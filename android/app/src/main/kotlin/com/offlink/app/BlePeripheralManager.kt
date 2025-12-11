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

    private val connectedDevices = CopyOnWriteArraySet<BluetoothDevice>()

    private var messageListener: ((String) -> Unit)? = null
    private var isAdvertising = false
    private var advertisingError: Int? = null
    
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

    fun initialize(serviceUuidString: String, characteristicUuidString: String): Boolean {
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

        if (isAdvertising) {
            stopAdvertising()
        }

        isAdvertising = false
        advertisingError = null

        if (!deviceName.isNullOrEmpty()) {
            try {
                adapter.name = "Offlink"
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

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceUuid(ParcelUuid(serviceUuidLocal))
            .build()

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
            Log.e(tag, "BLE scanner not available, falling back to classic discovery")
            useClassicDiscovery = true
            return startClassicDiscovery(timeoutMs)
        }
        
        scanRetryCount.set(0)
        return startScanWithRetry(timeoutMs)
    }
    
    private fun startScanWithRetry(timeoutMs: Long): Map<String, Any> {
        val currentRetry = scanRetryCount.get()
        Log.d(tag, "Starting BLE scan attempt ${currentRetry + 1}/$maxScanRetries")
        
        val scanner = bleScanner
        if (scanner == null) {
            Log.e(tag, "Scanner is null, falling back to classic discovery")
            return startClassicDiscovery(timeoutMs)
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
                    // BLE scanner is broken on this device, use classic discovery
                    Log.w(tag, "BLE scanner registration failed - switching to Classic Bluetooth discovery")
                    useClassicDiscovery = true
                    
                    mainHandler.post {
                        val result = startClassicDiscovery(timeoutMs)
                        if (result["success"] != true) {
                            notifyScanError(errorCode)
                        }
                    }
                } else if (scanRetryCount.incrementAndGet() < maxScanRetries) {
                    retryAfterDelay(timeoutMs)
                } else {
                    // All retries failed, try classic discovery
                    Log.w(tag, "All BLE scan retries failed - trying Classic discovery")
                    mainHandler.post {
                        startClassicDiscovery(timeoutMs)
                    }
                }
            }
        }
        
        val scanMode = when (currentRetry) {
            0 -> ScanSettings.SCAN_MODE_LOW_LATENCY
            1 -> ScanSettings.SCAN_MODE_BALANCED
            else -> ScanSettings.SCAN_MODE_LOW_POWER
        }
        
        val settings = ScanSettings.Builder()
            .setScanMode(scanMode)
            .setReportDelay(0)
            .build()
        
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
            
            // Fall back to classic discovery
            Log.w(tag, "BLE scan exception - trying Classic discovery")
            return startClassicDiscovery(timeoutMs)
        }
    }
    
    private fun retryAfterDelay(timeoutMs: Long) {
        val delayMs = 2000L * scanRetryCount.get()
        Log.d(tag, "Retrying BLE scan in ${delayMs}ms...")
        
        mainHandler.postDelayed({
            startScanWithRetry(timeoutMs)
        }, delayMs)
    }
    
    private fun processScanResult(result: ScanResult) {
        val device = result.device
        val deviceName = device.name ?: "Unknown"
        val deviceAddress = device.address
        val rssi = result.rssi
        
        val serviceUuids = result.scanRecord?.serviceUuids?.map { it.uuid.toString().uppercase() } ?: emptyList()
        
        Log.d(tag, "BLE scan result: $deviceName ($deviceAddress) RSSI: $rssi, Services: $serviceUuids")
        
        val targetServiceUuid = serviceUuid?.toString()?.uppercase()
        val matchesService = targetServiceUuid != null && serviceUuids.contains(targetServiceUuid)
        val matchesName = deviceName.lowercase().startsWith("offlink")
        
        if (matchesService || matchesName) {
            Log.d(tag, "Found Offlink device: $deviceName")
            
            val resultMap = mapOf(
                "id" to deviceAddress,
                "name" to deviceName,
                "rssi" to rssi,
                "serviceUuids" to serviceUuids,
                "matchedBy" to if (matchesService) "serviceUuid" else "name",
                "discoveryType" to "ble"
            )
            
            mainHandler.post {
                scanResultListener?.invoke(resultMap)
            }
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
            } else if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                connectedDevices.remove(device)
                Log.d(tag, "Central disconnected: ${device.address}")
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

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            super.onStartSuccess(settingsInEffect)
            isAdvertising = true
            advertisingError = null
            Log.d(tag, "Advertising successfully started")
        }
        override fun onStartFailure(errorCode: Int) {
            super.onStartFailure(errorCode)
            isAdvertising = false
            advertisingError = errorCode
            Log.e(tag, "Advertising failed: $errorCode")
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
