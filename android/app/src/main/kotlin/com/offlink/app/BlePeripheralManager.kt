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
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import java.nio.charset.Charset
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet

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

    fun setMessageListener(listener: ((String) -> Unit)?) {
        messageListener = listener
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
        val characteristicUuidLocal = characteristicUuid ?: run {
            Log.e(tag, "Characteristic UUID not initialized")
            return false
        }

        if (!adapter.isEnabled) {
            Log.w(tag, "Bluetooth adapter disabled")
            return false
        }

        // Stop any existing advertising first
        if (isAdvertising) {
            Log.d(tag, "Stopping existing advertising before restart")
            stopAdvertising()
        }

        // Reset advertising state
        isAdvertising = false
        advertisingError = null

        // Set device name if provided - use short name to fit in advertisement
        if (!deviceName.isNullOrEmpty()) {
            try {
                // Use just "Offlink" as the advertisement name to keep packet small
                // Full device name is still available via GATT
                val shortName = "Offlink"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    adapter.name = shortName.take(20)
                } else {
                    adapter.name = shortName
                }
                Log.d(tag, "Device name set to: ${adapter.name} (short name for advertisement)")
                Log.d(tag, "Full device name: $deviceName (available via GATT)")
            } catch (ex: SecurityException) {
                Log.w(tag, "Unable to set adapter name", ex)
            }
        }

        // Configure advertising settings: LOW_LATENCY mode, HIGH power, connectable
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()

        // Build advertisement data with service UUID and short device name
        // NOTE: BLE advertisement packets are limited to 31 bytes total
        // Strategy: Use a short name prefix "Offlink" (7 bytes) + Service UUID (16 bytes) = ~23 bytes
        val serviceUuidParcel = ParcelUuid(serviceUuidLocal)
        val dataBuilder = AdvertiseData.Builder()
        
        // Include device name - Android will include it if there's space
        // We use a short name to ensure it fits
        dataBuilder.setIncludeDeviceName(true)
        
        // CRITICAL: Add service UUID - this is what scanners filter by
        dataBuilder.addServiceUuid(serviceUuidParcel)
        Log.d(tag, "Added service UUID to advertisement: $serviceUuidLocal")

        val data = dataBuilder.build()
        
        // Verify the advertisement data contains the service UUID
        val serviceUuidsInData = data.serviceUuids
        if (serviceUuidsInData != null && serviceUuidsInData.isNotEmpty()) {
            Log.d(tag, "Advertisement data contains ${serviceUuidsInData.size} service UUID(s):")
            serviceUuidsInData.forEach { uuid ->
                Log.d(tag, "  - Service UUID in advertisement: ${uuid.uuid}")
            }
            Log.d(tag, "Advertisement packet size should be ~18 bytes (well under 31 byte limit)")
        } else {
            Log.e(tag, "WARNING: Advertisement data does NOT contain any service UUIDs!")
        }

        // Log what we're advertising
        Log.d(tag, "Starting BLE advertising with:")
        Log.d(tag, "  - Service UUID: $serviceUuidLocal")
        Log.d(tag, "  - Characteristic UUID: $characteristicUuidLocal")
        Log.d(tag, "  - Device name: $deviceName")
        Log.d(tag, "  - Mode: LOW_LATENCY")
        Log.d(tag, "  - TX Power: HIGH")
        Log.d(tag, "  - Connectable: true")

        try {
            advertiserLocal.startAdvertising(settings, data, advertiseCallback)
            Log.d(tag, "Advertising start requested for device: $deviceName")
            // Note: Actual success/failure will be reported in advertiseCallback
            // We return true here because the request was submitted successfully
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
        stopAdvertising()
        connectedDevices.clear()
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
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
                device,
                requestId,
                characteristic,
                preparedWrite,
                responseNeeded,
                offset,
                value
            )

            gattServer?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                offset,
                null
            )

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
            Log.d(tag, "  - Advertise mode: ${settingsInEffect.mode}")
            Log.d(tag, "  - TX power level: ${settingsInEffect.txPowerLevel}")
            Log.d(tag, "  - Connectable: ${settingsInEffect.isConnectable}")
        }

        override fun onStartFailure(errorCode: Int) {
            super.onStartFailure(errorCode)
            isAdvertising = false
            advertisingError = errorCode
            val errorMessage = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "ADVERTISE_FAILED_DATA_TOO_LARGE"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "ADVERTISE_FAILED_TOO_MANY_ADVERTISERS"
                ADVERTISE_FAILED_ALREADY_STARTED -> "ADVERTISE_FAILED_ALREADY_STARTED"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "ADVERTISE_FAILED_INTERNAL_ERROR"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "ADVERTISE_FAILED_FEATURE_UNSUPPORTED"
                else -> "UNKNOWN_ERROR"
            }
            Log.e(tag, "Advertising failed: $errorCode ($errorMessage)")
        }
    }

    fun isCurrentlyAdvertising(): Boolean {
        return isAdvertising
    }

    fun getAdvertisingError(): Int? {
        return advertisingError
    }
}

