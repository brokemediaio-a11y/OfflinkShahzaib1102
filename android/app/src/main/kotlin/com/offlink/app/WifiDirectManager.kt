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
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
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
import java.util.concurrent.atomic.AtomicReference

/**
 * WiFi Direct connection phase — strict state machine.
 *
 * All transitions are driven ONLY by:
 *   - System broadcast callbacks (WIFI_P2P_CONNECTION_CHANGED_ACTION)
 *   - WifiP2pInfo callbacks (onConnectionInfoAvailable)
 *   - Socket success / failure events
 *
 * NO optimistic state. NO simple isConnected booleans.
 */
enum class ConnectionPhase {
    IDLE,               // Initial / fully reset state
    DISCOVERING,        // discoverPeers() initiated
    CONNECTING,         // connect() request sent to WifiP2pManager
    GROUP_FORMED,       // groupFormed == true in onConnectionInfoAvailable
    SOCKET_CONNECTING,  // Socket thread started (ServerSocket listening / client dialing)
    SOCKET_CONNECTED,   // socket.isConnected == true, streams open → ONLY valid connected state
    DISCONNECTED,       // Explicit disconnect or broadcast disconnect event
    FAILED              // Unrecoverable error — must reconnect from scratch
}

/**
 * WifiDirectManager — Data Plane (Messaging Transport)
 *
 * Architecture role:
 *   BLE  → discovers peers (UUID + username) — control plane only
 *   Wi-Fi Direct → transports all chat messages — data plane
 *
 * Correct connection flow:
 *   1. Dart calls initiateConnection(targetDeviceName)
 *   2. discoverPeers() → PEERS_CHANGED broadcast → handlePeerListUpdate()
 *   3. Matching peer found → connect(WifiP2pConfig) → phase = CONNECTING
 *   4. CONNECTION_CHANGED broadcast → networkInfo.isConnected == true
 *   5. requestConnectionInfo() → groupFormed == true → phase = GROUP_FORMED
 *   6. Group Owner: start ServerSocket → phase = SOCKET_CONNECTING
 *      Client: dial groupOwnerAddress → phase = SOCKET_CONNECTING
 *   7. Socket connected → phase = SOCKET_CONNECTED → notify Dart
 *   8. Dart opens Chat screen ONLY after SOCKET_CONNECTED
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

    // ── State Machine ────────────────────────────────────────────────────────
    // Single source of truth. NO other flags drive connection logic.
    private val connectionPhase = AtomicReference(ConnectionPhase.IDLE)

    private val isP2pEnabled = AtomicBoolean(false)
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

    // Safety timeout: reset if we stay CONNECTING with no response for 15 s
    private var connectingTimeoutRunnable: Runnable? = null

    // Auto-retry counter — resets on a fresh user-initiated connect or disconnect
    private val connectRetryCount = AtomicInteger(0)
    private val maxConnectRetries = 5   // covers stale-INVITED cleanup + simultaneous-tap deadlock

    // ─── Passive Discovery Heartbeat ──────────────────────────────────────────
    // Android's discoverPeers() has an internal expiry (~60-120 s on most OEMs).
    // After it expires the device stops beaconing, making it invisible to remote
    // scans even though the app is running.  Re-running it every 60 s keeps this
    // device discoverable without any user interaction, enabling the one-tap
    // "initiator-only" connect flow.
    private val passiveDiscoveryIntervalMs = 60_000L
    private var passiveDiscoveryRunnable: Runnable? = null

    // Callbacks → Dart
    var peerListListener: ((List<Map<String, Any>>) -> Unit)? = null
    var connectionStateListener: ((Map<String, Any>) -> Unit)? = null
    var messageListener: ((String) -> Unit)? = null
    /** Fires on the receiving side when a remote device sends a Wi-Fi Direct invitation.
     *  Payload: { "deviceName": String, "deviceAddress": String }
     *  Flutter must respond within 30 s by calling acceptInvitation() or rejectInvitation().
     */
    var incomingInvitationListener: ((Map<String, Any>) -> Unit)? = null

    // ── Pending incoming invitation ────────────────────────────────────────────
    // Stores the peer whose WPS-PBC invitation is awaiting user consent.
    // Cleared on accept, reject, reset, or 30-second timeout.
    private var pendingInvitedPeer: WifiP2pDevice? = null
    private var invitationTimeoutRunnable: Runnable? = null

    private var initialized = false

    // Device name to apply once the p2pChannel is ready (set before initialize() completes)
    private var pendingDeviceName: String? = null

    // ── UUID-based peer identity ───────────────────────────────────────────────
    // The OffLink UUID is the single authoritative identity for every device.
    // Wi-Fi Direct MAC addresses are OEM-controlled strings that must NEVER leave
    // the native layer — the Dart side works exclusively with UUIDs.
    //
    // Connection flow:
    //   1. Each device advertises its UUID via Wi-Fi Direct DNS-SD (Bonjour).
    //   2. connectByUuid() runs DNS-SD service discovery to find the peer's MAC.
    //   3. connectToPeer(mac) is called internally — MAC never surfaces to Dart.
    //   4. Falls back to name-based initiateConnection() after 15 s if DNS-SD
    //      doesn't respond (handles OEM firmware bugs in DNS-SD stack).

    /** This device's OffLink UUID — set via setOwnUuid() and advertised over DNS-SD. */
    private var ownUuid: String? = null

    /** UUID of the peer we are currently trying to connect to. */
    private var targetUuid: String? = null

    /** Timeout runnable that fires if DNS-SD service discovery finds nothing in 15 s. */
    private var serviceDiscoveryTimeoutRunnable: Runnable? = null

    companion object {
        const val TCP_PORT = 8988
        const val GROUP_OWNER_IP = "192.168.49.1"
    }

    // ═══════════════════════════════════════════════════════════════
    // Public API
    // ═══════════════════════════════════════════════════════════════

    /**
     * Initialise the Wi-Fi Direct stack.
     *
     * [deviceUuid] — this device's OffLink UUID.  When provided it is
     * immediately registered as a DNS-SD Bonjour service so remote devices
     * can discover and connect to us by UUID without relying on the OEM
     * device-name string (which is not under app control on newer Android).
     */
    @SuppressLint("MissingPermission")
    fun initialize(deviceUuid: String? = null): Boolean {
        if (initialized) {
            // If a UUID was not set on the first call, allow a late registration.
            if (deviceUuid != null && ownUuid == null) setOwnUuid(deviceUuid)
            return true
        }

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
            connectionPhase.set(ConnectionPhase.DISCONNECTED)
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

        // Apply any device name that was requested before the channel was ready.
        pendingDeviceName?.let { name ->
            pendingDeviceName = null
            setDeviceName(name)
        }

        // Register UUID as a DNS-SD service so peers can discover us by UUID.
        if (deviceUuid != null) {
            setOwnUuid(deviceUuid)
        }

        // ── Clean up any stale group from a previous session ─────────────────
        // If the app was killed while a Wi-Fi Direct group was active, the
        // Android framework keeps that group alive.  Peers will then show as
        // INVITED or CONNECTED on the next launch, causing a spurious infinite
        // connect-loop before any user action.  Remove the group first; start
        // passive discovery only after the framework confirms a clean slate.
        wifiP2pManager!!.removeGroup(p2pChannel!!, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Stale Wi-Fi Direct group removed — starting passive discovery")
                mainHandler.postDelayed({ discoverPeers() }, 1000)
            }
            override fun onFailure(reason: Int) {
                // No group to remove — that is fine; start discovery normally.
                Log.d(tag, "No stale group on init (${failureReason(reason)}) — starting passive discovery")
                mainHandler.postDelayed({ discoverPeers() }, 1000)
            }
        })

        // Start the passive-discovery heartbeat so this device keeps broadcasting
        // its Wi-Fi Direct beacon even when the user never taps "Scan for Devices".
        schedulePassiveDiscovery()

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
                // Only advance to DISCOVERING if we are not already further along
                val phase = connectionPhase.get()
                if (phase == ConnectionPhase.IDLE || phase == ConnectionPhase.DISCONNECTED ||
                    phase == ConnectionPhase.FAILED) {
                    connectionPhase.set(ConnectionPhase.DISCOVERING)
                }

                // ── Proactive INVITED-peer check ──────────────────────────────
                // On some OEM devices (e.g. Infinix SMART 7 HD) the framework
                // does NOT reliably fire PEERS_CHANGED for spontaneous invitations
                // received while the device is in passive-discovery mode.
                // By explicitly requesting the peer list 500 ms after discovery
                // starts we catch any INVITED peer that arrived while we were
                // restarting, enabling true one-tap connection.
                mainHandler.postDelayed({
                    val ph = connectionPhase.get()
                    if (ph != ConnectionPhase.CONNECTING &&
                        ph != ConnectionPhase.GROUP_FORMED &&
                        ph != ConnectionPhase.SOCKET_CONNECTING &&
                        ph != ConnectionPhase.SOCKET_CONNECTED) {
                        Log.d(tag, "Post-discovery probe: checking for INVITED peers…")
                        wifiP2pManager?.requestPeers(p2pChannel) { peerList ->
                            handlePeerListUpdate(peerList)
                        }
                    }
                }, 500)
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Peer discovery failed: ${failureReason(reason)}")
                when {
                    reason == WifiP2pManager.BUSY &&
                    discoveryRetryCount.incrementAndGet() <= maxDiscoveryRetries -> {
                        val delayMs = 1500L * discoveryRetryCount.get()
                        Log.d(tag, "Peer discovery BUSY — retrying in ${delayMs}ms " +
                              "(attempt ${discoveryRetryCount.get()}/$maxDiscoveryRetries)")
                        mainHandler.postDelayed({ discoverPeers() }, delayMs)
                    }
                    else -> {
                        discoveryRetryCount.set(0)
                        val errorMsg = if (reason == WifiP2pManager.BUSY)
                            "Peer discovery unavailable (framework busy after $maxDiscoveryRetries retries)"
                        else
                            "Peer discovery failed: ${failureReason(reason)}"
                        connectionPhase.set(ConnectionPhase.FAILED)
                        notifyConnectionState(connected = false, error = errorMsg)
                    }
                }
            }
        })
        return mapOf("success" to true)
    }

    /**
     * Initiate a Wi-Fi Direct connection to the peer whose Wi-Fi name
     * matches [targetName].
     *
     * This call returns immediately. The actual connection sequence is
     * driven by system broadcasts and callbacks. Flutter MUST wait for
     * a SOCKET_CONNECTED event before opening the Chat screen.
     */
    @SuppressLint("MissingPermission")
    fun initiateConnection(targetName: String): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")

        targetDeviceName = targetName
        discoveryRetryCount.set(0)
        connectRetryCount.set(0)   // fresh user-initiated attempt — reset retry counter
        Log.d(tag, "Initiate connection to peer with name: '$targetName'")

        // ── Guard: only skip if we have a live, working socket connection ──────
        // Any state short of SOCKET_CONNECTED must attempt (re)connection.
        if (connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTED) {
            Log.d(tag, "Already socket-connected — no action needed")
            return mapOf("success" to true, "alreadyConnected" to true)
        }

        // If we are mid-connection (CONNECTING or SOCKET_CONNECTING), allow it
        // to complete rather than kicking off a redundant attempt.
        val phase = connectionPhase.get()
        if (phase == ConnectionPhase.CONNECTING || phase == ConnectionPhase.SOCKET_CONNECTING ||
            phase == ConnectionPhase.GROUP_FORMED) {
            Log.d(tag, "Connection already in progress (phase=$phase) — waiting for callbacks")
            return mapOf("success" to true, "waiting" to true)
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

        // ── Guard: prevent concurrent / duplicate connect() calls ────────────
        // handlePeerListUpdate can be called twice in quick succession (two rapid
        // PEERS_CHANGED broadcasts) before the async onSuccess flips the phase.
        // If we are already negotiating, silently ignore the duplicate.
        val currentPhase = connectionPhase.get()
        if (currentPhase == ConnectionPhase.CONNECTING ||
            currentPhase == ConnectionPhase.GROUP_FORMED ||
            currentPhase == ConnectionPhase.SOCKET_CONNECTING ||
            currentPhase == ConnectionPhase.SOCKET_CONNECTED) {
            Log.d(tag, "connectToPeer: already in $currentPhase — ignoring duplicate call for $deviceAddress")
            return mapOf("success" to true, "duplicate" to true)
        }

        Log.d(tag, "connect() called — target MAC: $deviceAddress")
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
        }

        mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Wi-Fi Direct connect() request accepted for $deviceAddress")
                connectionPhase.set(ConnectionPhase.CONNECTING)
                notifyConnectionState(connected = false, status = "connecting")

                // Safety net: if no GROUP_FORMED within 15 s, auto-retry with
                // exponential back-off to break the scan-scan collision where both
                // devices are simultaneously scanning and neither is listening.
                // After maxConnectRetries failures we give up and report an error.
                connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                connectingTimeoutRunnable = Runnable {
                    if (connectionPhase.get() != ConnectionPhase.CONNECTING) return@Runnable

                    val attempt = connectRetryCount.incrementAndGet()
                    Log.w(tag, "⏰ CONNECTING timeout — attempt $attempt/$maxConnectRetries")

                    // ── Check if the peer itself has sent us an invitation ────────
                    // Handles the simultaneous-tap scenario: both devices called
                    // connect() at the same time and each blocked the other's attempt.
                    // If our peer is now showing as INVITED in the peer list, accept
                    // their invitation directly instead of retrying from scratch.
                    // ⚠️  Filter by savedTarget (= targetDeviceName before reset) so we
                    // never accidentally accept an invitation from the wrong device when
                    // multiple peers are visible (e.g. connecting to Techno while Infinix
                    // is also in INVITED state from an unrelated session).
                    val invitedByPeer = synchronized(availablePeers) {
                        val target = targetDeviceName // capture before potential null from reset
                        availablePeers.firstOrNull { peer ->
                            peer.status == WifiP2pDevice.INVITED &&
                            (target == null || peer.deviceName.contains(target, ignoreCase = true))
                        }
                    }

                    // Save targetDeviceName BEFORE resetState() clears it.
                    // Retries need it to know which peer to auto-connect to.
                    val savedTarget = targetDeviceName
                    closeSocket()
                    resetState() // targetDeviceName is now null; restore it below for retries

                    if (invitedByPeer != null && attempt < maxConnectRetries) {
                        // Accept the peer's invitation.
                        // ⚠️  Do NOT reset connectRetryCount here — invitation attempts
                        // must count toward maxConnectRetries to prevent an infinite loop
                        // caused by a stale INVITED state from a previous session.
                        Log.d(tag, "⏰ Timeout: peer already invited us — accepting ${invitedByPeer.deviceName}'s invitation (attempt $attempt/$maxConnectRetries)")
                        targetDeviceName = savedTarget // restore so auto-connect guard works
                        connectToPeer(invitedByPeer.deviceAddress)
                        return@Runnable
                    }

                    if (attempt >= maxConnectRetries) {
                        // Exhausted retries — give up (targetDeviceName already null from resetState).
                        Log.e(tag, "Max connect retries ($maxConnectRetries) reached — giving up")
                        connectRetryCount.set(0)

                        if (savedTarget != null) {
                            // User tapped a device — tell Flutter so the UI can show an error.
                            notifyConnectionState(connected = false, error = "Connection failed after $attempt attempts")
                        } else {
                            // Passive INVITED acceptance failed (likely stale state from a
                            // previous session). Do NOT surface an error to the user —
                            // just silently restart passive discovery.
                            Log.w(tag, "Passive INVITED acceptance exhausted — clearing stale state and restarting discovery")
                            mainHandler.postDelayed({ discoverPeers() }, 2000)
                        }
                    } else {
                        // Keep the UI in "connecting" state — retry silently.
                        // Restore targetDeviceName so auto-connect fires when peers are found.
                        // Use increasing back-off so the two devices don't stay
                        // in lock-step scan-scan cycles.
                        targetDeviceName = savedTarget
                        notifyConnectionState(connected = false, status = "connecting")
                        val delayMs = 3000L + (attempt * 2000L) // 5 s, 7 s, …
                        Log.d(tag, "Auto-retrying Wi-Fi Direct discovery in ${delayMs}ms…")
                        mainHandler.postDelayed({ discoverPeers() }, delayMs)
                    }
                }.also { mainHandler.postDelayed(it, 15_000) }
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Wi-Fi Direct connect() to $deviceAddress failed: ${failureReason(reason)}")
                connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                connectingTimeoutRunnable = null
                connectionPhase.set(ConnectionPhase.FAILED)
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
        if (connectionPhase.get() != ConnectionPhase.SOCKET_CONNECTED) {
            Log.e(tag, "sendMessage: not socket-connected (phase=${connectionPhase.get()})")
            return false
        }
        if (!isSocketActive.get()) {
            Log.e(tag, "sendMessage: isSocketActive is false")
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

    /** True only when a TCP socket is confirmed open. */
    fun isConnected(): Boolean = connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTED

    fun isSocketActive(): Boolean = isSocketActive.get()
    fun isGroupOwner(): Boolean = isGroupOwner.get()
    fun getGroupOwnerAddress(): String? = groupOwnerAddress
    fun isP2pEnabled(): Boolean = isP2pEnabled.get()
    fun getConnectionPhase(): String = connectionPhase.get().name

    // ─── UUID-based connection via Wi-Fi Direct DNS-SD ────────────────────────

    /**
     * Set this device's OffLink UUID and register it as a Wi-Fi Direct
     * DNS-SD (Bonjour) service so that remote devices can discover us by UUID.
     *
     * Safe to call before or after [initialize].  If the P2P channel is not
     * yet ready the service will be registered once [initialize] completes.
     */
    fun setOwnUuid(uuid: String) {
        if (uuid.isBlank()) return
        ownUuid = uuid
        Log.d(tag, "setOwnUuid: $uuid")
        if (initialized && p2pChannel != null) {
            registerLocalService(uuid)
        }
        // If not yet initialised, initialize() will call setOwnUuid() again
        // after the channel is ready (via the deviceUuid parameter).
    }

    /**
     * Register this device's UUID as a Wi-Fi Direct DNS-SD Bonjour service.
     *
     * Remote devices can query "_offlink._tcp" services and read the "uuid"
     * TXT record to discover our MAC address without any BLE MAC exchange.
     */
    @SuppressLint("MissingPermission")
    private fun registerLocalService(uuid: String) {
        val mgr = wifiP2pManager ?: return
        val ch  = p2pChannel   ?: return

        // First remove any stale registration to avoid duplicate-service errors
        // on devices that cache the local service across initialise() calls.
        mgr.clearLocalServices(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { addService(mgr, ch, uuid) }
            override fun onFailure(r: Int) { addService(mgr, ch, uuid) } // best-effort
        })
    }

    @SuppressLint("MissingPermission")
    private fun addService(mgr: WifiP2pManager, ch: WifiP2pManager.Channel, uuid: String) {
        val record      = mapOf("uuid" to uuid)
        val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(uuid, "_offlink._tcp", record)
        mgr.addLocalService(ch, serviceInfo, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "✅ DNS-SD service registered: uuid=$uuid")
            }
            override fun onFailure(reason: Int) {
                Log.w(tag, "⚠️ DNS-SD service registration failed (${failureReason(reason)}) — " +
                           "peers will fall back to name-based discovery")
            }
        })
    }

    /**
     * Connect to a peer identified by its OffLink [targetUuid].
     *
     * Primary path: Wi-Fi Direct DNS-SD service discovery resolves the UUID
     * to a P2P MAC address internally, then calls connectToPeer(mac).
     * The MAC address never surfaces to the Dart layer.
     *
     * Fallback (after 15 s if DNS-SD yields no result): name-based peer
     * matching against [fallbackName] — works on devices whose Wi-Fi Direct
     * name happens to contain the username, or after setDeviceName() succeeds.
     */
    @SuppressLint("MissingPermission")
    fun connectByUuid(targetUuid: String, fallbackName: String) {
        if (!initialized) {
            Log.w(tag, "connectByUuid: not initialised")
            return
        }
        val mgr = wifiP2pManager ?: return
        val ch  = p2pChannel   ?: return

        Log.d(tag, "connectByUuid: UUID=$targetUuid, fallback='$fallbackName'")

        // ── Guard: already connected / connecting ────────────────────────────
        if (connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTED) {
            Log.d(tag, "Already socket-connected — no action needed"); return
        }
        val phase = connectionPhase.get()
        if (phase == ConnectionPhase.CONNECTING || phase == ConnectionPhase.SOCKET_CONNECTING ||
            phase == ConnectionPhase.GROUP_FORMED) {
            Log.d(tag, "Connection already in progress ($phase) — waiting"); return
        }

        this.targetUuid       = targetUuid
        this.targetDeviceName = fallbackName
        discoveryRetryCount.set(0)
        connectRetryCount.set(0)

        // ── Step 1: check peer cache — already have someone advertising UUID? ─
        // DNS-SD response listeners are persistent; if a prior discovery already
        // populated the cache and the device is visible, skip re-discovery.
        synchronized(availablePeers) {
            // We only have name in the peer cache; UUID→MAC is not pre-cached.
            // We must run DNS-SD discovery. However, if the peer's Wi-Fi Direct
            // name already contains the UUID (i.e. setDeviceName succeeded on
            // their side), short-circuit directly.
            val peer = availablePeers.firstOrNull {
                it.deviceName.contains(targetUuid, ignoreCase = true)
            }
            if (peer != null) {
                Log.d(tag, "connectByUuid: UUID found in peer name immediately — connecting")
                this.targetUuid = null
                connectToPeer(peer.deviceAddress)
                return
            }
        }

        // ── Step 2: DNS-SD service discovery ────────────────────────────────
        // Android fires TWO callbacks for every Bonjour service response:
        //   DnsSdServiceResponseListener  → (instanceName, registrationType, srcDevice)
        //   DnsSdTxtRecordListener        → (fullDomainName, txtRecordMap, srcDevice)
        // We match via BOTH so either one triggers the connect.
        // instanceName = UUID (registered via WifiP2pDnsSdServiceInfo.newInstance(uuid, ...))
        // txtRecordMap["uuid"] = UUID (TXT record set in the service info map)
        mgr.setDnsSdResponseListeners(
            ch,
            // ── Service response: instanceName is the UUID we registered ──
            WifiP2pManager.DnsSdServiceResponseListener { instanceName, _, srcDevice ->
                Log.d(tag, "DNS-SD service: instance=$instanceName, mac=${srcDevice.deviceAddress}")
                if (instanceName == this.targetUuid) {
                    Log.d(tag, "✅ UUID match via DNS-SD service name: $instanceName → ${srcDevice.deviceAddress}")
                    cancelServiceDiscoveryTimeout()
                    this.targetUuid = null
                    connectToPeer(srcDevice.deviceAddress)
                }
            },
            // ── TXT record: map contains { "uuid" → UUID } ─────────────────
            WifiP2pManager.DnsSdTxtRecordListener { _, txtRecord, srcDevice ->
                val peerUuid = txtRecord["uuid"] ?: return@DnsSdTxtRecordListener
                Log.d(tag, "DNS-SD TXT: uuid=$peerUuid, mac=${srcDevice.deviceAddress}")
                if (peerUuid == this.targetUuid) {
                    Log.d(tag, "✅ UUID match via DNS-SD TXT record: $peerUuid → ${srcDevice.deviceAddress}")
                    cancelServiceDiscoveryTimeout()
                    this.targetUuid = null
                    connectToPeer(srcDevice.deviceAddress)
                }
            }
        )

        val request = WifiP2pDnsSdServiceRequest.newInstance()
        mgr.addServiceRequest(ch, request, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "DNS-SD service request added — starting service discovery")
                mgr.discoverServices(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.d(tag, "DNS-SD service discovery started for UUID=$targetUuid")
                        scheduleServiceDiscoveryTimeout(fallbackName)
                    }
                    override fun onFailure(reason: Int) {
                        Log.w(tag, "discoverServices failed (${failureReason(reason)}) — falling back to name-based")
                        fallbackToNameBased(fallbackName)
                    }
                })
            }
            override fun onFailure(reason: Int) {
                Log.w(tag, "addServiceRequest failed (${failureReason(reason)}) — falling back to name-based")
                fallbackToNameBased(fallbackName)
            }
        })
    }

    private fun scheduleServiceDiscoveryTimeout(fallbackName: String) {
        cancelServiceDiscoveryTimeout()
        serviceDiscoveryTimeoutRunnable = Runnable {
            val ph = connectionPhase.get()
            if (ph != ConnectionPhase.CONNECTING && ph != ConnectionPhase.GROUP_FORMED &&
                ph != ConnectionPhase.SOCKET_CONNECTING && ph != ConnectionPhase.SOCKET_CONNECTED) {
                Log.w(tag, "DNS-SD timeout — no UUID match in 15 s, falling back to name-based")
                fallbackToNameBased(fallbackName)
            }
        }.also { mainHandler.postDelayed(it, 15_000) }
    }

    private fun cancelServiceDiscoveryTimeout() {
        serviceDiscoveryTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        serviceDiscoveryTimeoutRunnable = null
    }

    @SuppressLint("MissingPermission")
    private fun fallbackToNameBased(targetName: String) {
        targetUuid = null
        // Clear DNS-SD service requests so discoverServices() stops; we switch to discoverPeers().
        wifiP2pManager?.clearServiceRequests(p2pChannel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Service requests cleared — starting name-based peer discovery for '$targetName'")
                initiateConnection(targetName)
            }
            override fun onFailure(reason: Int) {
                Log.w(tag, "clearServiceRequests failed (${failureReason(reason)}) — proceeding with name-based anyway")
                initiateConnection(targetName)
            }
        })
    }

    /**
     * Set the Wi-Fi Direct device name to [name] (typically the OffLink username).
     *
     * This is critical for peer-name matching: the app searches for a peer whose
     * Wi-Fi Direct device name contains the OffLink username.  Without this call,
     * the peer shows its Android system name (e.g. "TECNO CAMON 30S") instead of
     * "techno", so the match fails even though the device is discoverable.
     *
     * Must be called AFTER [initialize] (needs an active p2pChannel).
     * Requires android.permission.CONFIGURE_WIFI_STATE in the manifest.
     *
     * WifiP2pManager.setDeviceName() was deprecated in API 29 and removed from
     * the public SDK in newer compileSdkVersions, so we invoke it via reflection
     * to keep compatibility across all Android versions.
     */
    fun setDeviceName(name: String) {
        val mgr = wifiP2pManager
        val ch  = p2pChannel
        if (mgr == null || ch == null) {
            Log.w(tag, "setDeviceName: manager or channel not ready — name='$name' will be applied after init")
            pendingDeviceName = name
            return
        }
        if (name.isBlank()) {
            Log.w(tag, "setDeviceName: blank name ignored")
            return
        }

        val listener = object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "✅ Wi-Fi Direct device name set to: '$name'")
            }
            override fun onFailure(reason: Int) {
                // Failure is non-fatal; peer-name matching may fall back to the
                // system device name.  Log but do not surface to Dart.
                Log.w(tag, "⚠️ setDeviceName failed (${failureReason(reason)}) — " +
                           "Wi-Fi Direct peers will see system name instead of '$name'")
            }
        }

        // setDeviceName was deprecated in API 29 and removed from the public
        // compileSdk stub in API 33+.  We use reflection so the code compiles
        // against any targetSdk while still invoking the method at runtime on
        // devices that still support it (Android 6 – 15 all still honour it).
        try {
            val method = mgr.javaClass.getMethod(
                "setDeviceName",
                WifiP2pManager.Channel::class.java,
                String::class.java,
                WifiP2pManager.ActionListener::class.java
            )
            method.invoke(mgr, ch, name, listener)
        } catch (e: NoSuchMethodException) {
            Log.w(tag, "setDeviceName not available on this device/API: ${e.message}")
        } catch (e: Exception) {
            Log.w(tag, "setDeviceName reflection error: ${e.message}")
        }
    }

    /**
     * Return current group info as a Dart-friendly map.
     */
    @SuppressLint("MissingPermission")
    fun getGroupInfo(): Map<String, Any>? {
        if (connectionPhase.get() != ConnectionPhase.SOCKET_CONNECTED) return null
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

    // ─── Consent API ──────────────────────────────────────────────────────────

    /**
     * Accept the pending incoming Wi-Fi Direct invitation.
     * Called by Flutter after the user taps "Accept" in the consent dialog.
     */
    fun acceptInvitation(): Map<String, Any> {
        val peer = pendingInvitedPeer
        if (peer == null) {
            Log.w(tag, "acceptInvitation: no pending invitation to accept")
            return mapOf("success" to false, "error" to "No pending invitation")
        }
        cancelInvitationTimeout()
        pendingInvitedPeer = null
        Log.d(tag, "✅ User accepted invitation from ${peer.deviceName} (${peer.deviceAddress})")

        // If the P2P group already formed while the dialog was displayed
        // (Android auto-accepted the WPS PBC handshake at the OS level),
        // we only need to start the TCP socket — no need to call connect() again.
        val phase = connectionPhase.get()
        if (phase == ConnectionPhase.GROUP_FORMED) {
            Log.d(tag, "acceptInvitation: group already formed — resuming socket setup")
            startSocketOrFail()
            return mapOf("success" to true)
        }

        // Group not yet formed — call connect() to trigger P2P negotiation.
        return connectToPeer(peer.deviceAddress)
    }

    /**
     * Reject the pending incoming Wi-Fi Direct invitation.
     * Called by Flutter after the user taps "Decline" in the consent dialog.
     */
    @SuppressLint("MissingPermission")
    fun rejectInvitation() {
        val peer = pendingInvitedPeer
        cancelInvitationTimeout()
        pendingInvitedPeer = null
        Log.d(tag, "❌ User rejected invitation from ${peer?.deviceName ?: "unknown"}")

        // If the P2P group already formed while the dialog was open (Android
        // auto-accepted at the OS level), we must dismantle it now.
        val phase = connectionPhase.get()
        if (phase == ConnectionPhase.GROUP_FORMED || phase == ConnectionPhase.SOCKET_CONNECTING) {
            Log.d(tag, "rejectInvitation: removing auto-formed group")
            wifiP2pManager?.removeGroup(p2pChannel!!, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(tag, "Group removed after user rejection")
                    resetState(restartPassiveDiscovery = true)
                }
                override fun onFailure(reason: Int) {
                    Log.w(tag, "Failed to remove group after rejection: ${failureReason(reason)}")
                    resetState(restartPassiveDiscovery = true)
                }
            })
        } else {
            // Group not yet formed — just restart passive discovery so we stay
            // visible for future connection attempts.
            resetState(restartPassiveDiscovery = true)
        }
    }

    private fun notifyIncomingInvitation(peer: WifiP2pDevice) {
        val payload = mapOf(
            "deviceName"    to peer.deviceName,
            "deviceAddress" to peer.deviceAddress
        )
        Log.d(tag, "🔔 Notifying Flutter of incoming invitation from ${peer.deviceName}")
        mainHandler.post { incomingInvitationListener?.invoke(payload) }
    }

    private fun scheduleInvitationTimeout() {
        cancelInvitationTimeout()
        invitationTimeoutRunnable = Runnable {
            if (pendingInvitedPeer != null) {
                Log.d(tag, "⏰ Invitation timed out — auto-rejecting")
                // Delegate to rejectInvitation() so group teardown logic runs.
                rejectInvitation()
            }
        }.also { mainHandler.postDelayed(it, 30_000) }
    }

    private fun cancelInvitationTimeout() {
        invitationTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        invitationTimeoutRunnable = null
    }

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
        // Mark disconnected immediately so in-flight callbacks don't trigger reconnect
        connectionPhase.set(ConnectionPhase.DISCONNECTED)
        targetDeviceName = null
        connectRetryCount.set(0)
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
        cancelPassiveDiscovery()
        cancelInvitationTimeout()
        pendingInvitedPeer = null
        disconnect()
        unregisterReceiver()
        try { executor.shutdownNow() } catch (_: Exception) {}
        initialized = false
    }

    // ═══════════════════════════════════════════════════════════════
    // Socket management
    // ═══════════════════════════════════════════════════════════════

    private fun startSocketServer() {
        Log.d(tag, "GROUP OWNER — starting TCP ServerSocket on port $TCP_PORT")
        connectionPhase.set(ConnectionPhase.SOCKET_CONNECTING)

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
                Log.d(tag, "TCP ServerSocket listening on port $TCP_PORT…")

                val client = srv.accept()
                Log.d(tag, "CLIENT connected to TCP server from ${client.inetAddress?.hostAddress}")
                activeSocket = client
                initSocketStreams(client)

            } catch (e: Exception) {
                if (isSocketActive.get() ||
                    connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTING) {
                    Log.e(tag, "TCP server error", e)
                    handleSocketError(e)
                } else {
                    Log.d(tag, "TCP server closed (expected — disconnect/reset in progress)")
                }
            }
        }
    }

    private fun startSocketClient(goIp: String) {
        Log.d(tag, "CLIENT — dialing TCP Group Owner at $goIp:$TCP_PORT")
        connectionPhase.set(ConnectionPhase.SOCKET_CONNECTING)

        notifyConnectionState(
            connected = true,
            role = "client",
            ipAddress = goIp,
            socketActive = false
        )

        executor.execute {
            val maxAttempts = 12
            var attempt = 0
            while (attempt < maxAttempts &&
                   !isSocketActive.get() &&
                   connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTING) {
                attempt++
                try {
                    Log.d(tag, "TCP connect attempt $attempt/$maxAttempts to $goIp:$TCP_PORT…")
                    Thread.sleep(1000)
                    val sock = Socket(goIp, TCP_PORT)
                    activeSocket = sock
                    Log.d(tag, "TCP socket connected to GO at $goIp:$TCP_PORT (attempt $attempt)")
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
            if (!isSocketActive.get() && attempt < maxAttempts) {
                Log.d(tag, "TCP client loop exited early (phase=${connectionPhase.get()})")
            }
        }
    }

    private fun initSocketStreams(sock: Socket) {
        try {
            socketWriter = BufferedWriter(OutputStreamWriter(sock.getOutputStream(), "UTF-8"))
            val reader   = BufferedReader(InputStreamReader(sock.getInputStream(), "UTF-8"))
            isSocketActive.set(true)

            // ── Transition to SOCKET_CONNECTED ──────────────────────────
            connectionPhase.set(ConnectionPhase.SOCKET_CONNECTED)
            Log.d(tag, "✅ Socket streams ready — phase=SOCKET_CONNECTED " +
                  "role=${if (isGroupOwner.get()) "GROUP_OWNER" else "CLIENT"} " +
                  "ip=$groupOwnerAddress")

            // Notify Dart: socket is live → Flutter may now open Chat screen
            mainHandler.post {
                notifyConnectionState(
                    connected = true,
                    role = if (isGroupOwner.get()) "group_owner" else "client",
                    ipAddress = groupOwnerAddress,
                    socketActive = true
                )
            }

            // ── Receive loop ─────────────────────────────────────────────
            executor.execute {
                try {
                    while (isSocketActive.get()) {
                        val line = reader.readLine()
                        if (line == null) {
                            // Peer closed the connection cleanly
                            Log.w(tag, "readLine() returned null — peer closed socket")
                            break
                        }
                        Log.d(tag, "Wi-Fi Direct received: ${line.take(80)}")
                        mainHandler.post { messageListener?.invoke(line) }
                    }
                } catch (e: Exception) {
                    if (isSocketActive.get()) {
                        Log.e(tag, "Socket read error", e)
                        handleSocketError(e)
                        return@execute
                    }
                }

                // If the loop exited (null or exception already handled above)
                // and the socket is still marked active, the peer closed without error.
                if (isSocketActive.get()) {
                    Log.w(tag, "Read loop ended while socket still marked active — cleaning up")
                    handleSocketError(Exception("Peer closed connection"))
                } else {
                    Log.d(tag, "Wi-Fi Direct receive loop ended normally")
                }
            }

        } catch (e: Exception) {
            Log.e(tag, "initSocketStreams error", e)
            handleSocketError(e)
        }
    }

    private fun closeSocket() {
        val wasActive = isSocketActive.getAndSet(false)
        if (wasActive) Log.d(tag, "Closing active socket…")
        try { socketWriter?.close() } catch (_: Exception) {}
        try { activeSocket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        socketWriter = null
        activeSocket = null
        serverSocket = null
        if (wasActive) Log.d(tag, "Socket closed")
    }

    /**
     * Start (or restart) the passive-discovery heartbeat.
     * Schedules a [discoverPeers] call every [passiveDiscoveryIntervalMs] so this
     * device keeps broadcasting its Wi-Fi Direct beacon even when idle, allowing
     * the remote side to find it without the user pressing "Scan for Devices".
     */
    private fun schedulePassiveDiscovery() {
        cancelPassiveDiscovery()
        passiveDiscoveryRunnable = Runnable {
            val phase = connectionPhase.get()
            if (initialized &&
                phase != ConnectionPhase.CONNECTING &&
                phase != ConnectionPhase.GROUP_FORMED &&
                phase != ConnectionPhase.SOCKET_CONNECTING &&
                phase != ConnectionPhase.SOCKET_CONNECTED) {
                Log.d(tag, "Passive discovery heartbeat — restarting discoverPeers() (phase=$phase)")
                discoverPeers()
            }
            // Always reschedule so the heartbeat survives regardless of phase.
            schedulePassiveDiscovery()
        }.also { mainHandler.postDelayed(it, passiveDiscoveryIntervalMs) }
    }

    private fun cancelPassiveDiscovery() {
        passiveDiscoveryRunnable?.let { mainHandler.removeCallbacks(it) }
        passiveDiscoveryRunnable = null
    }

    /**
     * Reset the state machine to DISCONNECTED.
     *
     * @param restartPassiveDiscovery  When true, schedule a [discoverPeers] call
     *   1.5 s after the reset so this device stays visible and can receive incoming
     *   Wi-Fi Direct invitations (one-tap passive-accept flow).
     *   Pass false when the caller explicitly manages the next action (e.g. user
     *   initiated disconnect, or the retry mechanism already schedules its own scan).
     */
    private fun resetState(restartPassiveDiscovery: Boolean = false) {
        connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        connectingTimeoutRunnable = null
        cancelServiceDiscoveryTimeout()
        targetUuid = null
        // Clear any pending consent request so a stale invitation doesn't linger.
        cancelInvitationTimeout()
        pendingInvitedPeer = null
        connectionPhase.set(ConnectionPhase.DISCONNECTED)
        isGroupOwner.set(false)
        groupOwnerAddress = null
        isSocketActive.set(false)
        // Always clear the pending target so stale connection intent from a
        // previous session (e.g. hot-reload) doesn't keep looping forever.
        // Callers that want to preserve the target for a retry must save it
        // before calling resetState() and restore it afterwards.
        targetDeviceName = null
        Log.d(tag, "State reset — phase=DISCONNECTED")

        // Keep passive discovery alive so we can detect incoming INVITED peers.
        // Without this, a spurious CONNECTION_CHANGED reset silences the device and
        // it can no longer auto-accept an invitation from the tapping device.
        // 800 ms delay: short enough to catch a pending invitation quickly,
        // long enough to avoid hammering the framework before it settles.
        if (restartPassiveDiscovery && initialized) {
            mainHandler.postDelayed({
                val ph = connectionPhase.get()
                if (ph == ConnectionPhase.DISCONNECTED || ph == ConnectionPhase.IDLE) {
                    Log.d(tag, "Post-reset: restarting passive discovery…")
                    discoverPeers()
                }
            }, 800)
        }
    }

    private fun handleSocketError(e: Exception) {
        Log.e(tag, "Socket error — resetting. Reason: ${e.message}")
        closeSocket()
        connectionPhase.set(ConnectionPhase.FAILED)
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
        role: String?      = null,
        ipAddress: String? = null,
        socketActive: Boolean? = null,
        status: String?    = null,
        error: String?     = null
    ) {
        val map = mutableMapOf<String, Any>(
            "connected"       to connected,
            "connectionPhase" to connectionPhase.get().name
        )
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
                    if (!isP2pEnabled.get()) {
                        // Wi-Fi Direct was turned off — full reset
                        Log.w(tag, "Wi-Fi Direct DISABLED — resetting state machine")
                        closeSocket()
                        resetState()
                        notifyConnectionState(connected = false, error = "Wi-Fi Direct disabled")
                    }
                }

                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    Log.d(tag, "Wi-Fi P2P peers changed — requesting list…")
                    wifiP2pManager?.requestPeers(p2pChannel) { peerList ->
                        handlePeerListUpdate(peerList)
                    }
                }

                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val networkInfo = extractNetworkInfo(intent)
                    Log.d(tag, "CONNECTION_CHANGED broadcast — " +
                          "networkInfo.isConnected=${networkInfo?.isConnected}, " +
                          "phase=${connectionPhase.get()}")

                    if (networkInfo?.isConnected == true) {
                        Log.d(tag, "Wi-Fi P2P network connected — requesting connection info…")
                        wifiP2pManager?.requestConnectionInfo(p2pChannel) { info ->
                            handleConnectionInfo(info)
                        }
                    } else {
                        Log.d(tag, "Wi-Fi P2P network disconnected")
                        val phase = connectionPhase.get()

                        // During active P2P negotiation the Android framework fires
                        // a spurious "disconnected" broadcast before the new group
                        // is established. Ignore it so we don't tear down a
                        // connection that is still forming.
                        //
                        // DISCOVERING is included because calling connect() while
                        // the device is still in discovery mode triggers this
                        // broadcast.  If we let it through, the Flutter layer sees
                        // a false "disconnected" event, clears _connectedPeerId, and
                        // later fails to emit ConnectionState.connected even though
                        // the socket forms successfully (race condition).
                        if (phase == ConnectionPhase.DISCOVERING ||
                            phase == ConnectionPhase.CONNECTING ||
                            phase == ConnectionPhase.GROUP_FORMED ||
                            phase == ConnectionPhase.SOCKET_CONNECTING) {
                            Log.d(tag, "Spurious disconnect during P2P negotiation " +
                                  "(phase=$phase) — ignoring")
                            return
                        }

                        val wasConnected = phase == ConnectionPhase.SOCKET_CONNECTED
                        closeSocket()
                        // Always restart passive discovery after a reset so this device
                        // keeps receiving PEERS_CHANGED broadcasts and can auto-accept
                        // incoming invitations (one-tap flow).
                        resetState(restartPassiveDiscovery = true)
                        notifyConnectionState(connected = false)
                        if (wasConnected) {
                            Log.w(tag, "Active socket lost — peer may have disconnected")
                        }
                    }
                }

                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                    val device = extractThisDevice(intent)
                    // Log the system name for diagnostics only — MAC is never exposed
                    // to the Dart layer. UUID is the single identity used by OffLink.
                    Log.d(tag, "This device info: name=${device?.deviceName}, " +
                               "uuid=$ownUuid (MAC omitted by design)")
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

        // ── Re-discovery when no peers are found ──────────────────────────────
        // If we have a target but the scan returned nothing, the other device
        // is probably also scanning (both devices scanning simultaneously means
        // neither is listening).  Schedule a re-scan with a short pause so the
        // radios can settle into listen/scan alternation.
        val phase0 = connectionPhase.get()
        if (availablePeers.isEmpty() && targetDeviceName != null &&
            phase0 != ConnectionPhase.SOCKET_CONNECTED &&
            phase0 != ConnectionPhase.CONNECTING &&
            phase0 != ConnectionPhase.SOCKET_CONNECTING &&
            phase0 != ConnectionPhase.GROUP_FORMED) {
            Log.d(tag, "No peers found — scheduling rediscovery in 4 s…")
            mainHandler.postDelayed({ discoverPeers() }, 4000)
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

        val phase  = connectionPhase.get()

        // ── Incoming Wi-Fi Direct invitation — request user consent ──────────
        // When another device has called connect() targeting us, Android places
        // that peer in our list with status == INVITED (1).
        // Instead of accepting immediately, notify Flutter so the user can
        // Accept or Decline via a consent dialog.  acceptInvitation() /
        // rejectInvitation() are called back from the Dart layer.
        if (phase != ConnectionPhase.SOCKET_CONNECTED &&
            phase != ConnectionPhase.CONNECTING &&
            phase != ConnectionPhase.SOCKET_CONNECTING &&
            phase != ConnectionPhase.GROUP_FORMED) {
            val invitedPeer = synchronized(availablePeers) {
                availablePeers.firstOrNull { it.status == WifiP2pDevice.INVITED }
            }
            if (invitedPeer != null) {
                if (pendingInvitedPeer?.deviceAddress == invitedPeer.deviceAddress) {
                    // Same invitation still pending — user hasn't responded yet.
                    Log.d(tag, "🔔 Invitation still pending from ${invitedPeer.deviceName} — waiting for user")
                    return
                }
                // New invitation — ask the user for consent.
                pendingInvitedPeer = invitedPeer
                scheduleInvitationTimeout()
                notifyIncomingInvitation(invitedPeer)
                return
            }
        }

        // ── Auto-connect on initiator side ────────────────────────────────────
        // Only fire when the user explicitly initiated a connection (targetDeviceName set).
        // Passive discovery (targetDeviceName == null) must NOT auto-connect to
        // random peers; INVITED detection above handles the passive accept case.
        val canAutoConnect = targetDeviceName != null &&
            phase != ConnectionPhase.SOCKET_CONNECTED &&
            phase != ConnectionPhase.CONNECTING &&
            phase != ConnectionPhase.SOCKET_CONNECTING &&
            phase != ConnectionPhase.GROUP_FORMED &&
            availablePeers.isNotEmpty()

        if (canAutoConnect) {
            val match = synchronized(availablePeers) {
                // ── Filter by targetDeviceName so we never connect to the wrong device ──
                // Previously this used firstOrNull() with no filter, which caused A52
                // to connect to Infinix even when the intended target was Techno, because
                // Infinix happened to be first in the peer list returned by the framework.
                availablePeers.firstOrNull {
                    it.deviceName.contains(targetDeviceName!!, ignoreCase = true)
                }
            }
            if (match != null) {
                Log.d(
                    tag,
                    "Auto-connecting to: ${match.deviceName} " +
                    "(${match.deviceAddress}) phase=$phase, requestedName=$targetDeviceName"
                )
                connectToPeer(match.deviceAddress)
            } else {
                // Named peer not yet visible — schedule a rediscovery and wait.
                Log.w(tag, "Auto-connect skipped — no peer matching '$targetDeviceName' found " +
                      "(${availablePeers.size} other peer(s) visible). Retrying discovery in 4 s…")
                mainHandler.postDelayed({ discoverPeers() }, 4000)
            }
        } else if (targetDeviceName != null) {
            Log.d(tag, "Auto-connect skipped — phase=$phase, target=$targetDeviceName")
        }
    }

    private fun handleConnectionInfo(info: WifiP2pInfo) {
        Log.d(
            tag,
            "onConnectionInfoAvailable — " +
            "groupFormed=${info.groupFormed}, " +
            "isGroupOwner=${info.isGroupOwner}, " +
            "groupOwnerAddress=${info.groupOwnerAddress?.hostAddress}"
        )

        if (!info.groupFormed) {
            Log.w(tag, "groupFormed=false — ignoring (not yet formed)")
            return
        }

        // Ignore duplicate callbacks if we are already past GROUP_FORMED
        val phase = connectionPhase.get()
        if (phase == ConnectionPhase.SOCKET_CONNECTING ||
            phase == ConnectionPhase.SOCKET_CONNECTED) {
            Log.d(tag, "handleConnectionInfo: already in $phase — ignoring duplicate callback")
            return
        }

        // Group is forming — cancel the CONNECTING and DNS-SD timeouts
        connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        connectingTimeoutRunnable = null
        cancelServiceDiscoveryTimeout()
        targetUuid = null

        connectionPhase.set(ConnectionPhase.GROUP_FORMED)
        isGroupOwner.set(info.isGroupOwner)
        groupOwnerAddress = info.groupOwnerAddress?.hostAddress

        Log.d(
            tag,
            "✅ Wi-Fi Direct GROUP FORMED — " +
            "role=${if (info.isGroupOwner) "GROUP_OWNER" else "CLIENT"}, " +
            "groupOwnerAddress=$groupOwnerAddress"
        )

        // ── Consent gate A — dialog was already shown via PEERS_CHANGED ─────────
        // On some OEM builds PEERS_CHANGED fires with status=INVITED before the
        // group forms.  handlePeerListUpdate() already stored pendingInvitedPeer and
        // notified Flutter.  We must still NOT start the socket here.
        // acceptInvitation() / rejectInvitation() resume socket setup.
        if (pendingInvitedPeer != null) {
            Log.d(tag, "🔒 Group formed but consent pending (gate A) — deferring socket setup")
            return
        }

        // ── Consent gate B — silent inbound connection (INVITED missed) ──────────
        // On other OEM builds (e.g. Samsung Galaxy A06) the INVITED state flashes
        // by so quickly that PEERS_CHANGED only ever reports status=0 (CONNECTED).
        // In that case we detect the inbound connection here: the group formed while
        // this device was in DISCOVERING phase and had no outbound target
        // (targetDeviceName == null means we never called initiateConnection()).
        // We query the peer list to identify the caller, show the consent dialog,
        // and defer the socket — exactly as gate A does.
        if ((phase == ConnectionPhase.DISCOVERING || phase == ConnectionPhase.IDLE) &&
            targetDeviceName == null) {
            Log.d(tag, "🔔 Passive inbound connection detected (phase=$phase, no target) — querying peer for consent")
            wifiP2pManager?.requestPeers(p2pChannel) { peerList ->
                // After group forms the peer appears as CONNECTED (0) in the list.
                val inboundPeer = peerList.deviceList.firstOrNull {
                    it.status == WifiP2pDevice.CONNECTED || it.status == WifiP2pDevice.INVITED
                }
                if (inboundPeer != null) {
                    Log.d(tag, "🔔 Inbound peer identified: ${inboundPeer.deviceName} (${inboundPeer.deviceAddress})")
                    pendingInvitedPeer = inboundPeer
                    scheduleInvitationTimeout()
                    notifyIncomingInvitation(inboundPeer)
                    // Socket is deferred — acceptInvitation() will start it.
                } else {
                    // Peer list is empty (race condition — group may have dissolved).
                    // Fall through and start socket so we don't get stuck.
                    Log.w(tag, "Passive inbound: peer list empty after group formed — starting socket without consent")
                    startSocketOrFail()
                }
            }
            return
        }

        startSocketOrFail()
    }

    /** Start TCP server (GO) or client (peer) based on current role. */
    private fun startSocketOrFail() {
        if (isGroupOwner.get()) {
            startSocketServer()
        } else {
            val goIp = groupOwnerAddress
            if (goIp != null) {
                startSocketClient(goIp)
            } else {
                Log.e(tag, "groupOwnerAddress is null — cannot start socket client")
                connectionPhase.set(ConnectionPhase.FAILED)
                notifyConnectionState(connected = false, error = "Group owner IP unavailable")
            }
        }
    }
}
