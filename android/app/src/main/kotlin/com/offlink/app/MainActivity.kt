package com.offlink.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val methodChannelName = "com.offlink.ble_peripheral"
    private val classicBluetoothChannelName = "com.offlink.classic_bluetooth"
    private val permissionsChannelName = "com.offlink.permissions"
    private val eventChannelName = "com.offlink.ble_peripheral/messages"
    private val scanEventChannelName = "com.offlink.ble_peripheral/scan_results"
    private val connectionStateChannelName = "com.offlink.ble_peripheral/connection_state"
    private val classicBluetoothMessageChannelName = "com.offlink.classic_bluetooth/messages"
    private val classicBluetoothConnectionStateChannelName = "com.offlink.classic_bluetooth/connection_state"
    
    // ── Wi-Fi Direct channel names ────────────────────────────────────
    private val wifiDirectMethodChannelName = "com.offlink.wifi_direct"
    private val wifiDirectMessagesChannelName = "com.offlink.wifi_direct/messages"
    private val wifiDirectConnectionStateChannelName = "com.offlink.wifi_direct/connection_state"
    private val wifiDirectPeersChannelName = "com.offlink.wifi_direct/peers"
    private val wifiDirectInvitationChannelName = "com.offlink.wifi_direct/invitation"

    private val blePeripheralManager by lazy { BlePeripheralManager(applicationContext) }
    private val classicBluetoothManager by lazy { ClassicBluetoothManager(applicationContext) }
    private val wifiDirectManager by lazy { WifiDirectManager(applicationContext) }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var messageSink: EventChannel.EventSink? = null
    private var scanResultSink: EventChannel.EventSink? = null
    private var connectionStateSink: EventChannel.EventSink? = null
    private var classicBluetoothMessageSink: EventChannel.EventSink? = null
    private var classicBluetoothConnectionStateSink: EventChannel.EventSink? = null
    // ── Wi-Fi Direct event sinks ──────────────────────────────────────
    private var wifiDirectMessageSink: EventChannel.EventSink? = null
    private var wifiDirectConnectionStateSink: EventChannel.EventSink? = null
    private var wifiDirectPeersSink: EventChannel.EventSink? = null
    private var wifiDirectInvitationSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        val serviceUuid = call.argument<String>("serviceUuid")
                        val characteristicUuid = call.argument<String>("characteristicUuid")
                        val deviceUuid = call.argument<String>("deviceUuid")
                        val initialized =
                            if (serviceUuid != null && characteristicUuid != null) {
                                blePeripheralManager.initialize(serviceUuid, characteristicUuid, deviceUuid)
                            } else {
                                false
                            }
                        result.success(initialized)
                    }

                    "startAdvertising" -> {
                        val deviceName = call.argument<String>("deviceName")
                        val started = blePeripheralManager.startAdvertising(deviceName)
                        result.success(started)
                    }

                    "stopAdvertising" -> {
                        blePeripheralManager.stopAdvertising()
                        result.success(null)
                    }

                    "suspendForScanning" -> {
                        Thread {
                            blePeripheralManager.suspendForScanning()
                            mainHandler.post {
                                result.success(null)
                            }
                        }.start()
                    }

                    "resumeAfterScanning" -> {
                        Thread {
                            val resumed = blePeripheralManager.resumeAfterScanning()
                            mainHandler.post {
                                result.success(resumed)
                            }
                        }.start()
                    }

                    "sendMessage" -> {
                        val message = call.argument<String>("message")
                        val delivered = if (message != null) {
                            blePeripheralManager.sendMessage(message)
                        } else {
                            false
                        }
                        result.success(delivered)
                    }
                    
                    // Native scanner methods
                    "startNativeScan" -> {
                        val timeoutMs = call.argument<Int>("timeoutMs")?.toLong() ?: 30000L
                        Thread {
                            val scanResult = blePeripheralManager.startNativeScan(timeoutMs)
                            mainHandler.post {
                                result.success(scanResult)
                            }
                        }.start()
                    }
                    
                    "stopNativeScan" -> {
                        blePeripheralManager.stopNativeScan()
                        result.success(null)
                    }
                    
                    "isNativeScanning" -> {
                        result.success(blePeripheralManager.isNativeScanning())
                    }
                    
                    // Classic Bluetooth discovery methods
                    "startClassicDiscovery" -> {
                        val timeoutMs = call.argument<Int>("timeoutMs")?.toLong() ?: 12000L
                        Thread {
                            val discoveryResult = blePeripheralManager.startClassicDiscovery(timeoutMs)
                            mainHandler.post {
                                result.success(discoveryResult)
                            }
                        }.start()
                    }
                    
                    "stopClassicDiscovery" -> {
                        blePeripheralManager.stopClassicDiscovery()
                        result.success(null)
                    }
                    
                    "isClassicDiscovering" -> {
                        result.success(blePeripheralManager.isClassicDiscovering())
                    }

                    else -> result.notImplemented()
                }
            }

        // Permissions Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkNearbyDevicesPermission" -> {
                        result.success(checkNearbyDevicesPermission())
                    }
                    
                    "isLocationEnabled" -> {
                        result.success(isLocationEnabled())
                    }
                    
                    "checkBluetoothPermissions" -> {
                        result.success(checkBluetoothPermissions())
                    }
                    
                    else -> result.notImplemented()
                }
            }

        // Message Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                messageSink = events
                blePeripheralManager.setMessageListener { message ->
                    mainHandler.post {
                        messageSink?.success(message)
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                messageSink = null
                blePeripheralManager.setMessageListener(null)
            }
        })
        
        // Scan Results Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            scanEventChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                scanResultSink = events
                blePeripheralManager.setScanResultListener { result ->
                    mainHandler.post {
                        scanResultSink?.success(result)
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                scanResultSink = null
                blePeripheralManager.setScanResultListener(null)
            }
        })
        
        // Connection State Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            connectionStateChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                android.util.Log.d("MainActivity", "🔵 Connection state EventChannel: onListen called")
                connectionStateSink = events
                android.util.Log.d("MainActivity", "🔵 Setting connection state listener in BlePeripheralManager")
                blePeripheralManager.setConnectionStateListener { state ->
                    android.util.Log.d("MainActivity", "🔵 Connection state event received from BlePeripheralManager: $state")
                    mainHandler.post {
                        if (connectionStateSink != null) {
                            connectionStateSink?.success(state)
                            android.util.Log.d("MainActivity", "✅ Connection state event sent to Dart successfully")
                        } else {
                            android.util.Log.w("MainActivity", "⚠️⚠️⚠️ Connection state sink is NULL! Event lost!")
                        }
                    }
                }
                android.util.Log.d("MainActivity", "✅ Connection state listener set up in native")
            }

            override fun onCancel(arguments: Any?) {
                android.util.Log.d("MainActivity", "🔵 Connection state EventChannel: onCancel called")
                connectionStateSink = null
                blePeripheralManager.setConnectionStateListener(null)
            }
        })
        
        // Classic Bluetooth Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, classicBluetoothChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        val initialized = classicBluetoothManager.initialize()
                        result.success(initialized)
                    }
                    
                    "connect" -> {
                        val address = call.argument<String>("address")
                        Thread {
                            val connected = if (address != null) {
                                classicBluetoothManager.connect(address)
                            } else {
                                false
                            }
                            mainHandler.post {
                                result.success(connected)
                            }
                        }.start()
                    }
                    
                    "disconnect" -> {
                        classicBluetoothManager.disconnect()
                        result.success(null)
                    }
                    
                    "sendMessage" -> {
                        val message = call.argument<String>("message")
                        val sent = if (message != null) {
                            classicBluetoothManager.sendMessage(message)
                        } else {
                            false
                        }
                        result.success(sent)
                    }
                    
                    "isConnected" -> {
                        result.success(classicBluetoothManager.isConnected())
                    }
                    
                    else -> result.notImplemented()
                }
            }
        
        // Classic Bluetooth Message Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            classicBluetoothMessageChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                classicBluetoothMessageSink = events
                classicBluetoothManager.setMessageListener { message ->
                    mainHandler.post {
                        classicBluetoothMessageSink?.success(message)
                    }
                }
            }
            
            override fun onCancel(arguments: Any?) {
                classicBluetoothMessageSink = null
                classicBluetoothManager.setMessageListener(null)
            }
        })
        
        // Classic Bluetooth Connection State Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            classicBluetoothConnectionStateChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                classicBluetoothConnectionStateSink = events
                classicBluetoothManager.setConnectionStateListener { state ->
                    mainHandler.post {
                        classicBluetoothConnectionStateSink?.success(state)
                    }
                }
            }
            
            override fun onCancel(arguments: Any?) {
                classicBluetoothConnectionStateSink = null
                classicBluetoothManager.setConnectionStateListener(null)
            }
        })

        // ── Wi-Fi Direct ──────────────────────────────────────────────

        // Wi-Fi Direct Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiDirectMethodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        val initialized = wifiDirectManager.initialize()
                        result.success(initialized)
                    }

                    "discoverPeers" -> {
                        wifiDirectManager.startDiscovery()
                        result.success(mapOf("success" to true))
                    }

                    "stopDiscovery" -> {
                        wifiDirectManager.stopDiscovery()
                        result.success(null)
                    }

                    "initiateConnection" -> {
                        val targetName = call.argument<String>("targetName")
                        if (targetName == null) {
                            result.error("INVALID_ARGS", "targetName is required", null)
                            return@setMethodCallHandler
                        }
                        // Find the peer by name from the current peer list and connect
                        Thread {
                            try {
                                // Start discovery first so peers list is populated,
                                // then connect once the peers-changed event fires.
                                // For now we connect directly if the peer is already known.
                                wifiDirectManager.connectByName(targetName)
                                mainHandler.post { result.success(mapOf("success" to true)) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.success(mapOf("success" to false, "error" to (e.message ?: "unknown")))
                                }
                            }
                        }.start()
                    }

                    "disconnect" -> {
                        wifiDirectManager.disconnect()
                        result.success(null)
                    }

                    "sendMessage" -> {
                        val message = call.argument<String>("message")
                        val sent = if (message != null) {
                            wifiDirectManager.sendMessage(message)
                        } else {
                            false
                        }
                        result.success(sent)
                    }

                    "isConnected" -> {
                        result.success(wifiDirectManager.isConnected())
                    }

                    "isSocketActive" -> {
                        result.success(wifiDirectManager.isSocketActive())
                    }

                    "getGroupInfo" -> {
                        result.success(wifiDirectManager.getGroupInfo())
                    }

                    "acceptInvitation" -> {
                        val res = wifiDirectManager.acceptInvitation()
                        result.success(res)
                    }

                    "rejectInvitation" -> {
                        wifiDirectManager.rejectInvitation()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // Wi-Fi Direct Messages Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            wifiDirectMessagesChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                wifiDirectMessageSink = events
                wifiDirectManager.messageListener = { message ->
                    mainHandler.post { wifiDirectMessageSink?.success(message) }
                }
            }
            override fun onCancel(arguments: Any?) {
                wifiDirectMessageSink = null
                wifiDirectManager.messageListener = null
            }
        })

        // Wi-Fi Direct Connection State Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            wifiDirectConnectionStateChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                wifiDirectConnectionStateSink = events
                wifiDirectManager.connectionStateListener = { state ->
                    mainHandler.post { wifiDirectConnectionStateSink?.success(state) }
                }
            }
            override fun onCancel(arguments: Any?) {
                wifiDirectConnectionStateSink = null
                wifiDirectManager.connectionStateListener = null
            }
        })

        // Wi-Fi Direct Peers Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            wifiDirectPeersChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                wifiDirectPeersSink = events
                wifiDirectManager.peerListListener = { peers ->
                    mainHandler.post { wifiDirectPeersSink?.success(peers) }
                }
            }
            override fun onCancel(arguments: Any?) {
                wifiDirectPeersSink = null
                wifiDirectManager.peerListListener = null
            }
        })

        // Wi-Fi Direct Invitation Event Channel
        // Fires on the RECEIVING device when a remote peer sends a connection invitation.
        // Payload: { "deviceName": String, "deviceAddress": String }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            wifiDirectInvitationChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                wifiDirectInvitationSink = events
                wifiDirectManager.incomingInvitationListener = { payload ->
                    mainHandler.post { wifiDirectInvitationSink?.success(payload) }
                }
            }
            override fun onCancel(arguments: Any?) {
                wifiDirectInvitationSink = null
                wifiDirectManager.incomingInvitationListener = null
            }
        })
    }

    override fun onDestroy() {
        blePeripheralManager.shutdown()
        classicBluetoothManager.shutdown()
        wifiDirectManager.shutdown()
        super.onDestroy()
    }

    private fun checkNearbyDevicesPermission(): Boolean {
        val sdkInt = Build.VERSION.SDK_INT

        // Android 11 (API 30 and below): use Location
        if (sdkInt <= 30) {
            val permission = Manifest.permission.ACCESS_FINE_LOCATION
            val status = ContextCompat.checkSelfPermission(this, permission)
            return status == PackageManager.PERMISSION_GRANTED
        }

        // Android 12 (API 31-32): use Bluetooth permissions
        if (sdkInt in 31..32) {
            val scanPermission = Manifest.permission.BLUETOOTH_SCAN
            val connectPermission = Manifest.permission.BLUETOOTH_CONNECT
            val advertisePermission = Manifest.permission.BLUETOOTH_ADVERTISE

            val scanGranted =
                ContextCompat.checkSelfPermission(this, scanPermission) == PackageManager.PERMISSION_GRANTED
            val connectGranted =
                ContextCompat.checkSelfPermission(this, connectPermission) == PackageManager.PERMISSION_GRANTED
            val advertiseGranted =
                ContextCompat.checkSelfPermission(this, advertisePermission) == PackageManager.PERMISSION_GRANTED

            return scanGranted && connectGranted && advertiseGranted
        }

        // Android 13+ (API 33+): use NEARBY_WIFI_DEVICES
        if (sdkInt >= 33) {
            val permission = Manifest.permission.NEARBY_WIFI_DEVICES
            val status = ContextCompat.checkSelfPermission(this, permission)
            return status == PackageManager.PERMISSION_GRANTED
        }

        return false
    }
    
    private fun isLocationEnabled(): Boolean {
        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        return locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
               locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
    }
    
    private fun checkBluetoothPermissions(): Boolean {
        val sdkInt = Build.VERSION.SDK_INT
        
        if (sdkInt >= 31) {
            // Android 12+ requires BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE
            val scanGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
            
            val connectGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            
            val advertiseGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_ADVERTISE
            ) == PackageManager.PERMISSION_GRANTED
            
            val locationGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            
            return scanGranted && connectGranted && advertiseGranted && locationGranted
        } else {
            // Android 11 and below
            val bluetoothGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH
            ) == PackageManager.PERMISSION_GRANTED
            
            val locationGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            
            return bluetoothGranted && locationGranted
        }
    }
}
