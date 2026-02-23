package com.offlink.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.nio.charset.Charset
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class BlePeripheralManager(private val context: Context) {

    private val tag = "OfflinkPeripheral"

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var messageCharacteristic: BluetoothGattCharacteristic? = null

    private var serviceUuid: UUID? = null
    private var characteristicUuid: UUID? = null
    private var deviceUuid: String? = null // App-generated persistent UUID

    private val connectedDevices = CopyOnWriteArraySet<BluetoothDevice>()

    private var messageListener: ((String) -> Unit)? = null
    private var isAdvertising = false
    private var advertisingError: Int? = null
    
    // Connection state listener for peripheral mode
    private var connectionStateListener: ((Map<String, Any>) -> Unit)? = null
    
    // Native scanner components
    private var bleScanner: BluetoothLeScanner? = null
    private var nativeScanCallback: ScanCallback? = null
    private var scanResultListener: ((Map<String, Any>) -> Unit)? = null
    private val isScanning = AtomicBoolean(false)
    private val scanRetryCount = AtomicInteger(0)
    private val maxScanRetries = 3
    private val mainHandler = Handler(Looper.getMainLooper())
    private var scanTimeoutRunnable: Runnable? = null
    
    // Classic Bluetooth discovery
    private var classicDiscoveryReceiver: BroadcastReceiver? = null
    private val isClassicDiscovering = AtomicBoolean(false)
    private var useClassicDiscovery = false

    fun setMessageListener(listener: ((String) -> Unit)?) {
        messageListener = listener
    }
    
    fun setScanResultListener(listener: ((Map<String, Any>) -> Unit)?) {
        scanResultListener = listener
    }
    
    fun setConnectionStateListener(listener: ((Map<String, Any>) -> Unit)?) {
        connectionStateListener = listener
    }

    fun initialize(serviceUuidString: String, characteristicUuidString: String, deviceUuidString: String?): Boolean {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            Log.w(tag, "BLE not supported")
            return false
        }

        serviceUuid = try {
            UUID.fromString(serviceUuidString)
        } catch (ex: IllegalArgumentException) {
            Log.e(tag, "Invalid service UUID", ex)
            return false
        }

        characteristicUuid = try {
            UUID.fromString(characteristicUuidString)
        } catch (ex: IllegalArgumentException) {
            Log.e(tag, "Invalid characteristic UUID", ex)
            return false
        }
        
        // Store device UUID for inclusion in advertisements
        deviceUuid = deviceUuidString
        if (deviceUuid != null) {
            Log.d(tag, "Device UUID set: $deviceUuid")
        } else {
            Log.w(tag, "Device UUID not provided - advertisements will not include UUID")
        }

        bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        if (bluetoothAdapter == null) {
            Log.e(tag, "Bluetooth adapter not available")
            return false
        }

        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(tag, "BLE advertiser not available")
            return false
        }
        
        bleScanner = bluetoothAdapter?.bluetoothLeScanner
        setupGattServer()
        return gattServer != null
    }

    private fun setupGattServer() {
        if (gattServer != null) return

        val serviceUuidLocal = serviceUuid ?: return
        val characteristicUuidLocal = characteristicUuid ?: return

        gattServer = bluetoothManager?.openGattServer(context, gattServerCallback)
        if (gattServer == null) {
            Log.e(tag, "Failed to open GATT server")
            return
        }

        val service = BluetoothGattService(
            serviceUuidLocal,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )

        messageCharacteristic = BluetoothGattCharacteristic(
            characteristicUuidLocal,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        service.addCharacteristic(messageCharacteristic)
        val added = gattServer?.addService(service) ?: false
        Log.d(tag, "Gatt service added: $added")
    }

    fun startAdvertising(deviceName: String?): Boolean {
        val adapter = bluetoothAdapter ?: run {
            Log.e(tag, "Bluetooth adapter not available")
            return false
        }
        val advertiserLocal = advertiser ?: run {
            Log.e(tag, "BLE advertiser not available")
            return false
        }
        val serviceUuidLocal = serviceUuid ?: run {
            Log.e(tag, "Service UUID not initialized")
            return false
        }

        if (!adapter.isEnabled) {
            Log.w(tag, "Bluetooth adapter disabled")
            return false
        }

        // Cancel any pending retries
        advertisingRetryHandler?.removeCallbacksAndMessages(null)
        
        if (isAdvertising) {
            stopAdvertising()
            // Wait a bit for advertising to fully stop
            try {
                Thread.sleep(100)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        isAdvertising = false
        advertisingError = null

        if (!deviceName.isNullOrEmpty()) {
            try {
                adapter.name = deviceName // Use the passed name instead of hardcoded "Offlink"
                Log.d(tag, "Device name set to: ${adapter.name}")
            } catch (ex: SecurityException) {
                Log.w(tag, "Unable to set adapter name", ex)
            }
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()

        // BLE advertisement data limit is 31 bytes total
        // Device name "Offlink" (7 bytes) + AD structure overhead (2 bytes) = 9 bytes
        // Manufacturer data: AD type (1 byte) + length (1 byte) + manufacturer ID (2 bytes) + UUID (16 bytes) = 20 bytes
        // Total: 9 + 20 = 29 bytes - should fit, but some devices have stricter limits
        // Solution: Remove device name completely, use only manufacturer data
        // Discovery will work by scanning for manufacturer ID 0xFFFF
        val dataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false) // Don't include device name to ensure we fit in 31 bytes
        
        // Add device UUID and username to advertisement data as manufacturer data
        // Use a custom manufacturer ID (0xFFFF is reserved for testing)
        // Format: UUID (16 bytes) + username length (1 byte) + username (variable, max 10 bytes)
        // Total: 16 + 1 + 10 = 27 bytes max, fits in 31-byte limit
        if (deviceUuid != null && deviceUuid!!.isNotEmpty()) {
            try {
                // Parse UUID string and convert to 16-byte array
                val uuid = UUID.fromString(deviceUuid)
                val uuidBytes = ByteArray(16)
                val msb = uuid.mostSignificantBits
                val lsb = uuid.leastSignificantBits
                
                // Convert long to bytes (most significant first)
                for (i in 0..7) {
                    uuidBytes[i] = ((msb shr (56 - i * 8)) and 0xFF).toByte()
                }
                for (i in 0..7) {
                    uuidBytes[8 + i] = ((lsb shr (56 - i * 8)) and 0xFF).toByte()
                }
                
                // Append username after UUID
                // Truncate to max 10 bytes to fit in BLE limit
                val usernameBytes = if (!deviceName.isNullOrEmpty() && deviceName != "Offlink") {
                    val nameBytes = deviceName.toByteArray(Charset.forName("UTF-8"))
                    if (nameBytes.size > 10) {
                        nameBytes.copyOf(10) // Truncate to 10 bytes
                    } else {
                        nameBytes
                    }
                } else {
                    ByteArray(0) // No username
                }
                
                // Combine: UUID (16 bytes) + username length (1 byte) + username (variable)
                val combinedData = ByteArray(16 + 1 + usernameBytes.size)
                System.arraycopy(uuidBytes, 0, combinedData, 0, 16)
                combinedData[16] = usernameBytes.size.toByte() // Store username length
                if (usernameBytes.isNotEmpty()) {
                    System.arraycopy(usernameBytes, 0, combinedData, 17, usernameBytes.size)
                }
                
                // Use manufacturer ID 0xFFFF (reserved for testing)
                dataBuilder.addManufacturerData(0xFFFF, combinedData)
                Log.d(tag, "Added device UUID and username to advertisement: UUID=$deviceUuid, username=$deviceName (${usernameBytes.size} bytes)")
            } catch (e: Exception) {
                Log.w(tag, "Failed to add device UUID and username to advertisement", e)
            }
        }
        
        val data = dataBuilder.build()

        Log.d(tag, "Starting BLE advertising with service UUID: $serviceUuidLocal")

        try {
            advertiserLocal.startAdvertising(settings, data, advertiseCallback)
            return true
        } catch (ex: Exception) {
            Log.e(tag, "Exception starting advertising", ex)
            isAdvertising = false
            advertisingError = AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR
            return false
        }
    }

    fun stopAdvertising() {
        try {
            if (isAdvertising) {
                advertiser?.stopAdvertising(advertiseCallback)
                Log.d(tag, "Stopped BLE advertising")
            }
            isAdvertising = false
            advertisingError = null
        } catch (ex: IllegalStateException) {
            Log.w(tag, "stopAdvertising failed", ex)
            isAdvertising = false
        }
    }

    fun sendMessage(message: String): Boolean {
        val characteristic = messageCharacteristic ?: return false
        val server = gattServer ?: return false
        val payload = message.toByteArray(Charset.forName("UTF-8"))

        characteristic.value = payload

        var delivered = false
        connectedDevices.forEach { device ->
            val ok = server.notifyCharacteristicChanged(device, characteristic, false)
            delivered = delivered || ok
        }
        return delivered
    }

    fun shutdown() {
        stopNativeScan()
        stopClassicDiscovery()
        stopAdvertising()
        connectedDevices.clear()
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
    }

    // ==================== CLASSIC BLUETOOTH DISCOVERY ====================
    
    /**
     * Start Classic Bluetooth discovery as fallback when BLE scanning fails
     * This uses a different code path and works on devices with broken BLE scanners
     */
    fun startClassicDiscovery(timeoutMs: Long = 12000): Map<String, Any> {
        Log.d(tag, "Starting Classic Bluetooth discovery...")
        
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(tag, "Bluetooth adapter not available or disabled")
            return mapOf("success" to false, "error" to "Bluetooth not available")
        }
        
        // Stop any existing discovery
        stopClassicDiscovery()
        
        // Cancel any ongoing discovery
        if (adapter.isDiscovering) {
            adapter.cancelDiscovery()
            Thread.sleep(500)
        }
        
        // Make device discoverable (helps with discovery)
        try {
            // Set scan mode to make us visible
            Log.d(tag, "Current scan mode: ${adapter.scanMode}")
        } catch (e: Exception) {
            Log.w(tag, "Could not check scan mode: ${e.message}")
        }
        
        // Register broadcast receiver for discovery results
        classicDiscoveryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        
                        val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt()
                        
                        device?.let {
                            processClassicDiscoveryResult(it, rssi)
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_STARTED -> {
                        Log.d(tag, "Classic Bluetooth discovery started")
                        isClassicDiscovering.set(true)
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        Log.d(tag, "Classic Bluetooth discovery finished")
                        isClassicDiscovering.set(false)
                    }
                }
            }
        }
        
        // Register the receiver
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(classicDiscoveryReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(classicDiscoveryReceiver, filter)
            }
        } catch (e: Exception) {
            Log.e(tag, "Failed to register discovery receiver", e)
            return mapOf("success" to false, "error" to "Failed to register receiver: ${e.message}")
        }
        
        // Start discovery
        val started = try {
            adapter.startDiscovery()
        } catch (e: SecurityException) {
            Log.e(tag, "Security exception starting discovery", e)
            false
        }
        
        if (started) {
            Log.d(tag, "Classic Bluetooth discovery started successfully")
            isClassicDiscovering.set(true)
            
            // Set up timeout
            mainHandler.postDelayed({
                Log.d(tag, "Classic discovery timeout reached")
                stopClassicDiscovery()
            }, timeoutMs)
            
            return mapOf("success" to true, "mode" to "classic")
        } else {
            Log.e(tag, "Failed to start Classic Bluetooth discovery")
            unregisterClassicReceiver()
            return mapOf("success" to false, "error" to "Failed to start discovery")
        }
    }
    
    private fun processClassicDiscoveryResult(device: BluetoothDevice, rssi: Int) {
        val deviceName = try {
            device.name ?: "Unknown"
        } catch (e: SecurityException) {
            "Unknown"
        }
        val deviceAddress = device.address
        
        Log.d(tag, "Classic discovery found: $deviceName ($deviceAddress) RSSI: $rssi")
        
        // Check if this is an Offlink device by name
        val matchesName = deviceName.lowercase().startsWith("offlink")
        
        if (matchesName) {
            Log.d(tag, "Found Offlink device via Classic discovery: $deviceName")
            
            val resultMap = mapOf(
                "id" to deviceAddress,
                "name" to deviceName,
                "rssi" to rssi,
                "serviceUuids" to emptyList<String>(),
                "matchedBy" to "classic_name",
                "discoveryType" to "classic"
            )
            
            mainHandler.post {
                scanResultListener?.invoke(resultMap)
            }
        }
    }
    
    fun stopClassicDiscovery() {
        Log.d(tag, "Stopping Classic Bluetooth discovery...")
        
        try {
            if (bluetoothAdapter?.isDiscovering == true) {
                bluetoothAdapter?.cancelDiscovery()
            }
        } catch (e: SecurityException) {
            Log.w(tag, "Security exception canceling discovery", e)
        }
        
        unregisterClassicReceiver()
        isClassicDiscovering.set(false)
        Log.d(tag, "Classic discovery stopped")
    }
    
    private fun unregisterClassicReceiver() {
        try {
            classicDiscoveryReceiver?.let {
                context.unregisterReceiver(it)
            }
        } catch (e: Exception) {
            // Receiver might not be registered
        }
        classicDiscoveryReceiver = null
    }
    
    fun isClassicDiscovering(): Boolean {
        return isClassicDiscovering.get() || (bluetoothAdapter?.isDiscovering == true)
    }

    // ==================== NATIVE BLE SCANNER ====================
    
    fun startNativeScan(timeoutMs: Long = 30000): Map<String, Any> {
        Log.d(tag, "Starting native BLE scan...")
        
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(tag, "Bluetooth adapter not available or disabled")
            return mapOf("success" to false, "error" to "Bluetooth not available")
        }
        
        stopNativeScan()
        Thread.sleep(300)
        
        bleScanner = adapter.bluetoothLeScanner
        
        if (bleScanner == null) {
            Log.e(tag, "BLE scanner not available, returning failure to try flutter_blue_plus")
            // Don't fall back to Classic discovery - it can't find BLE devices
            // Let ConnectionManager try flutter_blue_plus instead
            return mapOf("success" to false, "error" to "BLE scanner not available")
        }
        
        scanRetryCount.set(0)
        return startScanWithRetry(timeoutMs)
    }
    
    private fun startScanWithRetry(timeoutMs: Long): Map<String, Any> {
        val currentRetry = scanRetryCount.get()
        Log.d(tag, "Starting BLE scan attempt ${currentRetry + 1}/$maxScanRetries")
        
        // For registration failures, try to clean up and wait longer
        if (currentRetry > 0) {
            Log.d(tag, "Retry attempt - waiting longer and cleaning up")
            try {
                // Stop any existing scan callbacks
                stopNativeScan()
                Thread.sleep(1000L + (currentRetry * 500L)) // Longer delay for retries
            } catch (e: Exception) {
                Log.w(tag, "Error during cleanup: ${e.message}")
            }
        }
        
        val scanner = bleScanner
        if (scanner == null) {
            Log.e(tag, "Scanner is null, returning failure to try flutter_blue_plus")
            return mapOf("success" to false, "error" to "BLE scanner not available")
        }
        
        nativeScanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                processScanResult(result)
            }
            
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { processScanResult(it) }
            }
            
            override fun onScanFailed(errorCode: Int) {
                Log.e(tag, "BLE scan failed with error: $errorCode (${getScanErrorName(errorCode)})")
                isScanning.set(false)
                
                if (errorCode == SCAN_FAILED_APPLICATION_REGISTRATION_FAILED) {
                    // BLE scanner is broken on this device
                    // Don't fall back to Classic discovery here - let ConnectionManager try flutter_blue_plus first
                    // Classic discovery can't find BLE devices anyway
                    Log.w(tag, "BLE scanner registration failed - returning failure to try flutter_blue_plus")
                    useClassicDiscovery = true
                    
                    // Return failure so ConnectionManager can try flutter_blue_plus
                    mainHandler.post {
                        notifyScanError(errorCode)
                    }
                } else if (scanRetryCount.incrementAndGet() < maxScanRetries) {
                    retryAfterDelay(timeoutMs)
                } else {
                    // All retries failed - try flutter_blue_plus via ConnectionManager, not Classic discovery
                    Log.w(tag, "All BLE scan retries failed - returning failure to try flutter_blue_plus")
                    mainHandler.post {
                        notifyScanError(errorCode)
                    }
                }
            }
        }
        
        // Android 13+ requires LOW_LATENCY mode for reliable scanning
        // Use aggressive settings to ensure all advertisements are detected
        val scanMode = if (Build.VERSION.SDK_INT >= 33) {
            // Android 13+ - always use LOW_LATENCY
            ScanSettings.SCAN_MODE_LOW_LATENCY
        } else {
            // Android 12 and below - can use different modes for retries
            when (currentRetry) {
                0 -> ScanSettings.SCAN_MODE_LOW_LATENCY
                1 -> ScanSettings.SCAN_MODE_BALANCED
                else -> ScanSettings.SCAN_MODE_LOW_POWER
            }
        }
        
        val settingsBuilder = ScanSettings.Builder()
            .setScanMode(scanMode)
            .setReportDelay(0)
        
        // Android 13+ requires aggressive scan settings
        if (Build.VERSION.SDK_INT >= 33) {
            settingsBuilder
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
        }
        
        val settings = settingsBuilder.build()
        
        try {
            Log.d(tag, "Starting BLE scan with mode: ${getScanModeName(scanMode)}")
            scanner.startScan(null, settings, nativeScanCallback)
            
            // Check if scan actually started (give it a moment)
            Thread.sleep(200)
            
            isScanning.set(true)
            
            scanTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            scanTimeoutRunnable = Runnable {
                Log.d(tag, "Scan timeout reached")
                stopNativeScan()
            }
            mainHandler.postDelayed(scanTimeoutRunnable!!, timeoutMs)
            
            Log.d(tag, "BLE scan started successfully")
            return mapOf("success" to true, "retry" to currentRetry, "mode" to "ble")
            
        } catch (ex: Exception) {
            Log.e(tag, "Exception starting BLE scan", ex)
            isScanning.set(false)
            
            // Return failure to let ConnectionManager try flutter_blue_plus
            Log.w(tag, "BLE scan exception - returning failure to try flutter_blue_plus")
            return mapOf("success" to false, "error" to (ex.message ?: "BLE scan exception"))
        }
    }
    
    private fun retryAfterDelay(timeoutMs: Long) {
        val currentRetry = scanRetryCount.get()
        val delayMs = 1500L + (currentRetry * 1000L) // Progressive delay: 1.5s, 2.5s, 3.5s
        Log.d(tag, "Retrying BLE scan in ${delayMs}ms (attempt ${currentRetry + 1}/$maxScanRetries)...")
        
        mainHandler.postDelayed({
            startScanWithRetry(timeoutMs)
        }, delayMs)
    }
    
    private fun processScanResult(result: ScanResult) {
        val device = result.device
        val deviceName = device.name ?: "Unknown"
        val deviceAddress = device.address
        val rssi = result.rssi
        
        // Android 13+ often doesn't expose Service UUIDs in scan results
        // We should NOT rely on serviceUuids for device identification
        val serviceUuids = result.scanRecord?.serviceUuids?.map { it.uuid.toString().uppercase() } ?: emptyList()
        
        // CRITICAL: Extract device UUID from manufacturer data (manufacturer ID 0xFFFF)
        // This is the ONLY reliable way to identify devices on Android 13+
        var extractedDeviceUuid: String? = null
        val scanRecord = result.scanRecord
        if (scanRecord != null) {
            // Method 1: Try getManufacturerSpecificData (standard method)
            try {
                val manufacturerData = scanRecord.getManufacturerSpecificData(0xFFFF)
                if (manufacturerData != null && manufacturerData.size >= 16) {
                    extractedDeviceUuid = extractUuidFromBytes(manufacturerData)
                    if (extractedDeviceUuid != null) {
                        Log.d(tag, "Extracted UUID from manufacturer data (method 1): $extractedDeviceUuid")
                    }
                }
            } catch (e: Exception) {
                Log.w(tag, "Method 1 failed to get manufacturer data", e)
            }
            
            // Method 2: Try parsing all manufacturer data entries (Android 13+ fallback)
            if (extractedDeviceUuid == null) {
                try {
                    val allManufacturerData = scanRecord.getManufacturerSpecificData()
                    if (allManufacturerData != null && allManufacturerData.size() > 0) {
                        // Iterate through all manufacturer IDs
                        for (i in 0 until allManufacturerData.size()) {
                            val manufacturerId = allManufacturerData.keyAt(i)
                            if (manufacturerId == 0xFFFF) {
                                val data = allManufacturerData.valueAt(i)
                                if (data != null && data.size >= 16) {
                                    extractedDeviceUuid = extractUuidFromBytes(data)
                                    if (extractedDeviceUuid != null) {
                                        Log.d(tag, "Extracted UUID from manufacturer data (method 2): $extractedDeviceUuid")
                                        break
                                    }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(tag, "Method 2 failed to parse manufacturer data", e)
                }
            }
            
            // Method 3: Try parsing raw advertisement bytes (Android 13+ last resort)
            // Some OEMs (like TECNO) may structure manufacturer data differently
            if (extractedDeviceUuid == null && Build.VERSION.SDK_INT >= 33) {
                try {
                    val rawBytes = scanRecord.bytes
                    if (rawBytes != null && rawBytes.size > 0) {
                        // Parse raw BLE advertisement data
                        // Manufacturer data AD type is 0xFF, followed by length, manufacturer ID (2 bytes), then data
                        var i = 0
                        while (i < rawBytes.size - 1) {
                            val length = rawBytes[i].toInt() and 0xFF
                            if (length == 0) break
                            if (i + length >= rawBytes.size) break
                            
                            val adType = rawBytes[i + 1].toInt() and 0xFF
                            
                            // AD type 0xFF = Manufacturer Specific Data
                            if (adType == 0xFF && length >= 19) { // 1 (length) + 1 (type) + 2 (manufacturer ID) + 16 (UUID) = 20 bytes minimum
                                val manufacturerId = ((rawBytes[i + 2].toInt() and 0xFF) shl 8) or (rawBytes[i + 3].toInt() and 0xFF)
                                if (manufacturerId == 0xFFFF && length >= 19) {
                                    // Extract UUID bytes (skip length, type, and manufacturer ID)
                                    val uuidBytes = ByteArray(16)
                                    System.arraycopy(rawBytes, i + 4, uuidBytes, 0, 16)
                                    extractedDeviceUuid = extractUuidFromBytes(uuidBytes)
                                    if (extractedDeviceUuid != null) {
                                        Log.d(tag, "Extracted UUID from raw advertisement bytes (method 3): $extractedDeviceUuid")
                                        break
                                    }
                                }
                            }
                            
                            i += length + 1 // Move to next AD structure
                        }
                    }
                } catch (e: Exception) {
                    Log.w(tag, "Method 3 failed to parse raw advertisement bytes", e)
                }
            }
        }
        
        Log.d(tag, "BLE scan result: $deviceName ($deviceAddress) RSSI: $rssi, Services: ${serviceUuids.size} (may be empty on Android 13+), UUID: $extractedDeviceUuid")
        
        // CRITICAL: Device identification MUST use manufacturer data, NOT service UUIDs
        // On Android 13+, service UUIDs are often null/empty even when device is advertising
        val hasOurManufacturerData = extractedDeviceUuid != null
        
        // Fallback: Check device name (may be hidden by OEMs, so not reliable)
        val matchesName = deviceName.lowercase().startsWith("offlink")
        
        // Only accept devices with manufacturer data OR matching name
        // Do NOT rely on service UUIDs for identification
        if (hasOurManufacturerData || matchesName) {
            Log.d(tag, "Found Offlink device: $deviceName (UUID: $extractedDeviceUuid)")
            
            // Use extracted UUID as device ID, fallback to MAC address if UUID not found
            val deviceId = extractedDeviceUuid ?: deviceAddress
            
            // Extract username from manufacturer data
            var extractedUsername = deviceName
            val manufacturerData = scanRecord?.getManufacturerSpecificData(0xFFFF)
            if (manufacturerData != null && manufacturerData.size > 17) {
                // Format: UUID (16 bytes) + username length (1 byte) + username (variable)
                try {
                    val usernameLength = manufacturerData[16].toInt() and 0xFF
                    if (usernameLength > 0 && manufacturerData.size >= 17 + usernameLength) {
                        val usernameBytes = ByteArray(usernameLength)
                        System.arraycopy(manufacturerData, 17, usernameBytes, 0, usernameLength)
                        extractedUsername = String(usernameBytes, Charset.forName("UTF-8"))
                        Log.d(tag, "Extracted username from manufacturer data: $extractedUsername")
                    }
                } catch (e: Exception) {
                    Log.w(tag, "Failed to extract username from manufacturer data", e)
                }
            }
            
            val resultMap = mapOf(
                "id" to deviceId, // Use UUID if available, otherwise MAC
                "name" to extractedUsername, // Use extracted username instead of device name
                "rssi" to rssi,
                "serviceUuids" to serviceUuids, // May be empty on Android 13+ - do NOT rely on this
                "deviceUuid" to (extractedDeviceUuid ?: ""), // Include UUID separately for reference
                "macAddress" to deviceAddress, // Keep MAC for connection purposes
                "matchedBy" to if (hasOurManufacturerData) "manufacturerData" else "name",
                "discoveryType" to "ble",
                "username" to extractedUsername // Include extracted username explicitly
            )
            
            mainHandler.post {
                scanResultListener?.invoke(resultMap)
            }
        } else {
            // Log devices that don't match (for debugging on Android 13+)
            if (Build.VERSION.SDK_INT >= 33) {
                Log.d(tag, "Device rejected (no manufacturer data or matching name): $deviceName ($deviceAddress)")
                // Log raw scan record info for debugging
                scanRecord?.let { record ->
                    try {
                        val allManufacturerData = record.getManufacturerSpecificData()
                        val manufacturerCount = allManufacturerData?.size() ?: 0
                        Log.d(tag, "  Available manufacturer IDs: $manufacturerCount")
                        allManufacturerData?.let { manufacturerData ->
                            val size = manufacturerData.size()
                            if (size > 0) {
                                for (i in 0 until size) {
                                    val id = manufacturerData.keyAt(i)
                                    val data = manufacturerData.valueAt(i)
                                    val dataSize = data?.size ?: 0
                                    Log.d(tag, "    Manufacturer ID: 0x${id.toString(16)}, Data size: $dataSize")
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(tag, "  Could not read manufacturer data: ${e.message}")
                    }
                }
            }
        }
    }
    
    // Helper function to extract UUID from byte array
    // Returns the UUID string, or null if extraction fails
    private fun extractUuidFromBytes(uuidBytes: ByteArray): String? {
        return try {
            if (uuidBytes.size < 16) {
                Log.w(tag, "Manufacturer data too short: ${uuidBytes.size} bytes (need 16)")
                return null
            }
            
            // Extract 16-byte UUID
            val bytes = ByteArray(16)
            System.arraycopy(uuidBytes, 0, bytes, 0, 16)
            
            // Convert 16-byte array back to UUID (big-endian)
            var msb: Long = 0
            var lsb: Long = 0
            for (i in 0..7) {
                msb = msb or ((bytes[i].toLong() and 0xFF) shl (56 - i * 8))
            }
            for (i in 0..7) {
                lsb = lsb or ((bytes[8 + i].toLong() and 0xFF) shl (56 - i * 8))
            }
            val uuid = UUID(msb, lsb)
            uuid.toString().lowercase()
        } catch (e: Exception) {
            Log.w(tag, "Failed to extract UUID from bytes", e)
            null
        }
    }
    
    private fun notifyScanError(errorCode: Int) {
        val errorMap = mapOf(
            "error" to true,
            "errorCode" to errorCode,
            "errorName" to getScanErrorName(errorCode)
        )
        
        mainHandler.post {
            scanResultListener?.invoke(errorMap)
        }
    }
    
    fun stopNativeScan() {
        Log.d(tag, "Stopping native scan...")
        
        scanTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        scanTimeoutRunnable = null
        
        if (isScanning.get()) {
            try {
                nativeScanCallback?.let { callback ->
                    bleScanner?.stopScan(callback)
                }
            } catch (ex: Exception) {
                Log.w(tag, "Error stopping BLE scan", ex)
            }
        }
        
        // Also stop classic discovery if running
        stopClassicDiscovery()
        
        isScanning.set(false)
        nativeScanCallback = null
        Log.d(tag, "Native scan stopped")
    }
    
    fun isNativeScanning(): Boolean {
        return isScanning.get() || isClassicDiscovering.get()
    }
    
    private fun getScanErrorName(errorCode: Int): String {
        return when (errorCode) {
            SCAN_FAILED_ALREADY_STARTED -> "SCAN_FAILED_ALREADY_STARTED"
            SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "SCAN_FAILED_APPLICATION_REGISTRATION_FAILED"
            SCAN_FAILED_INTERNAL_ERROR -> "SCAN_FAILED_INTERNAL_ERROR"
            SCAN_FAILED_FEATURE_UNSUPPORTED -> "SCAN_FAILED_FEATURE_UNSUPPORTED"
            SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES"
            else -> "UNKNOWN_ERROR_$errorCode"
        }
    }
    
    private fun getScanModeName(mode: Int): String {
        return when (mode) {
            ScanSettings.SCAN_MODE_LOW_LATENCY -> "LOW_LATENCY"
            ScanSettings.SCAN_MODE_BALANCED -> "BALANCED"
            ScanSettings.SCAN_MODE_LOW_POWER -> "LOW_POWER"
            ScanSettings.SCAN_MODE_OPPORTUNISTIC -> "OPPORTUNISTIC"
            else -> "UNKNOWN_$mode"
        }
    }

    // ==================== GATT SERVER MANAGEMENT ====================
    fun suspendForScanning() {
        Log.d(tag, "Suspending GATT server for scanning")
        
        if (isAdvertising) {
            stopAdvertising()
            Thread.sleep(300)
        }
        
        val server = gattServer
        val devicesToDisconnect = connectedDevices.toList()
        
        if (server != null && devicesToDisconnect.isNotEmpty()) {
            Log.d(tag, "Disconnecting ${devicesToDisconnect.size} connected device(s)")
            devicesToDisconnect.forEach { device ->
                try {
                    server.cancelConnection(device)
                } catch (ex: Exception) {
                    Log.w(tag, "Error canceling connection", ex)
                }
            }
            Thread.sleep(200)
        }
        connectedDevices.clear()
        
        try {
            if (server != null) {
                Log.d(tag, "Closing GATT server...")
                server.clearServices()
                Thread.sleep(100)
                server.close()
                Log.d(tag, "GATT server closed")
            }
        } catch (ex: Exception) {
            Log.w(tag, "Error closing GATT server", ex)
        }
        gattServer = null
        messageCharacteristic = null
        
        bleScanner = null
        System.gc()
        Thread.sleep(300)
        bleScanner = bluetoothAdapter?.bluetoothLeScanner
        
        Log.d(tag, "GATT server suspended - ready for scanning")
    }

    fun resumeAfterScanning(): Boolean {
        Log.d(tag, "Resuming GATT server after scanning")
        
        stopNativeScan()
        stopClassicDiscovery()
        
        Thread.sleep(300)
        
        var attempts = 0
        val maxAttempts = 3
        
        while (attempts < maxAttempts && gattServer == null) {
            attempts++
            Log.d(tag, "Setting up GATT server (attempt $attempts/$maxAttempts)")
            
            try {
                setupGattServer()
                
                if (gattServer != null) {
                    Log.d(tag, "GATT server resumed successfully")
                    return true
                }
            } catch (ex: Exception) {
                Log.w(tag, "Failed to setup GATT server on attempt $attempts", ex)
            }
            
            if (gattServer == null && attempts < maxAttempts) {
                Thread.sleep(500)
            }
        }
        
        return gattServer != null
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            super.onConnectionStateChange(device, status, newState)
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                connectedDevices.add(device)
                Log.d(tag, "Central connected: ${device.address}")
                // Notify Dart about the connection
                if (connectionStateListener != null) {
                    Log.d(tag, "🔵 Connection state listener is NOT null, sending event to Dart")
                    val stateMap = mapOf(
                        "connected" to true,
                        "deviceAddress" to device.address,
                        "deviceName" to (device.name ?: "Unknown Device")
                    )
                    Log.d(tag, "🔵 Sending connection state event: $stateMap")
                    connectionStateListener?.invoke(stateMap)
                    Log.d(tag, "✅ Connection state event sent to listener")
                } else {
                    Log.w(tag, "⚠️⚠️⚠️ Connection state listener is NULL! Event will be lost.")
                    Log.w(tag, "⚠️ Device ${device.address} connected but Dart won't be notified!")
                }
            } else if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                connectedDevices.remove(device)
                Log.d(tag, "Central disconnected: ${device.address}")
                if (connectionStateListener != null) {
                    Log.d(tag, "🔵 Connection state listener is NOT null, sending disconnect event")
                    val stateMap = mapOf(
                        "connected" to false,
                        "deviceAddress" to device.address,
                        "deviceName" to (device.name ?: "Unknown Device")
                    )
                    connectionStateListener?.invoke(stateMap)
                } else {
                    Log.w(tag, "⚠️⚠️⚠️ Connection state listener is NULL! Disconnect event will be lost.")
                }
            }
        }
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            super.onCharacteristicWriteRequest(
                device, requestId, characteristic, preparedWrite, responseNeeded, offset, value
            )
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            if (characteristic.uuid == characteristicUuid) {
                val message = String(value, Charset.forName("UTF-8"))
                Log.d(tag, "Message received from ${device.address}: $message")
                messageListener?.invoke(message)
            }
        }
    }

    private var advertisingRetryCount = 0
    private val maxAdvertisingRetries = 5
    private var advertisingRetryHandler: Handler? = null
    
    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            super.onStartSuccess(settingsInEffect)
            isAdvertising = true
            advertisingError = null
            advertisingRetryCount = 0 // Reset retry count on success
            advertisingRetryHandler?.removeCallbacksAndMessages(null)
            Log.d(tag, "Advertising successfully started")
        }
        override fun onStartFailure(errorCode: Int) {
            super.onStartFailure(errorCode)
            isAdvertising = false
            advertisingError = errorCode
            val errorName = when (errorCode) {
                AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
                AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
                AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
                AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
                AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
                else -> "UNKNOWN($errorCode)"
            }
            Log.e(tag, "Advertising failed: $errorName ($errorCode)")
            
            // Retry advertising after a delay
            if (advertisingRetryCount < maxAdvertisingRetries && errorCode != AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED) {
                advertisingRetryCount++
                val delayMs = 2000L * advertisingRetryCount // Exponential backoff
                Log.d(tag, "Retrying advertising in ${delayMs}ms (attempt $advertisingRetryCount/$maxAdvertisingRetries)")
                
                advertisingRetryHandler = Handler(Looper.getMainLooper())
                advertisingRetryHandler?.postDelayed({
                    if (!isAdvertising && bluetoothAdapter?.isEnabled == true) {
                        val deviceName = bluetoothAdapter?.name ?: "Offlink"
                        startAdvertising(deviceName)
                    }
                }, delayMs)
            } else {
                Log.e(tag, "Max advertising retries reached or already started, giving up")
                advertisingRetryCount = 0
            }
        }
    }

    fun isCurrentlyAdvertising(): Boolean = isAdvertising
    fun getAdvertisingError(): Int? = advertisingError
    
    companion object {
        const val SCAN_FAILED_ALREADY_STARTED = 1
        const val SCAN_FAILED_APPLICATION_REGISTRATION_FAILED = 2
        const val SCAN_FAILED_INTERNAL_ERROR = 3
        const val SCAN_FAILED_FEATURE_UNSUPPORTED = 4
        const val SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES = 5
    }
}
