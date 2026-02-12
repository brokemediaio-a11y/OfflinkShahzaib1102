package com.offlink.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

class ClassicBluetoothManager(private val context: Context) {
    
    private val tag = "ClassicBluetooth"
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // UUID for RFCOMM service (standard Serial Port Profile UUID)
    private val uuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var serverSocket: BluetoothServerSocket? = null
    private var clientSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    
    private var acceptThread: AcceptThread? = null
    private var connectedThread: ConnectedThread? = null
    
    private var messageListener: ((String) -> Unit)? = null
    private var connectionStateListener: ((Map<String, Any>) -> Unit)? = null
    
    private var isServerRunning = false
    private var connectedDevice: BluetoothDevice? = null
    
    init {
        bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
    }
    
    fun setMessageListener(listener: ((String) -> Unit)?) {
        messageListener = listener
    }
    
    fun setConnectionStateListener(listener: ((Map<String, Any>) -> Unit)?) {
        connectionStateListener = listener
    }
    
    fun initialize(): Boolean {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(tag, "Bluetooth adapter not available or disabled")
            return false
        }
        
        // Start server socket to accept incoming connections
        startServer()
        
        Log.d(tag, "Classic Bluetooth manager initialized")
        return true
    }
    
    private fun startServer() {
        if (isServerRunning) {
            Log.w(tag, "Server already running")
            return
        }
        
        val adapter = bluetoothAdapter ?: return
        
        try {
            serverSocket = adapter.listenUsingRfcommWithServiceRecord("Offlink", uuid)
            isServerRunning = true
            
            acceptThread = AcceptThread()
            acceptThread?.start()
            
            Log.d(tag, "Classic Bluetooth server started")
        } catch (e: IOException) {
            Log.e(tag, "Error starting server socket", e)
            isServerRunning = false
        }
    }
    
    fun connect(address: String): Boolean {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(tag, "Bluetooth adapter not available or disabled")
            return false
        }
        
        // Cancel any existing connection
        disconnect()
        
        try {
            val device = adapter.getRemoteDevice(address)
            if (device == null) {
                Log.e(tag, "Device not found: $address")
                return false
            }
            
            Log.d(tag, "Connecting to device: ${device.name} ($address)")
            
            // Create socket and connect
            val socket = device.createRfcommSocketToServiceRecord(uuid)
            socket.connect()
            
            connectedDevice = device
            manageConnectedSocket(socket)
            
            notifyConnectionState(true, address, device.name ?: "Unknown")
            
            Log.d(tag, "Connected to device: ${device.name}")
            return true
        } catch (e: IOException) {
            Log.e(tag, "Error connecting to device", e)
            notifyConnectionState(false, address, "Unknown")
            return false
        }
    }
    
    fun disconnect() {
        try {
            connectedThread?.cancel()
            connectedThread = null
            
            clientSocket?.close()
            clientSocket = null
            
            inputStream?.close()
            inputStream = null
            
            outputStream?.close()
            outputStream = null
            
            if (connectedDevice != null) {
                val address = connectedDevice!!.address
                val name = connectedDevice!!.name ?: "Unknown"
                connectedDevice = null
                notifyConnectionState(false, address, name)
            }
            
            Log.d(tag, "Disconnected")
        } catch (e: Exception) {
            Log.e(tag, "Error disconnecting", e)
        }
    }
    
    fun sendMessage(message: String): Boolean {
        return connectedThread?.write(message.toByteArray(Charsets.UTF_8)) ?: false
    }
    
    fun isConnected(): Boolean {
        return connectedThread != null && clientSocket?.isConnected == true
    }
    
    private fun manageConnectedSocket(socket: BluetoothSocket) {
        try {
            clientSocket = socket
            inputStream = socket.inputStream
            outputStream = socket.outputStream
            
            connectedThread = ConnectedThread()
            connectedThread?.start()
            
            Log.d(tag, "Socket managed successfully")
        } catch (e: IOException) {
            Log.e(tag, "Error managing socket", e)
        }
    }
    
    private inner class AcceptThread : Thread() {
        override fun run() {
            var socket: BluetoothSocket?
            
            while (isServerRunning) {
                try {
                    socket = serverSocket?.accept()
                    if (socket != null) {
                        Log.d(tag, "Incoming connection from: ${socket.remoteDevice.name} (${socket.remoteDevice.address})")
                        
                        // Cancel server socket to accept only one connection
                        serverSocket?.close()
                        isServerRunning = false
                        
                        connectedDevice = socket.remoteDevice
                        manageConnectedSocket(socket)
                        
                        notifyConnectionState(true, socket.remoteDevice.address, socket.remoteDevice.name ?: "Unknown")
                    }
                } catch (e: IOException) {
                    if (isServerRunning) {
                        Log.e(tag, "Error accepting connection", e)
                    }
                    break
                }
            }
        }
    }
    
    private inner class ConnectedThread : Thread() {
        private val buffer = ByteArray(1024)
        
        override fun run() {
            while (true) {
                try {
                    val bytes = inputStream?.read(buffer)
                    if (bytes != null && bytes > 0) {
                        val message = String(buffer, 0, bytes, Charsets.UTF_8)
                        Log.d(tag, "Received message: $message")
                        
                        mainHandler.post {
                            messageListener?.invoke(message)
                        }
                    }
                } catch (e: IOException) {
                    Log.e(tag, "Error reading from socket", e)
                    break
                }
            }
            
            // Connection lost
            disconnect()
        }
        
        fun write(bytes: ByteArray): Boolean {
            return try {
                outputStream?.write(bytes)
                outputStream?.flush()
                Log.d(tag, "Message sent: ${String(bytes, Charsets.UTF_8)}")
                true
            } catch (e: IOException) {
                Log.e(tag, "Error writing to socket", e)
                false
            }
        }
        
        fun cancel() {
            try {
                clientSocket?.close()
            } catch (e: IOException) {
                Log.e(tag, "Error closing socket", e)
            }
        }
    }
    
    private fun notifyConnectionState(connected: Boolean, address: String, name: String) {
        val state = mapOf(
            "connected" to connected,
            "deviceAddress" to address,
            "deviceName" to name
        )
        
        mainHandler.post {
            connectionStateListener?.invoke(state)
        }
    }
    
    fun shutdown() {
        isServerRunning = false
        disconnect()
        
        try {
            serverSocket?.close()
        } catch (e: IOException) {
            Log.e(tag, "Error closing server socket", e)
        }
        
        acceptThread?.interrupt()
        serverSocket = null
    }
}
