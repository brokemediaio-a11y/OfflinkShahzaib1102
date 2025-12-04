package com.offlink.app

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val methodChannelName = "com.offlink.ble_peripheral"
    private val eventChannelName = "com.offlink.ble_peripheral/messages"
    private val blePeripheralManager by lazy { BlePeripheralManager(applicationContext) }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var messageSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        val serviceUuid = call.argument<String>("serviceUuid")
                        val characteristicUuid = call.argument<String>("characteristicUuid")
                        val initialized =
                            if (serviceUuid != null && characteristicUuid != null) {
                                blePeripheralManager.initialize(serviceUuid, characteristicUuid)
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

                    "sendMessage" -> {
                        val message = call.argument<String>("message")
                        val delivered = if (message != null) {
                            blePeripheralManager.sendMessage(message)
                        } else {
                            false
                        }
                        result.success(delivered)
                    }

                    else -> result.notImplemented()
                }
            }

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
    }

    override fun onDestroy() {
        blePeripheralManager.shutdown()
        super.onDestroy()
    }
}
