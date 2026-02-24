package com.offlink.app

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * WifiDirectManager — Data Plane (Messaging Transport)
 *
 * Implements Wi-Fi Direct (P2P) group negotiation and persistent TCP
 * socket communication for Offlink chat payload delivery.
 *
 * Architecture role:
 *   BLE  → discovers peers (UUID + username)
 *   Wi-Fi Direct → transports all chat messages
 *
 * Flow:
 *   1. Dart calls initiateConnection(targetDeviceName)
 *   2. discoverPeers() → WifiP2pBroadcastReceiver receives PEERS_CHANGED
 *   3. Peer with matching name is found → connect(WifiP2pConfig)
 *   4. WIFI_P2P_CONNECTION_CHANGED → requestConnectionInfo()
 *   5. Group Owner starts TCP server; client connects to GO IP
 *   6. Bidirectional line-delimited text over the socket
 */
class WifiDirectManager(private val context: Context) {

    private val tag = "OfflinkWifiDirect"

    // Wi-Fi P2P system components
    private var wifiP2pManager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null

    // Threading
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newCachedThreadPool()

    // Connection state
    private val isP2pEnabled = AtomicBoolean(false)
    private val isConnected = AtomicBoolean(false)
    private val isGroupOwner = AtomicBoolean(false)
    private var groupOwnerAddress: String? = null
    private var targetDeviceName: String? = null

    // Socket handles
    private var serverSocket: ServerSocket? = null
    private var activeSocket: Socket? = null
    private var socketWriter: BufferedWriter? = null
    private val isSocketActive = AtomicBoolean(false)

    // Peer list
    private val availablePeers = mutableListOf<WifiP2pDevice>()

    // Discovery retry state
    private val discoveryRetryCount = AtomicInteger(0)
    private val maxDiscoveryRetries = 4

    // Callbacks → Dart
    var peerListListener: ((List<Map<String, Any>>) -> Unit)? = null
    var connectionStateListener: ((Map<String, Any>) -> Unit)? = null
    var messageListener: ((String) -> Unit)? = null

    private var initialized = false

    companion object {
        const val TCP_PORT = 8988
        const val GROUP_OWNER_IP = "192.168.49.1"
    }

    // ═══════════════════════════════════════════════════════════════
    // Public API
    // ═══════════════════════════════════════════════════════════════

    fun initialize(): Boolean {
        if (initialized) return true

        wifiP2pManager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (wifiP2pManager == null) {
            Log.e(tag, "Wi-Fi P2P service not available on this device")
            return false
        }

        p2pChannel = wifiP2pManager!!.initialize(
            context,
            Looper.getMainLooper()
        ) {
            Log.w(tag, "Wi-Fi P2P channel disconnected — will attempt reinit")
            isConnected.set(false)
            isSocketActive.set(false)
            notifyConnectionState(connected = false, error = "P2P channel disconnected")
        }

        if (p2pChannel == null) {
            Log.e(tag, "Failed to initialize Wi-Fi P2P channel")
            return false
        }

        registerReceiver()
        initialized = true
        Log.d(tag, "WifiDirectManager initialised")
        return true
    }

    @SuppressLint("MissingPermission")
    fun discoverPeers(): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")
        val mgr = wifiP2pManager ?: return mapOf("success" to false, "error" to "Manager null")
        val ch  = p2pChannel   ?: return mapOf("success" to false, "error" to "Channel null")

        val attempt = discoveryRetryCount.get() + 1
        Log.d(tag, "Starting Wi-Fi Direct peer discovery… (attempt $attempt/$maxDiscoveryRetries)")
        mgr.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Peer discovery initiated successfully")
                discoveryRetryCount.set(0)
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Peer discovery failed: ${failureReason(reason)}")
                when {
                    reason == WifiP2pManager.BUSY &&
                    discoveryRetryCount.incrementAndGet() <= maxDiscoveryRetries -> {
                        // Framework is busy (previous operation still in flight).
                        // Back off and retry so auto-connect can eventually fire.
                        val delayMs = 1500L * discoveryRetryCount.get()
                        Log.d(tag, "Peer discovery BUSY — retrying in ${delayMs}ms " +
                              "(attempt ${discoveryRetryCount.get()}/$maxDiscoveryRetries)")
                        mainHandler.postDelayed({ discoverPeers() }, delayMs)
                    }
                    else -> {
                        discoveryRetryCount.set(0)
                        if (reason != WifiP2pManager.BUSY) {
                            notifyConnectionState(
                                connected = false,
                                error = "Peer discovery failed: ${failureReason(reason)}"
                            )
                        }
                        // Max retries exhausted for BUSY — notify dart
                        if (reason == WifiP2pManager.BUSY) {
                            notifyConnectionState(
                                connected = false,
                                error = "Peer discovery unavailable (framework busy after $maxDiscoveryRetries retries)"
                            )
                        }
                    }
                }
            }
        })
        return mapOf("success" to true)
    }

    /**
     * Initiate a Wi-Fi Direct connection to the peer whose Wi-Fi name
     * matches [targetName].  If the peer list is empty, peer discovery is
     * started first and auto-connect will fire when a matching peer appears.
     */
    @SuppressLint("MissingPermission")
    fun initiateConnection(targetName: String): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")

        targetDeviceName = targetName
        discoveryRetryCount.set(0)   // reset retry counter for this new attempt
        Log.d(tag, "Initiate connection to peer with name: '$targetName'")

        // Already connected?
        if (isConnected.get() && isSocketActive.get()) {
            Log.d(tag, "Already connected — no action needed")
            return mapOf("success" to true, "alreadyConnected" to true)
        }

        // Try to find matching peer in current list
        synchronized(availablePeers) {
            val peer = availablePeers.firstOrNull {
                it.deviceName.contains(targetName, ignoreCase = true)
            }
            if (peer != null) {
                Log.d(tag, "Found matching peer immediately: ${peer.deviceName}")
                return connectToPeer(peer.deviceAddress)
            }
        }

        // Peers not yet discovered — start discovery; auto-connect fires in broadcast receiver
        Log.d(tag, "No matching peer in cache — starting peer discovery…")
        discoverPeers()
        return mapOf("success" to true, "waiting" to true)
    }

    /**
     * Connect to a specific Wi-Fi Direct peer by its P2P MAC address.
     */
    @SuppressLint("MissingPermission")
    fun connectToPeer(deviceAddress: String): Map<String, Any> {
        val mgr = wifiP2pManager ?: return mapOf("success" to false, "error" to "Manager null")
        val ch  = p2pChannel   ?: return mapOf("success" to false, "error" to "Channel null")

        Log.d(tag, "Connecting to Wi-Fi Direct peer: $deviceAddress")
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
        }

        mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Wi-Fi Direct connection request sent to $deviceAddress")
                notifyConnectionState(connected = false, status = "connecting")
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Wi-Fi Direct connection to $deviceAddress failed: ${failureReason(reason)}")
                notifyConnectionState(connected = false, error = "Connect failed: ${failureReason(reason)}")
            }
        })
        return mapOf("success" to true)
    }

    /**
     * Send a message over the active Wi-Fi Direct socket.
     * Messages are newline-delimited UTF-8 strings.
     */
    fun sendMessage(message: String): Boolean {
        if (!isSocketActive.get()) {
            Log.e(tag, "sendMessage: socket is not active")
            return false
        }
        val w = socketWriter ?: run {
            Log.e(tag, "sendMessage: writer is null")
            return false
        }
        executor.execute {
            try {
                w.write(message)
                w.newLine()
                w.flush()
                Log.d(tag, "Message sent via Wi-Fi Direct socket (${message.length} chars)")
            } catch (e: Exception) {
                Log.e(tag, "Error writing to socket", e)
                handleSocketError(e)
            }
        }
        return true
    }

    fun isConnected(): Boolean = isConnected.get()
    fun isSocketActive(): Boolean = isSocketActive.get()
    fun isGroupOwner(): Boolean = isGroupOwner.get()
    fun getGroupOwnerAddress(): String? = groupOwnerAddress
    fun isP2pEnabled(): Boolean = isP2pEnabled.get()

    /**
     * Convenience alias used by MainActivity to initiate connection by name.
     * Delegates to [initiateConnection].
     */
    fun connectByName(targetName: String) {
        initiateConnection(targetName)
    }

    /**
     * Return current group info as a Dart-friendly map.
     */
    @SuppressLint("MissingPermission")
    fun getGroupInfo(): Map<String, Any>? {
        if (!isConnected.get()) return null
        var result: Map<String, Any>? = null
        val latch = java.util.concurrent.CountDownLatch(1)
        wifiP2pManager?.requestGroupInfo(p2pChannel) { group ->
            if (group != null) {
                result = mapOf(
                    "isGroupOwner" to group.isGroupOwner,
                    "networkName"  to (group.networkName ?: ""),
                    "passphrase"   to (group.passphrase ?: ""),
                    "ownerAddress" to group.owner.deviceAddress,
                    "clientCount"  to group.clientList.size
                )
            }
            latch.countDown()
        }
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        return result
    }

    fun startDiscovery() { discoverPeers() }

    fun stopDiscovery() {
        val mgr = wifiP2pManager ?: return
        val ch  = p2pChannel   ?: return
        mgr.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Peer discovery stopped")
            }
            override fun onFailure(reason: Int) {
                Log.w(tag, "stopPeerDiscovery failed: ${failureReason(reason)}")
            }
        })
    }

    fun disconnect() {
        Log.d(tag, "Disconnecting Wi-Fi Direct…")
        targetDeviceName = null
        closeSocket()

        val mgr = wifiP2pManager
        val ch  = p2pChannel
        if (mgr != null && ch != null) {
            @SuppressLint("MissingPermission")
            fun remove() = mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(tag, "Wi-Fi P2P group removed")
                    resetState()
                    notifyConnectionState(connected = false)
                }
                override fun onFailure(reason: Int) {
                    Log.w(tag, "removeGroup failed: ${failureReason(reason)}")
                    resetState()
                }
            })
            remove()
        } else {
            resetState()
        }
    }

    fun shutdown() {
        Log.d(tag, "Shutting down WifiDirectManager")
        disconnect()
        unregisterReceiver()
        try { executor.shutdownNow() } catch (_: Exception) {}
        initialized = false
    }

    // ═══════════════════════════════════════════════════════════════
    // Socket management
    // ═══════════════════════════════════════════════════════════════

    private fun startSocketServer() {
        Log.d(tag, "Wi-Fi P2P: I am Group Owner — starting TCP server on port $TCP_PORT")

        notifyConnectionState(
            connected = true,
            role = "group_owner",
            ipAddress = GROUP_OWNER_IP,
            socketActive = false
        )

        executor.execute {
            try {
                closeSocket()
                val srv = ServerSocket(TCP_PORT)
                serverSocket = srv
                Log.d(tag, "TCP server listening…")

                val client = srv.accept()
                Log.d(tag, "Wi-Fi Direct client connected to TCP server")
                activeSocket = client
                initSocketStreams(client)

            } catch (e: Exception) {
                if (isConnected.get()) {
                    Log.e(tag, "TCP server error", e)
                    handleSocketError(e)
                }
            }
        }
    }

    private fun startSocketClient(goIp: String) {
        Log.d(tag, "Wi-Fi P2P: I am Client — connecting TCP to Group Owner at $goIp:$TCP_PORT")

        notifyConnectionState(
            connected = true,
            role = "client",
            ipAddress = goIp,
            socketActive = false
        )

        executor.execute {
            val maxAttempts = 12
            var attempt = 0
            while (attempt < maxAttempts && !isSocketActive.get()) {
                attempt++
                try {
                    Thread.sleep(1000)
                    val sock = Socket(goIp, TCP_PORT)
                    activeSocket = sock
                    Log.d(tag, "TCP connected to GO at $goIp:$TCP_PORT (attempt $attempt)")
                    initSocketStreams(sock)
                    break
                } catch (e: Exception) {
                    Log.w(tag, "TCP connect attempt $attempt/$maxAttempts failed: ${e.message}")
                    if (attempt >= maxAttempts) {
                        Log.e(tag, "All TCP connect attempts exhausted")
                        handleSocketError(e)
                    }
                }
            }
        }
    }

    private fun initSocketStreams(sock: Socket) {
        try {
            socketWriter = BufferedWriter(OutputStreamWriter(sock.getOutputStream(), "UTF-8"))
            val reader   = BufferedReader(InputStreamReader(sock.getInputStream(), "UTF-8"))
            isSocketActive.set(true)

            Log.d(tag, "Wi-Fi Direct socket streams ready")

            // Notify Dart: fully connected and socket live
            mainHandler.post {
                notifyConnectionState(
                    connected = true,
                    role = if (isGroupOwner.get()) "group_owner" else "client",
                    ipAddress = groupOwnerAddress,
                    socketActive = true
                )
            }

            // Receive loop
            executor.execute {
                try {
                    while (isSocketActive.get()) {
                        val line = reader.readLine() ?: break
                        Log.d(tag, "Wi-Fi Direct received: ${line.take(80)}")
                        mainHandler.post { messageListener?.invoke(line) }
                    }
                } catch (e: Exception) {
                    if (isSocketActive.get()) {
                        Log.e(tag, "Socket read error", e)
                        handleSocketError(e)
                    }
                }
                Log.d(tag, "Wi-Fi Direct receive loop ended")
            }

        } catch (e: Exception) {
            Log.e(tag, "initSocketStreams error", e)
            handleSocketError(e)
        }
    }

    private fun closeSocket() {
        isSocketActive.set(false)
        try { socketWriter?.close() } catch (_: Exception) {}
        try { activeSocket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        socketWriter = null
        activeSocket = null
        serverSocket = null
    }

    private fun resetState() {
        isConnected.set(false)
        isGroupOwner.set(false)
        groupOwnerAddress = null
        isSocketActive.set(false)
    }

    private fun handleSocketError(e: Exception) {
        Log.e(tag, "Socket error: ${e.message}")
        closeSocket()
        isConnected.set(false)
        mainHandler.post {
            notifyConnectionState(connected = false, error = "Socket error: ${e.message}")
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // Broadcast Receiver
    // ═══════════════════════════════════════════════════════════════

    private fun registerReceiver() {
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        receiver = WifiP2pBroadcastReceiver()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            Log.d(tag, "Wi-Fi P2P broadcast receiver registered")
        } catch (e: Exception) {
            Log.e(tag, "Failed to register broadcast receiver", e)
        }
    }

    private fun unregisterReceiver() {
        try {
            receiver?.let { context.unregisterReceiver(it) }
            receiver = null
        } catch (_: Exception) {}
    }

    // ═══════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════

    private fun notifyConnectionState(
        connected: Boolean,
        role: String?    = null,
        ipAddress: String? = null,
        socketActive: Boolean? = null,
        status: String?  = null,
        error: String?   = null
    ) {
        val map = mutableMapOf<String, Any>("connected" to connected)
        role?.let         { map["role"]         = it }
        ipAddress?.let    { map["ipAddress"]    = it }
        socketActive?.let { map["socketActive"] = it }
        status?.let       { map["status"]       = it }
        error?.let        { map["error"]        = it }
        mainHandler.post { connectionStateListener?.invoke(map) }
    }

    private fun failureReason(reason: Int) = when (reason) {
        WifiP2pManager.P2P_UNSUPPORTED -> "P2P unsupported"
        WifiP2pManager.BUSY            -> "Busy"
        WifiP2pManager.ERROR           -> "Internal error"
        else                           -> "Unknown ($reason)"
    }

    // ═══════════════════════════════════════════════════════════════
    // Inner: BroadcastReceiver
    // ═══════════════════════════════════════════════════════════════

    @SuppressLint("MissingPermission")
    inner class WifiP2pBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {

                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    isP2pEnabled.set(state == WifiP2pManager.WIFI_P2P_STATE_ENABLED)
                    Log.d(tag, "Wi-Fi P2P state: ${if (isP2pEnabled.get()) "ENABLED" else "DISABLED"}")
                }

                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    Log.d(tag, "Wi-Fi P2P peers changed — requesting list…")
                    wifiP2pManager?.requestPeers(p2pChannel) { peerList ->
                        handlePeerListUpdate(peerList)
                    }
                }

                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val networkInfo = extractNetworkInfo(intent)
                    if (networkInfo?.isConnected == true) {
                        Log.d(tag, "Wi-Fi P2P network connected — requesting connection info…")
                        wifiP2pManager?.requestConnectionInfo(p2pChannel) { info ->
                            handleConnectionInfo(info)
                        }
                    } else {
                        Log.d(tag, "Wi-Fi P2P network disconnected")
                        closeSocket()
                        resetState()
                        notifyConnectionState(connected = false)
                    }
                }

                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                    val device = extractThisDevice(intent)
                    Log.d(tag, "This device info: ${device?.deviceName} (${device?.deviceAddress})")
                }
            }
        }

        private fun extractNetworkInfo(intent: Intent): NetworkInfo? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO, NetworkInfo::class.java)
            else
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO)

        private fun extractThisDevice(intent: Intent): WifiP2pDevice? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_DEVICE, WifiP2pDevice::class.java)
            else
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_DEVICE)
    }

    // ═══════════════════════════════════════════════════════════════
    // Peer & connection info handlers
    // ═══════════════════════════════════════════════════════════════

    @SuppressLint("MissingPermission")
    private fun handlePeerListUpdate(peerList: WifiP2pDeviceList) {
        synchronized(availablePeers) {
            availablePeers.clear()
            availablePeers.addAll(peerList.deviceList)
        }

        Log.d(tag, "Wi-Fi P2P discovered ${availablePeers.size} peer(s):")
        for (p in availablePeers) {
            Log.d(tag, "  • ${p.deviceName} (${p.deviceAddress}) status=${p.status}")
        }

        // Notify Dart
        val peersForDart = availablePeers.map { peer ->
            mapOf(
                "deviceName"    to peer.deviceName,
                "deviceAddress" to peer.deviceAddress,
                "status"        to peer.status
            )
        }
        mainHandler.post { peerListListener?.invoke(peersForDart) }

        // Auto-connect if we have a pending target name
        val target = targetDeviceName
        if (target != null && !isConnected.get()) {
            val match = synchronized(availablePeers) {
                availablePeers.firstOrNull {
                    it.deviceName.contains(target, ignoreCase = true)
                }
            }
            if (match != null) {
                Log.d(tag, "Auto-connecting to matching peer: ${match.deviceName}")
                connectToPeer(match.deviceAddress)
            } else {
                Log.w(tag, "No peer matching '$target' found. Available: ${availablePeers.map { it.deviceName }}")
            }
        }
    }

    private fun handleConnectionInfo(info: WifiP2pInfo) {
        Log.d(
            tag,
            "Wi-Fi P2P connection info: groupFormed=${info.groupFormed}, " +
            "isGroupOwner=${info.isGroupOwner}, " +
            "groupOwnerAddress=${info.groupOwnerAddress?.hostAddress}"
        )

        if (!info.groupFormed) {
            Log.w(tag, "Group not yet formed, waiting…")
            return
        }

        isConnected.set(true)
        isGroupOwner.set(info.isGroupOwner)
        groupOwnerAddress = info.groupOwnerAddress?.hostAddress

        Log.d(
            tag,
            "Wi-Fi Direct group formed! " +
            "Role: ${if (info.isGroupOwner) "GROUP OWNER" else "CLIENT"}, " +
            "GO address: $groupOwnerAddress"
        )

        if (info.isGroupOwner) {
            startSocketServer()
        } else {
            val goIp = groupOwnerAddress
            if (goIp != null) {
                startSocketClient(goIp)
            } else {
                Log.e(tag, "Group owner IP is null — cannot establish socket")
                notifyConnectionState(connected = false, error = "Group owner IP unavailable")
            }
        }
    }
}
