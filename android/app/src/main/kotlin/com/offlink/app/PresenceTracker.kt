package com.offlink.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * PresenceTracker — Persistent background BLE scanner for contact presence detection.
 *
 * Runs as an Android Foreground Service so it survives app backgrounding.
 * Continuously scans for BLE advertisements from known OffLink contacts.
 *
 * Architecture:
 *   PresenceTracker (Foreground Service)
 *     └── BLE Advertisement Scanner
 *           └── on advertisement → match UUID → update presence state
 *                 └── Callback → Flutter EventChannel → PresenceProvider
 *                       └── UI badge + local notification
 */
class PresenceTracker : Service() {

    companion object {
        private const val TAG = "PresenceTracker"
        private const val NOTIFICATION_CHANNEL_ID = "offlink_presence"
        private const val NOTIFICATION_ID = 9001
        private const val PRESENCE_TIMEOUT_MS = 60_000L // 60 seconds
        private const val SCAN_RESTART_INTERVAL_MS = 30_000L // restart scan every 30s to avoid Android throttling

        // Static listener that MainActivity sets for EventChannel bridge
        var presenceListener: ((Map<String, Any>) -> Unit)? = null

        // Known contact UUIDs to watch for — set from Flutter side
        private val watchedContactUuids = ConcurrentHashMap.newKeySet<String>()

        fun updateWatchedContacts(uuids: List<String>) {
            watchedContactUuids.clear()
            watchedContactUuids.addAll(uuids)
            Log.d(TAG, "Updated watched contacts: ${uuids.size} contact(s)")
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var scanner: BluetoothLeScanner? = null
    private var isScanning = false

    // Track last-seen timestamp and RSSI per contact UUID
    private val lastSeenMap = ConcurrentHashMap<String, Long>()
    private val rssiMap = ConcurrentHashMap<String, Int>()
    private val presenceState = ConcurrentHashMap<String, Boolean>() // true = inRange

    // Periodic timeout checker
    private val timeoutChecker = object : Runnable {
        override fun run() {
            checkTimeouts()
            mainHandler.postDelayed(this, 10_000) // check every 10 seconds
        }
    }

    // Periodic scan restarter (avoids Android BLE scan throttling)
    private val scanRestarter = object : Runnable {
        override fun run() {
            if (isScanning) {
                restartScan()
            }
            mainHandler.postDelayed(this, SCAN_RESTART_INTERVAL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "PresenceTracker service created")
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        initScanner()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "PresenceTracker service started")
        startPresenceScan()
        mainHandler.post(timeoutChecker)
        mainHandler.postDelayed(scanRestarter, SCAN_RESTART_INTERVAL_MS)
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "PresenceTracker service destroyed")
        stopPresenceScan()
        mainHandler.removeCallbacks(timeoutChecker)
        mainHandler.removeCallbacks(scanRestarter)
        super.onDestroy()
    }

    // ═══════════════════════════════════════════════════════════════════
    // BLE Scanner Setup
    // ═══════════════════════════════════════════════════════════════════

    private fun initScanner() {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
        scanner = adapter?.bluetoothLeScanner

        if (scanner == null) {
            Log.e(TAG, "BLE scanner not available")
        }
    }

    private fun startPresenceScan() {
        if (isScanning) return
        val s = scanner ?: return

        try {
            // BlePeripheralManager advertises using manufacturer data key 0xFFFF
            // (NOT a service UUID). No scan filter — we inspect all advertisements
            // and extract the OffLink UUID from manufacturer data in handleScanResult.
            // Use BALANCED mode in background to reduce battery drain.
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
                .setReportDelay(0)
                .build()

            s.startScan(null, settings, presenceScanCallback)
            isScanning = true
            Log.d(TAG, "Presence scan started (BALANCED, no service filter)")
        } catch (e: SecurityException) {
            Log.e(TAG, "Security exception starting presence scan: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting presence scan: ${e.message}")
        }
    }

    private fun stopPresenceScan() {
        if (!isScanning) return
        try {
            scanner?.stopScan(presenceScanCallback)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping presence scan: ${e.message}")
        }
        isScanning = false
        Log.d(TAG, "Presence scan stopped")
    }

    private fun restartScan() {
        stopPresenceScan()
        startPresenceScan()
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scan Callback
    // ═══════════════════════════════════════════════════════════════════

    private val presenceScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            handleScanResult(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            for (result in results) {
                handleScanResult(result)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Presence scan failed with error code: $errorCode")
            isScanning = false
            // Retry after a delay
            mainHandler.postDelayed({ startPresenceScan() }, 5000)
        }
    }

    private fun handleScanResult(result: ScanResult) {
        try {
            // Extract device UUID from scan record
            val scanRecord = result.scanRecord ?: return
            val serviceData = scanRecord.serviceData
            val deviceUuid = extractDeviceUuid(scanRecord) ?: return

            // Check if this is a watched contact
            if (!watchedContactUuids.contains(deviceUuid)) return

            val now = System.currentTimeMillis()
            val rssi = result.rssi
            val wasInRange = presenceState[deviceUuid] ?: false

            lastSeenMap[deviceUuid] = now
            rssiMap[deviceUuid] = rssi

            if (!wasInRange) {
                // Contact just came into range
                presenceState[deviceUuid] = true
                Log.d(TAG, "Contact $deviceUuid came into range (RSSI: $rssi)")
                notifyPresenceChange(deviceUuid, inRange = true, rssi = rssi)
            } else {
                // Still in range — update RSSI silently
                notifyRssiUpdate(deviceUuid, rssi)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling presence scan result: ${e.message}")
        }
    }

    /**
     * Extract the OffLink device UUID from a BLE scan record.
     *
     * BlePeripheralManager encodes the UUID as 16 raw big-endian bytes in
     * manufacturer data key 0xFFFF (primary advertisement).
     * This mirrors the extraction logic in BleDiscoveryService.dart exactly.
     */
    private fun extractDeviceUuid(scanRecord: android.bluetooth.le.ScanRecord): String? {
        val mfgData = scanRecord.manufacturerSpecificData ?: return null

        // Primary: manufacturer data key 0xFFFF — 16 raw UUID bytes
        val uuidBytes = mfgData.get(0xFFFF)
        if (uuidBytes != null && uuidBytes.size >= 16) {
            return bytesToUuidString(uuidBytes)
        }

        // 0xFFFE is the scan response (username only) — not a UUID source, skip it.
        return null
    }

    /**
     * Convert 16 big-endian bytes to a UUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
     * Mirrors BleDiscoveryService._bytesToUuid in Dart.
     */
    private fun bytesToUuidString(bytes: ByteArray): String? {
        return try {
            if (bytes.size < 16) return null
            var msb = 0L
            var lsb = 0L
            for (i in 0..7) {
                msb = (msb shl 8) or (bytes[i].toLong() and 0xFF)
            }
            for (i in 8..15) {
                lsb = (lsb shl 8) or (bytes[i].toLong() and 0xFF)
            }
            val uuid = java.util.UUID(msb, lsb)
            uuid.toString()
        } catch (e: Exception) {
            null
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Timeout Detection
    // ═══════════════════════════════════════════════════════════════════

    private fun checkTimeouts() {
        val now = System.currentTimeMillis()
        for ((uuid, lastSeen) in lastSeenMap) {
            val wasInRange = presenceState[uuid] ?: false
            if (wasInRange && (now - lastSeen) > PRESENCE_TIMEOUT_MS) {
                presenceState[uuid] = false
                Log.d(TAG, "Contact $uuid went out of range (timeout)")
                notifyPresenceChange(uuid, inRange = false, rssi = null)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Flutter Callbacks
    // ═══════════════════════════════════════════════════════════════════

    private fun notifyPresenceChange(deviceUuid: String, inRange: Boolean, rssi: Int?) {
        val event = mapOf(
            "type" to "presence_change",
            "deviceUuid" to deviceUuid,
            "inRange" to inRange,
            "rssi" to (rssi ?: 0),
            "timestamp" to System.currentTimeMillis()
        )
        mainHandler.post {
            presenceListener?.invoke(event)
        }
    }

    private fun notifyRssiUpdate(deviceUuid: String, rssi: Int) {
        val event = mapOf(
            "type" to "rssi_update",
            "deviceUuid" to deviceUuid,
            "inRange" to true,
            "rssi" to rssi,
            "timestamp" to System.currentTimeMillis()
        )
        mainHandler.post {
            presenceListener?.invoke(event)
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Notification
    // ═══════════════════════════════════════════════════════════════════

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "OffLink Presence",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Monitors nearby OffLink contacts"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("OffLink")
            .setContentText("Monitoring for nearby contacts")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }
}
