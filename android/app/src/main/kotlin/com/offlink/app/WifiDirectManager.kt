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
import java.net.InetSocketAddress
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

    // ── Passive GO mode flag ──────────────────────────────────────────────────
    // True while this device has created a passive relay group via
    // startPassiveGoMode().  Prevents handleConnectionInfo() from advancing
    // the main connection state machine when the group first forms (which would
    // start a ServerSocket and set phase=SOCKET_CONNECTING, blocking all
    // outbound user-initiated connections).  The flag stays true until:
    //   • A relay client actually joins the group (detected via requestPeers),
    //     at which point socket setup proceeds normally.
    //   • initiateConnection() or connectToGroupByUuid() is called — the passive
    //     group is removed first so the device can act as a client.
    //   • resetState() clears all state.
    private val isPassiveGoMode = AtomicBoolean(false)

    // ── Passive GO creation in-flight guard ───────────────────────────────────
    // Set to true BEFORE removeGroup() is called in startPassiveGoMode() and
    // cleared only when handleConnectionInfo() processes the new passive group,
    // createGroup() fails, or the user initiates an outbound connection.
    //
    // This flag allows resetState() to preserve isPassiveGoMode across the
    // spurious DISCONNECTED broadcasts that the Android framework fires during
    // the removeGroup() → createGroup() transition, which is the root cause of
    // the "phase=SOCKET_CONNECTING immediately after passive GO creation" bug.
    private val pendingPassiveGoCreation = AtomicBoolean(false)

    // Socket handles
    private var serverSocket: ServerSocket? = null
    private var activeSocket: Socket? = null
    private var socketWriter: BufferedWriter? = null
    private val socketWriteLock = Any()
    private val isSocketActive = AtomicBoolean(false)

    // ─── Multi-GO Group Session ────────────────────────────────────────────────
    // When this device is a Multi-GO Group Owner it keeps one BufferedWriter per
    // connected client.  clientSocketMap is keyed by peer UUID (from the UUID
    // handshake) so the relay logic can skip the sender.
    //
    // When this device is a GROUP_OWNER in a regular (non-Multi-GO) session the
    // map stays empty and the legacy single-socket path is used.  The flag
    // isMultiGoGroupOwner distinguishes the two modes.
    private val clientSocketMap = java.util.concurrent.ConcurrentHashMap<String, BufferedWriter>()
    private val clientSockets   = java.util.concurrent.ConcurrentHashMap<String, Socket>()
    private val clientWriteLocks = java.util.concurrent.ConcurrentHashMap<String, Any>()
    private val isMultiGoGroupOwner = AtomicBoolean(false)
    /** Fires when a new client UUID is accepted into the Multi-GO group. */
    var groupMemberJoinedListener: ((String) -> Unit)? = null
    /** Fires when a client UUID disconnects from the Multi-GO group. */
    var groupMemberLeftListener: ((String) -> Unit)? = null

    // ─── Application-level heartbeat ──────────────────────────────────────────
    // Sends a lightweight PING frame every 15 s when no data is flowing.
    // Keeps the TCP connection alive through NAT/power-management and detects
    // dead peers within one heartbeat interval instead of waiting for a long
    // OS-level socket timeout (~minutes).
    private val heartbeatIntervalMs  = 15_000L
    private val heartbeatPingMessage = "__PING__"
    private var heartbeatRunnable: Runnable? = null

    // Peer list
    private val availablePeers = mutableListOf<WifiP2pDevice>()

    // Discovery retry state
    private val discoveryRetryCount = AtomicInteger(0)
    private val maxDiscoveryRetries = 6

    // Consecutive non-BUSY discovery failure counter.
    // After this many back-to-back failures (e.g. "Internal error") we escalate
    // to hardRecoverP2pSlot() which resets the WiFi Direct hardware stack.
    private val discoveryErrorCount = AtomicInteger(0)
    private val maxDiscoveryErrors  = 2

    // Set to true while a hard BUSY recovery is in progress to suppress
    // concurrent discoverPeers() calls from the passive-discovery heartbeat.
    private val isBusyRecovering = AtomicBoolean(false)

    // Tracks consecutive hard-BUSY recoveries so we can apply exponential
    // backoff instead of always retrying after a fixed 6 s delay.
    // Resets to 0 on any successful discoverPeers() call.
    private val hardBusyRecoverCount = AtomicInteger(0)

    // Safety timeout: reset if we stay CONNECTING with no response.
    // DTN weak-link relay attempts are intentionally patient so links around
    // -89 dBm get enough time to form before we retry.
    private var connectingTimeoutRunnable: Runnable? = null

    // Auto-retry counter — resets on a fresh user-initiated connect or disconnect
    private val connectRetryCount = AtomicInteger(0)
    private val maxConnectRetries = 5   // covers stale-INVITED cleanup + simultaneous-tap deadlock

    // True after the current one-to-one attempt has already tried the
    // passive-GO UUID join fallback. Prevents looping when the target has
    // no passive GO group available.
    @Volatile private var triedPassiveGoJoin = false

    // ─── Passive Discovery Heartbeat ──────────────────────────────────────────
    // Android's discoverPeers() has an internal expiry (~60-120 s on most OEMs).
    // After it expires the device stops beaconing, making it invisible to remote
    // scans even though the app is running.  Re-running it every 30 s (reduced
    // from 60 s) doubles beaconing frequency, improving discoverability at range.
    private val passiveDiscoveryIntervalMs = 30_000L
    private var passiveDiscoveryRunnable: Runnable? = null

    // ─── Background DNS-SD Service Browser ────────────────────────────────────
    // Periodically queries _offlink._tcp services over Wi-Fi Direct so nearby
    // devices are discovered at Wi-Fi Direct range (~200 m) even when BLE
    // cannot reach them (~50 m).  Discovered entries are emitted to Dart so the
    // UI can show them without waiting for a user-initiated connect attempt.
    private val backgroundServiceDiscoveryIntervalMs = 90_000L
    private var backgroundServiceDiscoveryRunnable: Runnable? = null

    // UUID → {uuid, name, address} — populated by the background DNS-SD browser.
    private val backgroundDiscoveredServices = mutableMapOf<String, MutableMap<String, Any>>()

    // Callbacks → Dart
    var peerListListener: ((List<Map<String, Any>>) -> Unit)? = null
    var connectionStateListener: ((Map<String, Any>) -> Unit)? = null
    var messageListener: ((String) -> Unit)? = null
    /** Fires when background DNS-SD service discovery finds OffLink peers.
     *  Each map: { "uuid": String, "name": String?, "address": String }
     *  This allows the UI to discover peers at Wi-Fi Direct range independently
     *  of BLE, extending the effective discovery range from ~50 m to ~200 m.
     */
    var discoveredServicesListener: ((List<Map<String, Any>>) -> Unit)? = null
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

    /** This device's display name — embedded in DNS-SD TXT record so peers can
     *  show our username without requiring a prior BLE discovery. */
    private var ownUsername: String? = null

    /** UUID of the peer we are currently trying to connect to. */
    private var targetUuid: String? = null

    /** Timeout runnable that fires if DNS-SD service discovery finds nothing in 15 s. */
    private var serviceDiscoveryTimeoutRunnable: Runnable? = null

    companion object {
        const val TCP_PORT = 8988
        const val GROUP_OWNER_IP = "192.168.49.1"

        // ── Credential derivation ─────────────────────────────────────────────
        // Each OffLink device creates a WiFi Direct group whose credentials are
        // deterministically derived from its UUID.  Any peer that knows your UUID
        // can compute the SSID/passphrase and connect WITHOUT a consent dialog.
        //
        // SSID rules (Android): must start with "DIRECT-" and be 1–32 chars.
        // Passphrase rules: 8–63 printable ASCII chars.

        fun deriveGroupSsid(uuid: String): String =
            "DIRECT-OL-${uuid.replace("-", "").take(8).uppercase()}"

        fun deriveGroupPassphrase(uuid: String): String = try {
            java.security.MessageDigest.getInstance("SHA-256")
                .digest(uuid.toByteArray(Charsets.UTF_8))
                .take(8)
                .joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            // Fallback: uuid chars + suffix (always 8+ chars, always ASCII)
            uuid.replace("-", "").take(8).lowercase() + "offlink"
        }
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

        // Start background DNS-SD service browser after a delay so peer discovery
        // can own the P2P channel first (Xiaomi/MIUI often returns BUSY if overlapped).
        // This discovers nearby OffLink peers at Wi-Fi Direct range (~200 m)
        // independent of BLE, then continues on a 90-second cycle.
        mainHandler.postDelayed({
            if (initialized) {
                runBackgroundServiceDiscovery()
                scheduleBackgroundServiceDiscovery()
            }
        }, 12_000)

        return true
    }

    /**
     * Xiaomi / some Samsung builds leave [WifiP2pManager] in BUSY when
     * [discoverPeers], DNS-SD [discoverServices], and passive heartbeats overlap.
     * Stopping peer discovery and clearing service requests frees the slot.
     */
    @SuppressLint("MissingPermission")
    private fun recoverP2pDiscoverySlot(delayBeforeRetryMs: Long, onReady: () -> Unit) {
        val mgr = wifiP2pManager ?: run {
            mainHandler.postDelayed(onReady, delayBeforeRetryMs)
            return
        }
        val ch = p2pChannel ?: run {
            mainHandler.postDelayed(onReady, delayBeforeRetryMs)
            return
        }
        val proceed = Runnable { mainHandler.postDelayed(onReady, delayBeforeRetryMs) }
        mgr.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                mgr.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = proceed.run()
                    override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) = proceed.run()
                })
            }
            override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) {
                mgr.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = proceed.run()
                    override fun onFailure(@Suppress("UNUSED_PARAMETER") r2: Int) = proceed.run()
                })
            }
        })
    }

    /**
     * Aggressive BUSY recovery for persistent cases (Samsung Android 14+).
     * Extends [recoverP2pDiscoverySlot] by also calling removeGroup(), which
     * frees any lingering P2P group that is the root cause of the BUSY state.
     * After all async calls complete, waits [delayBeforeRetryMs] then calls [onReady].
     */
    @SuppressLint("MissingPermission")
    private fun hardRecoverP2pSlot(delayBeforeRetryMs: Long, onReady: () -> Unit) {
        val mgr = wifiP2pManager ?: run { mainHandler.postDelayed(onReady, delayBeforeRetryMs); return }
        val ch  = p2pChannel   ?: run { mainHandler.postDelayed(onReady, delayBeforeRetryMs); return }
        val proceed = Runnable { mainHandler.postDelayed(onReady, delayBeforeRetryMs) }

        mgr.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { clearAndRemove(mgr, ch, proceed) }
            override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) { clearAndRemove(mgr, ch, proceed) }
        })
    }

    @SuppressLint("MissingPermission")
    private fun clearAndRemove(mgr: WifiP2pManager, ch: WifiP2pManager.Channel, proceed: Runnable) {
        mgr.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { removeGroupForRecover(mgr, ch, proceed) }
            override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) { removeGroupForRecover(mgr, ch, proceed) }
        })
    }

    @SuppressLint("MissingPermission")
    private fun removeGroupForRecover(mgr: WifiP2pManager, ch: WifiP2pManager.Channel, proceed: Runnable) {
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { proceed.run() }
            override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) { proceed.run() }
        })
    }

    private fun resumeAfterBusyRecovery() {
        isBusyRecovering.set(false)
        val phase = connectionPhase.get()
        val uuid = ownUuid
        val canReceivePassively =
            targetDeviceName == null &&
            uuid != null &&
            (phase == ConnectionPhase.DISCONNECTED ||
                phase == ConnectionPhase.IDLE ||
                phase == ConnectionPhase.DISCOVERING ||
                phase == ConnectionPhase.FAILED)

        if (canReceivePassively) {
            Log.d(tag, "BUSY recovery complete — restoring passive GO readiness")
            connectionPhase.set(ConnectionPhase.DISCONNECTED)
            startPassiveGoMode(uuid)
        } else {
            discoverPeers()
        }
    }

    @SuppressLint("MissingPermission")
    fun discoverPeers(): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")
        val mgr = wifiP2pManager ?: return mapOf("success" to false, "error" to "Manager null")
        val ch  = p2pChannel   ?: return mapOf("success" to false, "error" to "Channel null")

        // ── Guard: never restart peer discovery while a connection is in progress ──
    // When handlePeerListUpdate() fails to find a name-matching peer it schedules
    // discoverPeers() 4 s later.  If connect() succeeds during those 4 s the
    // delayed callback fires mid-negotiation and floods the P2P stack with BUSY
    // errors.  The resulting hardRecoverP2pSlot() calls removeGroup() which
    // tears down the very connection we are forming — the peer never sees the
    // invitation and the group is silently destroyed.
    val guardPhase = connectionPhase.get()
    if (guardPhase == ConnectionPhase.CONNECTING ||
        guardPhase == ConnectionPhase.GROUP_FORMED ||
        guardPhase == ConnectionPhase.SOCKET_CONNECTING ||
        guardPhase == ConnectionPhase.SOCKET_CONNECTED) {
        Log.d(tag, "discoverPeers: skipping — connection in progress ($guardPhase)")
        return mapOf("success" to true, "skipped" to true)
    }

    val fails = discoveryRetryCount.get()
        Log.d(tag, "Starting Wi-Fi Direct peer discovery… (busyRetries=$fails/$maxDiscoveryRetries)")

        mgr.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Peer discovery initiated successfully")
                discoveryRetryCount.set(0)
                discoveryErrorCount.set(0) // reset non-BUSY error counter on successful start
                hardBusyRecoverCount.set(0) // reset hard-BUSY backoff counter on any successful start
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
                        val delayMs = (800L * discoveryRetryCount.get()).coerceAtMost(5000L)
                        Log.d(tag, "Peer discovery BUSY — recover slot then retry in ${delayMs}ms " +
                              "(${discoveryRetryCount.get()}/$maxDiscoveryRetries)")
                        recoverP2pDiscoverySlot(delayMs) { discoverPeers() }
                    }
                    reason == WifiP2pManager.BUSY -> {
                        discoveryRetryCount.set(0)
                        val busyAttempt = hardBusyRecoverCount.incrementAndGet()
                        // Exponential backoff: each consecutive hard-BUSY recovery
                        // waits longer before re-attempting discoverPeers().
                        // This prevents the "BUSY storm" observed in production where
                        // rapid back-to-back recoveries permanently killed the P2P stack.
                        val busyDelayMs = when (busyAttempt) {
                            1    ->  6_000L
                            2    -> 12_000L
                            3    -> 20_000L
                            else -> 30_000L
                        }
                        Log.w(tag, "Peer discovery still BUSY — hard recover #$busyAttempt, delay=${busyDelayMs}ms")
                        connectionPhase.set(ConnectionPhase.DISCONNECTED)
                        if (targetDeviceName != null) {
                            notifyConnectionState(
                                connected = false,
                                error = "Wi-Fi Direct was busy; clearing and retrying…"
                            )
                        } else {
                            Log.d(tag, "Peer discovery BUSY while idle — recovering without surfacing a connection error")
                        }
                        // Suppress the passive-discovery heartbeat so it doesn't
                        // fire concurrent discoverPeers() calls during recovery and
                        // make the BUSY state worse (Samsung Android 14 pattern).
                        isBusyRecovering.set(true)
                        // Use the aggressive path: removeGroup() included so any
                        // lingering stale group (the most common BUSY root cause on
                        // Samsung devices) is torn down before the next attempt.
                        hardRecoverP2pSlot(busyDelayMs) {
                            resumeAfterBusyRecovery()
                        }
                    }
                    else -> {
                        discoveryRetryCount.set(0)
                        val errorMsg = "Peer discovery failed: ${failureReason(reason)}, phase=${connectionPhase.get()}"
                        connectionPhase.set(ConnectionPhase.FAILED)
                        notifyConnectionState(connected = false, error = errorMsg)
                        // Non-BUSY stack error (e.g. "Internal error" / ERROR=0).
                        // The passive heartbeat retries every 30 s but if the WiFi Direct
                        // hardware stack is crashed those retries also fail.
                        // After maxDiscoveryErrors consecutive failures escalate to
                        // hardRecoverP2pSlot() which resets the P2P hardware state.
                        val errorCount = discoveryErrorCount.incrementAndGet()
                        if (errorCount >= maxDiscoveryErrors) {
                            discoveryErrorCount.set(0)
                            val errAttempt = hardBusyRecoverCount.incrementAndGet()
                            // Reuse the same exponential backoff counter as BUSY hard-recovery.
                            // Consecutive Internal error → BUSY cycles compound the backoff,
                            // preventing the P2P stack death observed in the 10:51 demo session.
                            val errDelayMs = when (errAttempt) {
                                1    ->  8_000L
                                2    -> 15_000L
                                3    -> 25_000L
                                else -> 35_000L
                            }
                            Log.w(tag, "Peer discovery FAILED $errorCount times — hard-recovering P2P stack (attempt #$errAttempt, delay=${errDelayMs}ms)")
                            isBusyRecovering.set(true)
                            hardRecoverP2pSlot(errDelayMs) {
                                isBusyRecovering.set(false)
                                if (connectionPhase.get() == ConnectionPhase.IDLE ||
                                    connectionPhase.get() == ConnectionPhase.DISCONNECTED ||
                                    connectionPhase.get() == ConnectionPhase.FAILED) {
                                    discoverPeers()
                                }
                            }
                        }
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

        // If we are currently in passive GO mode (group created for relay standby),
        // we must remove the group before acting as a client, because the Android
        // P2P stack cannot simultaneously be a GO and initiate an outbound connect.
        if (isPassiveGoMode.getAndSet(false)) {
            pendingPassiveGoCreation.set(false) // user is taking over — passive creation cancelled
            Log.d(tag, "initiateConnection: leaving passive GO mode to connect to '$targetName'")
            val mgr2 = wifiP2pManager ?: return mapOf("success" to false, "error" to "Manager null")
            val ch2  = p2pChannel   ?: return mapOf("success" to false, "error" to "Channel null")
            val saved = targetName
            connectionPhase.set(ConnectionPhase.CONNECTING)
            mgr2.removeGroup(ch2, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    connectionPhase.set(ConnectionPhase.IDLE)
                    Log.d(tag, "Passive GO removed — retrying initiateConnection '$saved'")
                    mainHandler.postDelayed({ initiateConnection(saved) }, 500)
                }
                override fun onFailure(r: Int) {
                    connectionPhase.set(ConnectionPhase.IDLE)
                    Log.w(tag, "removeGroup before initiateConnection failed ($r) — retrying anyway")
                    mainHandler.postDelayed({ initiateConnection(saved) }, 500)
                }
            })
            return mapOf("success" to true, "waiting" to true)
        }

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
        // Use the legacy WifiP2pConfig on all API levels.
        // WifiP2pConfig.Builder was introduced in API 29 for group-creation features
        // (setNetworkName, setPassphrase, setGroupOperatingBand) that we do NOT need
        // when simply connecting to a peer. Several OEM Android 12 ROMs (e.g. Infinix)
        // throw IllegalStateException("network name must be non-empty") from Builder.build()
        // even without setGroupOperatingBand, so we avoid the Builder entirely.
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
        }

        mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Wi-Fi Direct connect() request accepted for $deviceAddress")
                connectionPhase.set(ConnectionPhase.CONNECTING)
                notifyConnectionState(connected = false, status = "connecting")

                // Safety net: if no GROUP_FORMED within 45 s, auto-retry with
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
                }.also { mainHandler.postDelayed(it, 45_000) }
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Wi-Fi Direct connect() to $deviceAddress failed: ${failureReason(reason)}")
                connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                connectingTimeoutRunnable = null

                if (reason == WifiP2pManager.BUSY) {
                    // The P2P stack is still processing the original connect() call
                    // (common when the CONNECTING timeout retries while the first attempt
                    // is still pending — Android returns BUSY but the group forms anyway).
                    // DO NOT notify Dart of failure; CONNECTION_CHANGED will arrive when
                    // the group forms.  Flip phase back to CONNECTING and start a shorter
                    // watchdog so we still give up if the group never appears.
                    Log.w(tag, "connect() BUSY — prior call still in progress; waiting for CONNECTION_CHANGED")
                    connectionPhase.compareAndSet(ConnectionPhase.FAILED, ConnectionPhase.CONNECTING)
                    connectingTimeoutRunnable = Runnable {
                        if (connectionPhase.get() == ConnectionPhase.CONNECTING) {
                            Log.e(tag, "Post-BUSY CONNECTING watchdog expired — giving up")
                            val savedTarget = targetDeviceName
                            closeSocket()
                            resetState()
                            if (savedTarget != null) {
                                notifyConnectionState(connected = false, error = "Connection timed out")
                            }
                        }
                    }.also { mainHandler.postDelayed(it, 35_000) }
                    return
                }

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
                writeFrame(w, message, socketWriteLock)
                Log.v(tag, "Message sent via Wi-Fi Direct socket (${message.length} chars)")
            } catch (e: Exception) {
                Log.e(tag, "Error writing to socket", e)
                handleSocketError(e)
            }
        }
        return true
    }

    private fun writeFrame(writer: BufferedWriter, message: String, lock: Any) {
        synchronized(lock) {
            writer.write(message)
            writer.newLine()
            writer.flush()
        }
    }

    /** True only when a TCP socket is confirmed open. */
    fun isConnected(): Boolean = connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTED

    fun isSocketActive(): Boolean = isSocketActive.get()
    fun isGroupOwner(): Boolean = isGroupOwner.get()
    fun getGroupOwnerAddress(): String? = groupOwnerAddress
    fun isP2pEnabled(): Boolean = isP2pEnabled.get()
    fun getConnectionPhase(): String = connectionPhase.get().name
    fun isMultiGoOwner(): Boolean = isMultiGoGroupOwner.get()
    fun getGroupMemberCount(): Int = clientSocketMap.size
    fun getGroupMemberUuids(): List<String> = clientSocketMap.keys.toList()

    // ─── Multi-GO Group Owner API ─────────────────────────────────────────────

    /**
     * Start this device as a Wi-Fi Direct Group Owner (software AP) without
     * peer negotiation.  Uses createGroup() with the highest GO intent so this
     * device always wins the role.
     *
     * After the framework confirms the group is created, [startMultiClientServer]
     * opens a TCP ServerSocket in a loop that accepts N simultaneous clients.
     *
     * Call from Dart via method channel "startAsGroupOwner".
     */
    @SuppressLint("MissingPermission")
    fun startAsGroupOwner(): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")
        val mgr = wifiP2pManager ?: return mapOf("success" to false, "error" to "Manager null")
        val ch  = p2pChannel   ?: return mapOf("success" to false, "error" to "Channel null")

        // Already acting as a Multi-GO owner — idempotent
        if (isMultiGoGroupOwner.get()) {
            Log.d(tag, "startAsGroupOwner: already Multi-GO owner — ignoring")
            return mapOf("success" to true, "alreadyOwner" to true)
        }

        // Remove any existing group first so createGroup() starts clean
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { createMultiGoGroup(mgr, ch) }
            override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) {
                // No group to remove — proceed directly
                createMultiGoGroup(mgr, ch)
            }
        })
        return mapOf("success" to true)
    }

    @SuppressLint("MissingPermission")
    private fun createMultiGoGroup(mgr: WifiP2pManager, ch: WifiP2pManager.Channel) {
        Log.d(tag, "Multi-GO: calling createGroup() to force GO role")
        connectionPhase.set(ConnectionPhase.CONNECTING)
        notifyConnectionState(connected = false, status = "forming_group")

        mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Multi-GO: createGroup() accepted — waiting for CONNECTION_CHANGED")
                // Actual socket start happens in handleConnectionInfo() via CONNECTION_CHANGED
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Multi-GO: createGroup() failed: ${failureReason(reason)}")
                connectionPhase.set(ConnectionPhase.FAILED)
                notifyConnectionState(connected = false, error = "GO createGroup failed: ${failureReason(reason)}")
            }
        })
    }

    /**
     * Connect to an existing Multi-GO group as a client.
     *
     * Behaves like [connectByUuid] but sets groupOwnerIntent = 0 so the GO
     * role is yielded to the existing Group Owner.
     *
     * Call from Dart via method channel "joinGroupAsClient".
     */
    @SuppressLint("MissingPermission")
    fun joinGroupAsClient(targetUuid: String, fallbackName: String): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")
        // Delegate to the standard UUID-based connect path.
        // The GROUP_OWNER intent on the other side (= 15) guarantees it wins the election.
        connectByUuid(targetUuid, fallbackName)
        return mapOf("success" to true)
    }

    // ═══════════════════════════════════════════════════════════════
    // Passive GO mode — dialog-free relay connections
    // ═══════════════════════════════════════════════════════════════

    /**
     * Put this device into "Passive Group Owner" mode.
     *
     * Creates a WiFi Direct group whose SSID and passphrase are derived
     * deterministically from [uuid].  Any peer that knows our UUID can
     * connect using [connectToGroupByUuid] without triggering a consent
     * dialog, because they supply the correct credentials up-front instead
     * of sending a WPS-PBC invitation.
     *
     * This is the relay-receive side of the dialog-free relay protocol.
     * Call on app startup after initialize() returns true.
     */
    @SuppressLint("MissingPermission")
    fun startPassiveGoMode(uuid: String): Map<String, Any> {
        ownUuid = uuid
        val mgr = wifiP2pManager ?: return mapOf("success" to false, "error" to "Manager null")
        val ch  = p2pChannel   ?: return mapOf("success" to false, "error" to "Channel null")

        Log.d(tag, "startPassiveGoMode: creating passive GO group for UUID=$uuid")

        // Guard must be set BEFORE removeGroup() fires so that the spurious
        // DISCONNECTED broadcast dispatched by removeGroup() does NOT clear
        // isPassiveGoMode inside resetState() before handleConnectionInfo() runs.
        pendingPassiveGoCreation.set(true)

        // Remove any existing group first so createGroup() starts clean.
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess()                 { createPassiveGoGroup(mgr, ch, uuid) }
            override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) { createPassiveGoGroup(mgr, ch, uuid) }
        })
        return mapOf("success" to true)
    }

    @SuppressLint("MissingPermission")
    private fun createPassiveGoGroup(mgr: WifiP2pManager, ch: WifiP2pManager.Channel, uuid: String) {
        isPassiveGoMode.set(true) // flag checked in handleConnectionInfo
        // pendingPassiveGoCreation was set in startPassiveGoMode() and stays true
        // until handleConnectionInfo() processes the new group.  On failure paths
        // we clear it here so resetState() resumes normal isPassiveGoMode cleanup.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+: use Builder with explicit credentials so clients can
            // connect without a dialog.
            try {
                val config = WifiP2pConfig.Builder()
                    .setNetworkName(deriveGroupSsid(uuid))
                    .setPassphrase(deriveGroupPassphrase(uuid))
                    .build()
                mgr.createGroup(ch, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.d(tag, "Passive GO group created (API 29+): SSID=${deriveGroupSsid(uuid)}")
                        // pendingPassiveGoCreation stays true — cleared in handleConnectionInfo()
                    }
                    override fun onFailure(reason: Int) {
                        Log.w(tag, "createGroup (Builder) failed: ${failureReason(reason)} — falling back to legacy createGroup()")
                        mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
                            override fun onSuccess() {
                                Log.d(tag, "Legacy passive GO group created")
                                // pendingPassiveGoCreation stays true — cleared in handleConnectionInfo()
                            }
                            override fun onFailure(r: Int) {
                                Log.e(tag, "Legacy createGroup also failed: ${failureReason(r)}")
                                // Both createGroup() paths failed — clear flag so resetState()
                                // can clean up isPassiveGoMode normally.
                                pendingPassiveGoCreation.set(false)
                                isPassiveGoMode.set(false)
                            }
                        })
                    }
                })
                return
            } catch (e: Exception) {
                Log.w(tag, "WifiP2pConfig.Builder failed: ${e.message} — using legacy createGroup()")
            }
        }
        // Android 9 or Builder exception: create group without explicit credentials.
        // Clients on older Android will need to go through the PBC path anyway.
        mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "Legacy passive GO group created (pre-API29)")
                // pendingPassiveGoCreation stays true — cleared in handleConnectionInfo()
            }
            override fun onFailure(reason: Int) {
                Log.e(tag, "Legacy createGroup failed: ${failureReason(reason)}")
                // createGroup() failed — clear flag so resetState() can clean up normally.
                pendingPassiveGoCreation.set(false)
                isPassiveGoMode.set(false)
            }
        })
    }

    /**
     * Restore passive GO mode after a relay connection completes.
     *
     * Call this after every DTN relay disconnect so this device is ready to
     * accept the next relay connection without a dialog.
     */
    @SuppressLint("MissingPermission")
    fun restorePassiveGoMode(): Map<String, Any> {
        val uuid = ownUuid ?: return mapOf("success" to false, "error" to "ownUuid not set")
        Log.d(tag, "restorePassiveGoMode: recreating passive GO group for UUID=$uuid")
        return startPassiveGoMode(uuid)
    }

    /**
     * Connect to a remote device's passive GO group using derived credentials.
     *
     * On Android 10+ (API 29): supplies SSID + passphrase derived from
     * [targetUuid] so the GO auto-accepts without showing a consent dialog.
     *
     * On Android 9 (API < 29): the Builder API is unavailable; falls back to
     * the existing DNS-SD → MAC → WPS-PBC path ([connectByUuid]).  The dialog
     * may appear on the relay device on those older OS versions, but the
     * connection still works.
     *
     * [targetUuid]    — OffLink UUID of the relay peer to connect to.
     * [fallbackName]  — display name used if we need the DNS-SD fallback path.
     */
    @SuppressLint("MissingPermission")
    fun connectToGroupByUuid(targetUuid: String, fallbackName: String): Map<String, Any> {
        if (!initialized) return mapOf("success" to false, "error" to "Not initialized")

        // We are about to become a client — passive GO mode ends here.
        // removeGroup() below will dissolve the passive group before we connect.
        isPassiveGoMode.set(false)
        pendingPassiveGoCreation.set(false) // user is taking over — passive creation cancelled

        // Atomic transition IDLE → CONNECTING.  Multiple Dart threads spawned by
        // BLE scan bursts all arrive here simultaneously; compareAndSet ensures
        // exactly ONE wins and the rest bail out without a race window.
        val nonActivePhases = setOf(
            ConnectionPhase.IDLE,
            ConnectionPhase.DISCOVERING,
            ConnectionPhase.DISCONNECTED,
            ConnectionPhase.FAILED
        )
        val currentPhase = connectionPhase.get()
        if (currentPhase !in nonActivePhases) {
            Log.d(tag, "connectToGroupByUuid: already in $currentPhase — ignoring")
            return mapOf("success" to false, "duplicate" to true, "phase" to currentPhase.name)
        }
        // compareAndSet: only the FIRST thread transitions IDLE→CONNECTING.
        // All others see a non-IDLE phase after this point.
        if (!connectionPhase.compareAndSet(currentPhase, ConnectionPhase.CONNECTING)) {
            val racePhase = connectionPhase.get()
            Log.d(tag, "connectToGroupByUuid: lost CAS race (now $racePhase) — ignoring")
            return mapOf("success" to false, "duplicate" to true, "phase" to racePhase.name)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // API < 29: Builder unavailable — use existing DNS-SD path
            Log.d(tag, "connectToGroupByUuid: API < 29 — using connectByUuid fallback")
            connectionPhase.set(ConnectionPhase.IDLE) // let connectByUuid manage phase
            connectByUuid(targetUuid, fallbackName)
            return mapOf("success" to true, "path" to "legacy_dns_sd")
        }

        val mgr = wifiP2pManager ?: run {
            connectionPhase.set(ConnectionPhase.IDLE)
            return mapOf("success" to false, "error" to "Manager null")
        }
        val ch  = p2pChannel   ?: run {
            connectionPhase.set(ConnectionPhase.IDLE)
            return mapOf("success" to false, "error" to "Channel null")
        }

        val ssid       = deriveGroupSsid(targetUuid)
        val passphrase = deriveGroupPassphrase(targetUuid)
        Log.d(tag, "connectToGroupByUuid: SSID=$ssid target=$fallbackName (API 29+)")

        this.targetDeviceName = fallbackName
        val capturedTargetUuid = targetUuid  // capture before nulling — needed for WPS-PBC fallback
        this.targetUuid       = null         // credentials are pre-computed; UUID no longer needed for the Builder path
        cancelServiceDiscoveryTimeout()
        connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        connectingTimeoutRunnable = null
        notifyConnectionState(connected = false, status = "connecting")

        try {
            val config = WifiP2pConfig.Builder()
                .setNetworkName(ssid)
                .setPassphrase(passphrase)
                .build()

            val startConnect = {
                // Remove our own group before joining the remote one so the P2P
                // stack doesn't conflict between GO and client roles.
                mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        doGroupConnect(mgr, ch, config, capturedTargetUuid ?: "", fallbackName)
                    }

                    override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) {
                        doGroupConnect(mgr, ch, config, capturedTargetUuid ?: "", fallbackName)
                    }
                })
            }

            val clearServicesThenConnect = {
                mgr.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = startConnect()
                    override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) = startConnect()
                })
            }

            // DTN relay connection is the foreground action now; stop discovery
            // first so DISCOVERING cannot occupy the P2P slot and turn this into
            // a no-op duplicate.
            mgr.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(tag, "connectToGroupByUuid: stopped discovery before DTN relay connect")
                    clearServicesThenConnect()
                }

                override fun onFailure(@Suppress("UNUSED_PARAMETER") r: Int) {
                    clearServicesThenConnect()
                }
            })
        } catch (e: Exception) {
            Log.w(tag, "connectToGroupByUuid: Builder failed (${e.message}) — resetting to IDLE for DTN retry")
            connectionPhase.set(ConnectionPhase.IDLE)
            targetDeviceName = null
            notifyConnectionState(connected = false, error = "builder_failed")
        }

        return mapOf("success" to true, "path" to "builder_credentials")
    }

    @SuppressLint("MissingPermission")
    private fun doGroupConnect(
        mgr: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        config: WifiP2pConfig,
        uuid: String,       // target UUID — used in WPS-PBC fallback
        fallbackName: String
    ) {
        // Safety timeout started BEFORE mgr.connect() is called.
        // On some OEM builds (observed: Infinix, Samsung A06) the
        // WifiP2pManager.connect() ActionListener never fires onSuccess or
        // onFailure — the callback is silently swallowed while the native P2P
        // state machine sits in CONNECTING indefinitely.  Without a pre-call
        // timeout the phase would stay CONNECTING forever and every subsequent
        // connectToGroupByUuid would return {duplicate:true}, locking the relay
        // path for the entire session (observed: 91 minutes in production logs).
        // Starting the timer here guarantees it fires regardless of callback delivery.
        connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        val preCallTimeout = Runnable {
            if (connectionPhase.get() != ConnectionPhase.CONNECTING) return@Runnable
            Log.w(tag, "doGroupConnect: CONNECTING timeout (65 s, pre-call safety) — resetting to IDLE")
            connectionPhase.set(ConnectionPhase.IDLE)
            targetDeviceName = null
            notifyConnectionState(connected = false, error = "connection_timeout")
        }
        connectingTimeoutRunnable = preCallTimeout
        mainHandler.postDelayed(preCallTimeout, 65_000)

        mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "doGroupConnect: connect() accepted (dialog-free) for $fallbackName")
                connectRetryCount.set(0)
                // Callback confirmed — reset timer to the standard 60 s window
                // counted from the moment Android accepted the request.
                connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                connectingTimeoutRunnable = Runnable {
                    if (connectionPhase.get() != ConnectionPhase.CONNECTING) return@Runnable
                    Log.w(tag, "doGroupConnect: CONNECTING timeout (60 s) — resetting to IDLE for DTN retry")
                    connectionPhase.set(ConnectionPhase.IDLE)
                    targetDeviceName = null
                    notifyConnectionState(connected = false, error = "connection_timeout")
                }
                mainHandler.postDelayed(connectingTimeoutRunnable!!, 60_000)
            }
            override fun onFailure(reason: Int) {
                // Cancel the pre-call safety timer — failure is immediate, no need to wait.
                connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                connectingTimeoutRunnable = null
                // Credential-based connect failed (target likely has no passive GO group).
                // Fall back to standard DNS-SD + WPS-PBC so the message can still be
                // delivered — a dialog will appear on the target device, which is
                // acceptable for direct nearby delivery.
                Log.w(tag, "doGroupConnect: connect() failed (${failureReason(reason)}) — falling back to DNS-SD / WPS-PBC")
                connectionPhase.set(ConnectionPhase.IDLE)
                targetDeviceName = fallbackName  // restore for connectByUuid auto-connect
                if (uuid.isNotBlank()) {
                    connectByUuid(uuid, fallbackName)
                } else {
                    targetDeviceName = null
                    notifyConnectionState(connected = false, error = "connect_failed_no_uuid")
                }
            }
        })
    }

    /**
     * Send [message] to ALL connected clients simultaneously (GO-side relay).
     *
     * [senderUuid] — UUID of the device that originated the message.
     *   Pass null to send to everyone (e.g. when the GO itself is the sender).
     *   Pass a UUID to skip that socket (prevents echo-back to sender).
     *
     * Returns the count of sockets written to successfully.
     */
    fun broadcastToAllClients(message: String, senderUuid: String? = null): Int {
        if (!isMultiGoGroupOwner.get()) {
            Log.w(tag, "broadcastToAllClients: not a Multi-GO owner — use sendMessage instead")
            return 0
        }
        var successCount = 0
        val deadClients = mutableListOf<String>()
        for ((uuid, writer) in clientSocketMap) {
            if (uuid == senderUuid) continue // don't echo back to sender
            try {
                val lock = clientWriteLocks[uuid] ?: Any().also { clientWriteLocks[uuid] = it }
                writeFrame(writer, message, lock)
                successCount++
            } catch (e: Exception) {
                Log.w(tag, "Multi-GO: write to client $uuid failed: ${e.message}")
                deadClients.add(uuid)
            }
        }
        // Prune dead clients
        for (uuid in deadClients) {
            removeClient(uuid)
        }
        Log.d(tag, "Multi-GO: broadcastToAllClients → $successCount/${clientSocketMap.size + deadClients.size} sockets")
        return successCount
    }

    /** Remove a client from the Multi-GO session and close its socket. */
    private fun removeClient(uuid: String) {
        clientSocketMap.remove(uuid)
        clientWriteLocks.remove(uuid)
        clientSockets.remove(uuid)?.let {
            try { it.close() } catch (_: Exception) {}
        }
        Log.d(tag, "Multi-GO: client $uuid removed (${clientSocketMap.size} remaining)")
        mainHandler.post { groupMemberLeftListener?.invoke(uuid) }

        // If all clients leave, notify Dart that the group is empty
        if (clientSocketMap.isEmpty()) {
            notifyMultiGoState()
        }
    }

    /** Emit current Multi-GO group state to Dart. */
    private fun notifyMultiGoState() {
        val map = mutableMapOf<String, Any>(
            "connected"       to true,
            "role"            to "group_owner",
            "socketActive"    to true,
            "ipAddress"       to GROUP_OWNER_IP,
            "connectionPhase" to connectionPhase.get().name,
            "multiGoMemberCount" to clientSocketMap.size,
            "multiGoMembers"  to clientSocketMap.keys.toList()
        )
        mainHandler.post { connectionStateListener?.invoke(map) }
    }

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
     * Set this device's display name so it is embedded in the DNS-SD TXT record.
     * When remote devices discover us via background service scanning they can
     * immediately display our username without a prior BLE exchange.
     *
     * Re-registers the local service so the updated TXT record is broadcast.
     * Safe to call at any time after or before [initialize].
     */
    fun setOwnUsername(name: String) {
        if (name.isBlank()) return
        ownUsername = name
        Log.d(tag, "setOwnUsername: $name")
        // Re-register service so TXT record now includes the name.
        val uuid = ownUuid ?: return
        if (initialized && p2pChannel != null) {
            registerLocalService(uuid)
        }
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
    private fun addService(
        mgr: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        uuid: String,
        attempt: Int = 1
    ) {
        // Include the username in the TXT record so remote devices can display
        // our name when discovered via Wi-Fi Direct DNS-SD, even without BLE.
        // This is the primary fallback when setDeviceName() is unavailable (Android 12+).
        val record = mutableMapOf<String, String>("uuid" to uuid)
        ownUsername?.takeIf { it.isNotBlank() }?.let { record["name"] = it }
        val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(uuid, "_offlink._tcp", record)
        mgr.addLocalService(ch, serviceInfo, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "✅ DNS-SD service registered: uuid=$uuid (attempt $attempt)")
            }
            override fun onFailure(reason: Int) {
                Log.w(tag, "⚠️ DNS-SD service registration failed attempt $attempt " +
                           "(${failureReason(reason)})")
                // Retry up to 3 times with exponential back-off (3 s, 6 s, 9 s).
                // addLocalService() frequently fails if called too soon after the
                // Wi-Fi Direct channel initialises, or if the service was
                // registered in a previous session and needs clearLocalServices first.
                if (attempt < 3) {
                    mainHandler.postDelayed({
                        if (initialized) addService(mgr, ch, uuid, attempt + 1)
                    }, attempt * 3_000L)
                } else {
                    Log.e(tag, "DNS-SD service registration failed after $attempt attempts — " +
                               "name-based or BLE fallback will be used for discovery")
                }
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

        if (isPassiveGoMode.get()) {
            val savedUuid = targetUuid
            val savedName = fallbackName
            Log.d(tag, "connectByUuid: removing passive GO before outgoing connect")
            isPassiveGoMode.set(false)
            pendingPassiveGoCreation.set(false)
            connectionPhase.set(ConnectionPhase.CONNECTING)
            mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    connectionPhase.set(ConnectionPhase.IDLE)
                    mainHandler.postDelayed({
                        connectByUuid(savedUuid, savedName)
                    }, 500)
                }

                override fun onFailure(reason: Int) {
                    connectionPhase.set(ConnectionPhase.IDLE)
                    Log.w(tag, "connectByUuid: remove passive GO failed " +
                        "(${failureReason(reason)}) - retrying anyway")
                    mainHandler.postDelayed({
                        connectByUuid(savedUuid, savedName)
                    }, 500)
                }
            })
            return
        }

        Log.d(tag, "connectByUuid: UUID=$targetUuid, fallback='$fallbackName'")

        // ── Guard: already connected / connecting ────────────────────────────
        if (connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTED) {
            // The Dart side may have lost its connection state (e.g. hot-restart
            // resets Dart state while the native TCP socket survives).  Re-emit
            // the current connected state so Dart can sync without going through
            // the full DNS-SD → connect() → GROUP_FORMED → socket flow again.
            Log.d(tag, "Already socket-connected — re-notifying Flutter of connected state")
            notifyConnectionState(
                connected   = true,
                role        = if (isGroupOwner.get()) "group_owner" else "client",
                ipAddress   = groupOwnerAddress,
                socketActive = true
            )
            return
        }
        val phase = connectionPhase.get()
        if (phase == ConnectionPhase.CONNECTING || phase == ConnectionPhase.SOCKET_CONNECTING ||
            phase == ConnectionPhase.GROUP_FORMED) {
            Log.d(tag, "Connection already in progress ($phase) — waiting"); return
        }

        if (this.targetDeviceName == null) triedPassiveGoJoin = false
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
        // Use the unified DNS-SD listener which handles both background peer
        // caching and active-connect UUID matching in a single registration.
        setupUnifiedDnsSdListeners()

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

    // ─── Unified DNS-SD Listener ───────────────────────────────────────────────
    // Single listener handles both:
    //   (a) Background browsing — caches ALL _offlink._tcp services for the UI
    //   (b) Active connect — triggers connectToPeer() when targetUuid matches
    // Both paths reuse the same registered callbacks so they never clobber each other.

    @SuppressLint("MissingPermission")
    private fun setupUnifiedDnsSdListeners() {
        val mgr = wifiP2pManager ?: return
        val ch  = p2pChannel   ?: return

        mgr.setDnsSdResponseListeners(
            ch,
            // Service response: instanceName is the UUID registered by the remote device
            WifiP2pManager.DnsSdServiceResponseListener { instanceName, _, srcDevice ->
                Log.d(tag, "DNS-SD service: instance=$instanceName, mac=${srcDevice.deviceAddress}")
                synchronized(backgroundDiscoveredServices) {
                    val entry = backgroundDiscoveredServices.getOrPut(instanceName) {
                        mutableMapOf("uuid" to instanceName)
                    }
                    entry["address"] = srcDevice.deviceAddress
                }
                emitDiscoveredServices()
                // Active connect path
                if (instanceName == targetUuid) {
                    Log.d(tag, "✅ UUID match via DNS-SD service name: $instanceName → ${srcDevice.deviceAddress}")
                    cancelServiceDiscoveryTimeout()
                    targetUuid = null
                    connectToPeer(srcDevice.deviceAddress)
                }
            },
            // TXT record: map contains { "uuid" → UUID, "name" → username (optional) }
            WifiP2pManager.DnsSdTxtRecordListener { _, txtRecord, srcDevice ->
                val peerUuid = txtRecord["uuid"] ?: return@DnsSdTxtRecordListener
                val peerName = txtRecord["name"] ?: ""
                Log.d(tag, "DNS-SD TXT: uuid=$peerUuid, name=$peerName, mac=${srcDevice.deviceAddress}")
                synchronized(backgroundDiscoveredServices) {
                    val entry = backgroundDiscoveredServices.getOrPut(peerUuid) {
                        mutableMapOf("uuid" to peerUuid)
                    }
                    entry["address"] = srcDevice.deviceAddress
                    if (peerName.isNotEmpty()) entry["name"] = peerName
                }
                emitDiscoveredServices()
                // Active connect path
                if (peerUuid == targetUuid) {
                    Log.d(tag, "✅ UUID match via DNS-SD TXT record: $peerUuid → ${srcDevice.deviceAddress}")
                    cancelServiceDiscoveryTimeout()
                    targetUuid = null
                    connectToPeer(srcDevice.deviceAddress)
                }
            }
        )
    }

    private fun emitDiscoveredServices() {
        val services = synchronized(backgroundDiscoveredServices) {
            backgroundDiscoveredServices.values.map { it.toMap() }
        }
        mainHandler.post { discoveredServicesListener?.invoke(services) }
    }

    // ─── Background DNS-SD Service Browser ────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun runBackgroundServiceDiscovery() {
        val mgr = wifiP2pManager ?: return
        val ch  = p2pChannel   ?: return
        val phase = connectionPhase.get()
        // Don't interfere with an active connection in progress.
        // FAILED is now retried by the passive-discovery heartbeat, so DNS-SD
        // is also allowed to run from FAILED to keep the device visible.
        if (phase == ConnectionPhase.CONNECTING ||
            phase == ConnectionPhase.GROUP_FORMED ||
            phase == ConnectionPhase.SOCKET_CONNECTING ||
            phase == ConnectionPhase.SOCKET_CONNECTED) {
            Log.d(tag, "Background DNS-SD skipped — phase=$phase")
            return
        }
        Log.d(tag, "Background DNS-SD service discovery starting…")

        setupUnifiedDnsSdListeners()

        mgr.addServiceRequest(ch, WifiP2pDnsSdServiceRequest.newInstance(),
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    mgr.discoverServices(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            Log.d(tag, "Background DNS-SD discoverServices started")
                            // Clear service requests after 20 s (collection window)
                            mainHandler.postDelayed({
                                mgr.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
                                    override fun onSuccess() { Log.d(tag, "Background service requests cleared") }
                                    override fun onFailure(r: Int) {}
                                })
                            }, 20_000)
                        }
                        override fun onFailure(reason: Int) {
                            Log.w(tag, "Background discoverServices failed (${failureReason(reason)})")
                        }
                    })
                }
                override fun onFailure(reason: Int) {
                    Log.w(tag, "Background addServiceRequest failed (${failureReason(reason)})")
                }
            })
    }

    private fun scheduleBackgroundServiceDiscovery() {
        cancelBackgroundServiceDiscovery()
        backgroundServiceDiscoveryRunnable = Runnable {
            if (initialized) runBackgroundServiceDiscovery()
            scheduleBackgroundServiceDiscovery()
        }.also { mainHandler.postDelayed(it, backgroundServiceDiscoveryIntervalMs) }
    }

    private fun cancelBackgroundServiceDiscovery() {
        backgroundServiceDiscoveryRunnable?.let { mainHandler.removeCallbacks(it) }
        backgroundServiceDiscoveryRunnable = null
    }

    @SuppressLint("MissingPermission")
    private fun fallbackToNameBased(targetName: String) {
        val savedUuid = targetUuid
        targetUuid = null

        // ── Fast path: use MAC from background DNS-SD cache ─────────────────
        // The 90-second background service browser populates backgroundDiscoveredServices
        // with UUID→MAC mappings even before the user taps "Connect".  If we already
        // know the peer's MAC from a previous scan, connect directly without running
        // another discovery round — this is the common case when setDeviceName() fails
        // (Android 12+) so the device shows as its system name in the P2P peer list.
        if (savedUuid != null) {
            val cachedMacAny = synchronized(backgroundDiscoveredServices) {
                backgroundDiscoveredServices[savedUuid]?.get("address")
            }
            val cachedMac: String? = cachedMacAny as? String
            if (cachedMac != null && cachedMac.isNotBlank()) {
                Log.d(tag, "fallbackToNameBased: UUID $savedUuid found in background cache -> $cachedMac — connecting directly")
                wifiP2pManager?.clearServiceRequests(p2pChannel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { connectToPeer(cachedMac) }
                    override fun onFailure(r: Int) { connectToPeer(cachedMac) }
                })
                return
            }
        }

        // ── Slow path: name-based P2P peer discovery ─────────────────────────
        // Clear DNS-SD service requests so discoverServices() stops; we switch to discoverPeers().
        if (savedUuid != null &&
            !triedPassiveGoJoin &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            triedPassiveGoJoin = true
            Log.d(tag, "fallbackToNameBased: DNS-SD cache miss — trying passive-GO join for UUID=$savedUuid")
            wifiP2pManager?.clearServiceRequests(p2pChannel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { connectToGroupByUuid(savedUuid, targetName) }
                override fun onFailure(r: Int) { connectToGroupByUuid(savedUuid, targetName) }
            })
            return
        }

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
        // Resolve the UUID for this MAC from our background DNS-SD cache so that
        // the Dart layer can auto-accept invitations from known contacts without
        // showing a dialog.
        val peerUuid = synchronized(backgroundDiscoveredServices) {
            backgroundDiscoveredServices.values.firstOrNull {
                (it["address"] as? String) == peer.deviceAddress
            }?.get("uuid") as? String
        } ?: ""

        val payload = mapOf(
            "deviceName"    to peer.deviceName,
            "deviceAddress" to peer.deviceAddress,
            "peerUuid"      to peerUuid
        )
        Log.d(tag, "🔔 Notifying Flutter of incoming invitation from ${peer.deviceName} (uuid=${peerUuid.ifEmpty { "unknown" }})")
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
        // Drop Dart callbacks first so DNS-SD / P2P posts after engine detach
        // don't hit a dead binary messenger (hot restart, activity finish).
        peerListListener = null
        connectionStateListener = null
        messageListener = null
        discoveredServicesListener = null
        incomingInvitationListener = null
        cancelPassiveDiscovery()
        cancelBackgroundServiceDiscovery()
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
        if (isMultiGoGroupOwner.get()) {
            startMultiClientServer()
        } else {
            startSingleClientServer()
        }
    }

    /** Legacy single-client server — used for regular P2P unicast connections. */
    private fun startSingleClientServer() {
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

    /**
     * Multi-client TCP server for the Multi-GO Group Owner.
     *
     * Runs a persistent accept-loop.  Each accepted connection gets its own
     * coroutine-equivalent (executor thread) running [initMultiClientStreams].
     * The loop exits only when [serverSocket] is closed (via [closeSocket]).
     */
    private fun startMultiClientServer() {
        Log.d(tag, "Multi-GO: starting multi-client TCP ServerSocket on port $TCP_PORT")
        connectionPhase.set(ConnectionPhase.SOCKET_CONNECTED)  // GO is immediately "connected"
        isSocketActive.set(true)

        notifyConnectionState(
            connected = true,
            role = "group_owner",
            ipAddress = GROUP_OWNER_IP,
            socketActive = true
        )
        mainHandler.post { startHeartbeat() }

        executor.execute {
            try {
                closeSocket()
                val srv = ServerSocket(TCP_PORT)
                serverSocket = srv
                Log.d(tag, "Multi-GO: ServerSocket listening on port $TCP_PORT…")

                // Accept loop — runs until the socket is closed
                while (isSocketActive.get()) {
                    val clientSocket = try {
                        srv.accept()
                    } catch (e: Exception) {
                        if (isSocketActive.get()) {
                            Log.e(tag, "Multi-GO: ServerSocket.accept() error", e)
                        } else {
                            Log.d(tag, "Multi-GO: ServerSocket closed — accept loop ending")
                        }
                        break
                    }
                    val clientIp = clientSocket.inetAddress?.hostAddress ?: "unknown"
                    Log.d(tag, "Multi-GO: new client connected from $clientIp")
                    // Hand each client off to its own thread
                    executor.execute { initMultiClientStreams(clientSocket) }
                }
            } catch (e: Exception) {
                if (isSocketActive.get()) {
                    Log.e(tag, "Multi-GO: ServerSocket setup error", e)
                    handleSocketError(e)
                }
            }
        }
    }

    /**
     * Perform UUID handshake with a freshly accepted client, then run its
     * dedicated read-loop.  Messages from this client are relayed to ALL
     * other clients immediately (same-iteration relay).
     */
    private fun initMultiClientStreams(sock: Socket) {
        try {
            sock.keepAlive  = true
            sock.tcpNoDelay = true

            val writer = BufferedWriter(OutputStreamWriter(sock.getOutputStream(), "UTF-8"))
            val reader = BufferedReader(InputStreamReader(sock.getInputStream(), "UTF-8"))

            // ── UUID handshake ──────────────────────────────────────────────
            // Send our own UUID first so the client knows who the GO is.
            val myUuid = ownUuid ?: "unknown-go"
            val handshake = """{"__type":"__uuid_handshake__","senderUuid":"$myUuid"}"""
            writer.write(handshake); writer.newLine(); writer.flush()

            // Read the client's UUID handshake
            val firstLine = reader.readLine() ?: run {
                Log.w(tag, "Multi-GO: client closed without handshake")
                try { sock.close() } catch (_: Exception) {}
                return
            }

            var clientUuid = "unknown-${System.currentTimeMillis()}"
            try {
                val json = org.json.JSONObject(firstLine)
                if (json.optString("__type") == "__uuid_handshake__") {
                    clientUuid = json.optString("senderUuid", clientUuid)
                } else {
                    // Not a handshake — still deliver to Dart and treat as unknown client
                    mainHandler.post { messageListener?.invoke(firstLine) }
                }
            } catch (_: Exception) {
                // Malformed JSON — deliver raw
                mainHandler.post { messageListener?.invoke(firstLine) }
            }

            clientSocketMap[clientUuid] = writer
            clientSockets[clientUuid]   = sock
            val clientWriteLock = Any()
            clientWriteLocks[clientUuid] = clientWriteLock
            Log.d(tag, "Multi-GO: client $clientUuid joined (${clientSocketMap.size} total)")
            mainHandler.post { groupMemberJoinedListener?.invoke(clientUuid) }
            notifyMultiGoState()

            // Acknowledge back to client so they know they are part of the group
            val ack = """{"__type":"__group_joined__","groupOwnerUuid":"$myUuid","yourUuid":"$clientUuid"}"""
            writeFrame(writer, ack, clientWriteLock)

            // ── Per-client receive loop ─────────────────────────────────────
            try {
                while (isSocketActive.get()) {
                    val line = reader.readLine() ?: break
                    if (line == heartbeatPingMessage) continue

                    Log.v(tag, "Multi-GO received from $clientUuid: ${line.take(80)}")

                    // Relay to all OTHER clients simultaneously
                    broadcastToAllClients(line, senderUuid = clientUuid)

                    // Also deliver to GO itself (GO is a participant too)
                    mainHandler.post { messageListener?.invoke(line) }
                }
            } catch (e: Exception) {
                if (isSocketActive.get()) {
                    Log.w(tag, "Multi-GO: read error for client $clientUuid: ${e.message}")
                }
            }

            // Client disconnected — clean up
            Log.d(tag, "Multi-GO: client $clientUuid disconnected")
            removeClient(clientUuid)

        } catch (e: Exception) {
            Log.e(tag, "Multi-GO: initMultiClientStreams error", e)
            try { sock.close() } catch (_: Exception) {}
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
            val maxAttempts = 18
            var attempt = 0
            while (attempt < maxAttempts &&
                   !isSocketActive.get() &&
                   connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTING) {
                attempt++
                try {
                    Log.d(tag, "TCP connect attempt $attempt/$maxAttempts to $goIp:$TCP_PORT…")
                    Thread.sleep(1500)
                    val sock = Socket()
                    sock.connect(InetSocketAddress(goIp, TCP_PORT), 5000)
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
            // TCP keepalive: OS sends probes if idle for >2 min, catches dead connections
            // without waiting for the default ~hours-long timeout.
            sock.keepAlive = true
            // Disable Nagle algorithm — deliver small chat frames immediately.
            sock.tcpNoDelay = true

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
                startHeartbeat()
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
                        // Silently absorb heartbeat pings — never forward to Dart.
                        if (line == heartbeatPingMessage) {
                            Log.v(tag, "Heartbeat PING received — connection alive")
                            continue
                        }
                        Log.v(tag, "Wi-Fi Direct received: ${line.take(80)}")
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
        stopHeartbeat()
        val wasActive = isSocketActive.getAndSet(false)
        if (wasActive) Log.d(tag, "Closing active socket…")
        try { socketWriter?.close() } catch (_: Exception) {}
        try { activeSocket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        socketWriter = null
        activeSocket = null
        serverSocket = null
        // Close all Multi-GO client sockets
        if (clientSocketMap.isNotEmpty()) {
            Log.d(tag, "Multi-GO: closing ${clientSocketMap.size} client socket(s)")
            for ((_, w) in clientSocketMap) { try { w.close() } catch (_: Exception) {} }
            for ((_, s) in clientSockets)   { try { s.close() } catch (_: Exception) {} }
            clientSocketMap.clear()
            clientSockets.clear()
        }
        isMultiGoGroupOwner.set(false)
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
            // FAILED from discoverPeers().onFailure must be retried here — it has no
            // other recovery path. FAILED from socket/connection errors self-heals via
            // removeGroupAfterError() → CONNECTION_CHANGED → resetState(DISCONNECTED).
            // Allowing FAILED in the heartbeat is safe: discoverPeers() will either
            // recover (phase → DISCOVERING) or fail again (phase stays FAILED) and
            // we retry on the next tick. Active-connection phases are still excluded.
            val allowHeartbeat = initialized &&
                !isBusyRecovering.get() &&
                phase != ConnectionPhase.CONNECTING &&
                phase != ConnectionPhase.GROUP_FORMED &&
                phase != ConnectionPhase.SOCKET_CONNECTING &&
                phase != ConnectionPhase.SOCKET_CONNECTED
            if (allowHeartbeat) {
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
        // Preserve isPassiveGoMode when a passive GO creation is actively in flight.
        // The DISCONNECTED broadcast fired by removeGroup() (step 1 of startPassiveGoMode)
        // reaches resetState() AFTER createPassiveGoGroup() has already set
        // isPassiveGoMode=true.  Clearing the flag here causes handleConnectionInfo()
        // to miss the passive GO guard and start a ServerSocket immediately, setting
        // phase=SOCKET_CONNECTING and blocking all subsequent outbound connections.
        // pendingPassiveGoCreation is cleared by handleConnectionInfo() or on failure.
        if (!pendingPassiveGoCreation.get()) {
            isPassiveGoMode.set(false)
        } else {
            Log.d(tag, "State reset — preserving isPassiveGoMode (passive GO creation in flight)")
        }
        discoveryRetryCount.set(0)
        discoveryErrorCount.set(0)
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
            // Proactively dissolve the P2P group so the peer immediately learns about
            // this disconnect via CONNECTION_CHANGED (rather than waiting up to one
            // heartbeat interval for a TCP write failure on their side).  Without this,
            // the peer stays in SOCKET_CONNECTED and silently ignores our reconnect
            // invitations for up to 15 seconds.
            removeGroupAfterError()
        }
    }

    /**
     * Called after a socket error to tear down the Wi-Fi Direct P2P group.
     * This signals the remote peer (e.g. A06 as CLIENT) to immediately leave
     * the group rather than waiting for a TCP timeout / heartbeat failure.
     * The resulting CONNECTION_CHANGED broadcast triggers [handleDisconnect] on
     * both devices, which calls [resetState] and restarts passive discovery.
     */
    @SuppressLint("MissingPermission")
    private fun removeGroupAfterError() {
        val mgr = wifiP2pManager ?: run { resetState(restartPassiveDiscovery = true); return }
        val ch  = p2pChannel   ?: run { resetState(restartPassiveDiscovery = true); return }
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(tag, "P2P group dissolved after socket error — " +
                      "peer will detect disconnect via CONNECTION_CHANGED")
                // handleDisconnect() owns resetState() when CONNECTION_CHANGED fires.
                // No need to call it here to avoid a double-reset race.
            }
            override fun onFailure(reason: Int) {
                Log.w(tag, "removeGroup after socket error failed " +
                      "(${failureReason(reason)}) — resetting state manually")
                resetState(restartPassiveDiscovery = true)
            }
        })
    }

    // ─── Heartbeat ────────────────────────────────────────────────────────────

    /** Start sending a lightweight PING frame every [heartbeatIntervalMs] ms.
     *  Must be called from the main thread (runs on [mainHandler]).
     *  The peer's receive loop silently discards PING frames so they never
     *  reach Dart.  If the write fails the socket is already dead and
     *  [handleSocketError] tears down the connection so the app can reconnect.
     */
    private fun startHeartbeat() {
        stopHeartbeat()
        heartbeatRunnable = Runnable {
            if (isSocketActive.get() &&
                connectionPhase.get() == ConnectionPhase.SOCKET_CONNECTED) {
                executor.execute {
                    try {
                    val w = socketWriter
                    if (w != null) {
                        writeFrame(w, heartbeatPingMessage, socketWriteLock)
                        Log.v(tag, "Heartbeat PING sent")
                    }
                    } catch (e: Exception) {
                        Log.w(tag, "Heartbeat PING failed — connection lost: ${e.message}")
                        handleSocketError(e)
                        return@execute
                    }
                }
                mainHandler.postDelayed(heartbeatRunnable!!, heartbeatIntervalMs)
            }
        }.also { mainHandler.postDelayed(it, heartbeatIntervalMs) }
    }

    private fun stopHeartbeat() {
        heartbeatRunnable?.let { mainHandler.removeCallbacks(it) }
        heartbeatRunnable = null
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
                        // Wi-Fi Direct was turned off — full reset (clear all passive GO flags)
                        Log.w(tag, "Wi-Fi Direct DISABLED — resetting state machine")
                        pendingPassiveGoCreation.set(false)
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

                        // SOCKET_CONNECTING: a real group teardown also emits
                        // isConnected=false. If we always ignore it, we stay stuck in
                        // SOCKET_CONNECTING with ServerSocket.accept() blocking while
                        // peers drop to 0 (common on Samsung + mixed GO/client flows).
                        if (phase == ConnectionPhase.SOCKET_CONNECTING) {
                            wifiP2pManager?.requestConnectionInfo(p2pChannel) { info ->
                                mainHandler.post {
                                    if (connectionPhase.get() != ConnectionPhase.SOCKET_CONNECTING) {
                                        return@post
                                    }
                                    if (!info.groupFormed) {
                                        Log.w(
                                            tag,
                                            "Disconnect during SOCKET_CONNECTING — P2P group gone — resetting"
                                        )
                                        closeSocket()
                                        resetState(restartPassiveDiscovery = true)
                                        notifyConnectionState(connected = false)
                                    } else {
                                        Log.d(
                                            tag,
                                            "Disconnect during SOCKET_CONNECTING — group still formed; " +
                                                "ignoring spurious broadcast"
                                        )
                                    }
                                }
                            }
                            return
                        }

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
                            phase == ConnectionPhase.GROUP_FORMED) {
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

        // Passive GO groups are created before any relay/client joins. On some
        // OEMs (observed: Infinix SMART 7 HD) Android does not deliver another
        // connection-info callback when a client later joins that already-ready
        // group; it only updates the peer list. Without this bridge the client
        // reaches 192.168.49.1 but the GO never opens TCP/8988, producing
        // ECONNREFUSED or a long connection timeout.
        if (isPassiveGoMode.get() &&
            isGroupOwner.get() &&
            phase != ConnectionPhase.SOCKET_CONNECTING &&
            phase != ConnectionPhase.SOCKET_CONNECTED) {
            val connectedRelayClient = synchronized(availablePeers) {
                availablePeers.firstOrNull { it.status == WifiP2pDevice.CONNECTED }
            }
            if (connectedRelayClient != null) {
                Log.d(
                    tag,
                    "🔁 Passive GO: connected client ${connectedRelayClient.deviceName} " +
                        "seen in peer list — starting TCP server"
                )
                isPassiveGoMode.set(false)
                pendingPassiveGoCreation.set(false)
                connectionPhase.set(ConnectionPhase.GROUP_FORMED)
                startSocketOrFail()
                return
            }
        }

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

                // ── Cross-invite: we are the initiator targeting this exact peer ───
                // When both devices tap "connect" simultaneously, or when the first
                // connect() call collides and the peer retries, Android marks the peer
                // INVITED on OUR side too.  Since WE initiated, auto-accept silently —
                // there is no need to show the user a consent dialog.
                val target = targetDeviceName
                if (target != null &&
                    invitedPeer.deviceName.contains(target, ignoreCase = true)) {
                    Log.d(tag, "🤝 Cross-invite from our own target ${invitedPeer.deviceName} — auto-accepting (no dialog)")
                    pendingInvitedPeer = invitedPeer
                    cancelInvitationTimeout()
                    val currentGroupPhase = connectionPhase.get()
                    if (currentGroupPhase == ConnectionPhase.GROUP_FORMED) {
                        startSocketOrFail()
                    } else {
                        connectToPeer(invitedPeer.deviceAddress)
                    }
                    return
                }

                // Auto-accept silently — all OffLink devices act as relay nodes.
                // SeenCache / TTL in the DTN layer prevent loops and stale delivery.
                // Skipping the Flutter roundtrip avoids the 30-second consent window
                // and any risk of the dialog appearing on-screen.
                Log.d(tag, "↩️ Auto-accepting relay invitation from ${invitedPeer.deviceName} (${invitedPeer.deviceAddress})")
                pendingInvitedPeer = invitedPeer
                cancelInvitationTimeout()
                val currentGroupPhase = connectionPhase.get()
                if (currentGroupPhase == ConnectionPhase.GROUP_FORMED) {
                    startSocketOrFail()
                } else {
                    connectToPeer(invitedPeer.deviceAddress)
                }
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

        // ── Passive GO mode guard ─────────────────────────────────────────────
        // If we created this group ourselves via startPassiveGoMode(), we must NOT
        // advance the state machine or start a ServerSocket here — that would set
        // phase=SOCKET_CONNECTING and block all outbound user-initiated connections.
        //
        // Instead, keep phase=IDLE and check the peer list:
        //   • Empty → initial group formation, no client yet → stay IDLE.
        //   • Has CONNECTED peer → relay client just joined → proceed with socket.
        if (isPassiveGoMode.get() && info.isGroupOwner) {
            // The passive group has formed — creation is no longer pending.
            // Clear the guard so subsequent resetState() calls clean up normally.
            pendingPassiveGoCreation.set(false)
            isGroupOwner.set(true)
            groupOwnerAddress = info.groupOwnerAddress?.hostAddress
            connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            connectingTimeoutRunnable = null
            wifiP2pManager?.requestPeers(p2pChannel) { peers ->
                val relayClientJoined = peers.deviceList.any {
                    it.status == WifiP2pDevice.CONNECTED || it.status == WifiP2pDevice.INVITED
                }
                if (relayClientJoined) {
                    Log.d(tag, "🔁 Passive GO: relay client joined — starting socket (phase → GROUP_FORMED)")
                    isPassiveGoMode.set(false) // active connection now owns the state machine
                    connectionPhase.set(ConnectionPhase.GROUP_FORMED)
                    startSocketOrFail()
                } else {
                    Log.d(tag, "📡 Passive GO group ready (no client yet) — phase stays IDLE")
                    connectionPhase.set(ConnectionPhase.IDLE)
                }
            } ?: connectionPhase.set(ConnectionPhase.IDLE)
            return
        }

        // Group is forming — cancel the CONNECTING and DNS-SD timeouts
        connectingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        connectingTimeoutRunnable = null
        cancelServiceDiscoveryTimeout()
        targetUuid = null

        isGroupOwner.set(info.isGroupOwner)
        groupOwnerAddress = info.groupOwnerAddress?.hostAddress

        Log.d(
            tag,
            "✅ Wi-Fi Direct GROUP FORMED — " +
            "role=${if (info.isGroupOwner) "GROUP_OWNER" else "CLIENT"}, " +
            "groupOwnerAddress=$groupOwnerAddress"
        )

        // ── Multi-GO fast path: if we called createGroup() we skip consent ───────
        // The Multi-GO owner initiated the group itself — no peer invitation to consent.
        if (isMultiGoGroupOwner.get() && info.isGroupOwner) {
            connectionPhase.set(ConnectionPhase.GROUP_FORMED)
            onMultiGoGroupFormed(info)
            return
        }

        connectionPhase.set(ConnectionPhase.GROUP_FORMED)

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
            startSocketServer()  // routes to multi-client or single-client based on isMultiGoGroupOwner
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

    /** Called from handleConnectionInfo when createGroup() was used (Multi-GO path). */
    @SuppressLint("MissingPermission")
    private fun onMultiGoGroupFormed(info: WifiP2pInfo) {
        if (!info.groupFormed || !info.isGroupOwner) {
            Log.w(tag, "Multi-GO: expected to be GO after createGroup() but groupFormed=${info.groupFormed} isGroupOwner=${info.isGroupOwner}")
            return
        }
        isMultiGoGroupOwner.set(true)
        isGroupOwner.set(true)
        groupOwnerAddress = GROUP_OWNER_IP
        connectionPhase.set(ConnectionPhase.GROUP_FORMED)
        Log.d(tag, "Multi-GO: group formed — starting multi-client server")
        startMultiClientServer()
    }
}
