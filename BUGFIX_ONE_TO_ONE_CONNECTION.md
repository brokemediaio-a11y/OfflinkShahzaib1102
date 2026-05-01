# OffLink — One-to-One Connection Bug Fixes

## Overview

This document covers the bugs identified and fixes applied to the **ONE-TO-ONE CONNECTION** module of the OffLink app (Wi-Fi Direct P2P messaging). All fixes were applied without breaking the **HOPPING (DTN relay)** or **BROADCASTING** modules.

**Devices used for testing:**
| Device | Serial | UUID |
|---|---|---|
| Samsung Galaxy A06 | R8VX800CFVF | `21aecab9-632b-49da-9157-d0dd11466058` |
| Techno Camon 30S | 127783749Y102537 | `d6b9a7cc-ee76-4485-8eb2-af39eaed18a5` |
| Infinix Smart 7 HD | 095983746G005858 | `2edfc898-c367-4460-b8a5-b6237b67cfc9` |

---

## Architecture Background

- **BLE** = control plane (discovery only — finds nearby devices by UUID)
- **Wi-Fi Direct** = data plane (all messaging)
- **Passive GO Mode** = each device runs a persistent Wi-Fi Direct Group Owner with a deterministic SSID/passphrase derived from its UUID, so relay peers can connect without dialogs
- **`connectByUuid`** = user-initiated connection path: removes own passive GO → DNS-SD service discovery → `connectToPeer(mac)` → invitation dialog
- **`connectToGroupByUuid`** = relay/DTN path: derives target's passive GO credentials from UUID → joins group directly (no dialog, API 29+)
- **`ConnectionPhase`** state machine (native): `IDLE → DISCOVERING → CONNECTING → GROUP_FORMED → SOCKET_CONNECTING → SOCKET_CONNECTED → DISCONNECTED/FAILED`

---

## Bug 1 — Spurious DISCONNECTED from Passive GO Teardown (removeGroup)

### Symptom
Within ~50–80 ms of tapping "Connect", a red error snackbar flashed on screen ("Connection failed"). Sometimes the connection eventually succeeded anyway (with a delay); other times it failed permanently.

### Root Cause
When a user initiates a connection, `connectByUuid` detects `isPassiveGoMode = true` and calls `removeGroup()` to tear down the passive GO before connecting. Before the fix, the code set `connectionPhase = DISCONNECTED` before calling `removeGroup()`.

Android's `WIFI_P2P_CONNECTION_CHANGED_ACTION` broadcast fires when the group is removed. The broadcast receiver checks `connectionPhase` to decide whether to suppress it:

```kotlin
// Broadcast receiver — spurious disconnect filter
if (phase == ConnectionPhase.DISCOVERING ||
    phase == ConnectionPhase.CONNECTING ||
    phase == ConnectionPhase.GROUP_FORMED) {
    // suppress — this is a normal mid-connection broadcast
    return
}
// otherwise → notifyConnectionState(connected=false)
```

With `phase = DISCONNECTED`, the broadcast was **not suppressed** → `notifyConnectionState(connected=false, error=null)` fired → Dart received a disconnect event → UI showed error snackbar at ~80 ms.

The same bug existed in the `initiateConnection()` fallback path (used when DNS-SD fails and name-based discovery takes over).

### Fix Applied

**File: `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt`**

**In `connectByUuid` (passive GO teardown):**
```kotlin
// BEFORE (bug):
connectionPhase.set(ConnectionPhase.DISCONNECTED)
mgr.removeGroup(ch, ...)

// AFTER (fix):
connectionPhase.set(ConnectionPhase.CONNECTING)  // broadcast receiver now filters this
mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
    override fun onSuccess() {
        connectionPhase.set(ConnectionPhase.IDLE)  // reset so retry proceeds normally
        mainHandler.postDelayed({ connectByUuid(savedUuid, savedName) }, 500)
    }
    override fun onFailure(reason: Int) {
        connectionPhase.set(ConnectionPhase.IDLE)
        mainHandler.postDelayed({ connectByUuid(savedUuid, savedName) }, 500)
    }
})
```

**In `initiateConnection` (same pattern, fallback path):**
```kotlin
connectionPhase.set(ConnectionPhase.CONNECTING)
mgr2.removeGroup(ch2, object : WifiP2pManager.ActionListener {
    override fun onSuccess() {
        connectionPhase.set(ConnectionPhase.IDLE)
        mainHandler.postDelayed({ initiateConnection(saved) }, 500)
    }
    override fun onFailure(r: Int) {
        connectionPhase.set(ConnectionPhase.IDLE)
        mainHandler.postDelayed({ initiateConnection(saved) }, 500)
    }
})
```

**Result:** The `removeGroup()` spurious broadcast is now filtered at the native level. The ~80 ms error flash was eliminated.

---

## Bug 2 — Spurious DISCONNECTED During DNS-SD Phase

### Symptom
After the passive GO teardown fix was applied, the error flash timing shifted from ~80 ms to ~320 ms. The connection still showed a red error snackbar before eventually succeeding (or failing).

### Root Cause
After passive GO is removed and `connectByUuid` retries, it enters DNS-SD service discovery with `connectionPhase = IDLE`. During this window, the Android framework fires **another** `CONNECTION_CHANGED(isConnected=false)` broadcast — a framework artifact during Wi-Fi stack settling. With `connectionPhase = IDLE`, this broadcast was NOT in the filter set `{DISCOVERING, CONNECTING, GROUP_FORMED}`, so it passed through to Dart.

In Dart's `_handleWifiDirectState`, this `error=null` disconnect event triggered the full disconnect handler:
- Cleared `_connectedPeerId`
- Emitted `ConnectionState.disconnected`
- Home screen saw `disconnected` after `connecting` → showed error snackbar

**From second test logs (A06, 02:30:00):**
```
[02:29:59.550] ConnectionManager: Wi-Fi Direct negotiation started
[02:30:00.054] Wi-Fi Direct negotiation started for techno — awaiting SOCKET_CONNECTED event…
[02:30:00.374] 🔌 WIFI_DIRECT_STATE: connected=false, error=null, phase=DISCONNECTED  ← SPURIOUS
[02:30:00.376] ConnectionManager: Wi-Fi Direct disconnected — disconnected  ← ERROR SNACKBAR
```

### Fix Applied

**File: `lib/services/communication/connection_manager.dart`**

Added a Dart-side guard in `_handleWifiDirectState` to intercept `error=null` spurious disconnects during active connection attempts:

```dart
// ── Spurious null-error disconnect during active connection ───
// The Android framework fires CONNECTION_CHANGED(isConnected=false)
// with no error during DNS-SD setup and passive-GO teardown phases.
// If we have an active connection attempt (timer running, peerId set)
// and no error string, this is a framework artifact — ignore it.
if (state.error == null &&
    _connectionTimeoutTimer != null &&
    _connectedPeerId != null) {
  Logger.info(
      'ConnectionManager: ignoring spurious null-error disconnect '
      'during active connection attempt for '
      '"${_connectedDevice?.name ?? _connectedPeerId}"');
  _connectionController.add(ConnectionState.connecting);
  return;
}
```

**Safety analysis:**
- `_connectedPeerId` is set at line 1186 of `connectToDevice`, **before** the native method channel call — so it is always set by the time any native broadcast arrives
- `_connectionTimeoutTimer` is started at line 1183, also before the native call
- After a real disconnect: timer is cancelled → `_connectionTimeoutTimer = null` → guard does NOT fire (real disconnects handled normally)
- After successful connection: timer is cancelled → guard does NOT fire
- Real failures with `error != null` bypass the `error == null` condition → handled normally

**Result:** The ~320 ms spurious disconnect is silently ignored. The UI stays in "connecting" state and the actual connection proceeds uninterrupted.

---

## Bug 3 — Dart Timeout Too Short (30s)

### Symptom
Connection attempt showed a timeout error after 30 seconds, but the connection actually succeeded shortly after (sometimes at ~37 seconds). User saw an error for ~7 seconds before the app snapped to the chat screen.

### Root Cause
The Dart watchdog timer was set to 30 seconds. The native Android Wi-Fi Direct `connectingTimeoutRunnable` fires at 45 seconds. On some OEM devices (Infinix, Samsung A06), the P2P group formation genuinely takes 35–40 seconds. The Dart timer was firing first, calling `disconnect()`, but by that point the native P2P stack was too far along to actually abort — the connection succeeded anyway, but the UI had already shown an error.

### Fix Applied

**File: `lib/services/communication/connection_manager.dart`**

```dart
// BEFORE:
static const int _connectionTimeoutSeconds = 30;

// AFTER:
/// 50 s gives the native 45 s connectingTimeoutRunnable time to fire first,
/// avoiding premature Dart-side cancellation of slow-forming P2P groups.
static const int _connectionTimeoutSeconds = 50;
```

**Result:** Dart timer fires at 50 s (after the native 45 s watchdog). Slow connections are no longer prematurely aborted.

---

## Bug 4 — "Wi-Fi Direct Busy; Clearing and Retrying" Treated as Failure

### Symptom
Connection attempt immediately reported an error with a message about "busy".

### Root Cause
When `discoverPeers()` is called while the Wi-Fi Direct stack is busy, Android returns `BUSY`. The native layer's retry handler emits `notifyConnectionState(error="Wi-Fi Direct was busy; clearing and retrying…")`. The Dart handler previously treated any non-null error during the `!state.connected` branch as a permanent failure — clearing `_connectedPeerId` and emitting `ConnectionState.error`.

### Fix Applied

**File: `lib/services/communication/connection_manager.dart`**

```dart
// ── Transient P2P stack BUSY during active connection attempt ──
if (state.error != null &&
    state.error!.contains('clearing and retrying') &&
    _connectionTimeoutTimer != null &&
    _connectedPeerId != null) {
  Logger.info('ConnectionManager: P2P stack busy — native layer '
      'self-recovering, keeping connecting state for "${_connectedDevice?.name ?? _connectedPeerId}"');
  _connectionController.add(ConnectionState.connecting);
  return;
}
```

**Result:** The BUSY transient state is treated as "still connecting" rather than a permanent failure.

---

## Bug 5 — Connection Fails When Target's Wi-Fi Direct Name Does Not Match App Name

### Symptom
After the error-flash fixes, A06→Techno connection would spin for the full 50-second timeout and then fail. Native logs showed A06 could see "TECNO CAMON 30S" in the peer list the entire time but never connected:

```
W/OfflinkWifiDirect(32419): Auto-connect skipped — no peer matching 'techno' found
  (2 other peer(s) visible). Retrying discovery in 4 s…
```

### Root Cause

The `connectByUuid` connection flow:
1. **Check peer cache** — look for UUID in Wi-Fi Direct device name → `"TECNO CAMON 30S"` does not contain the UUID → miss
2. **DNS-SD service discovery (15 s)** → fails silently (Techno is in passive GO mode, which suppresses DNS-SD advertisements)
3. **Background DNS-SD cache** (`backgroundDiscoveredServices`) → empty for the same reason
4. **Name-based fallback** (`initiateConnection("techno")`) → looks for a peer whose Wi-Fi Direct name contains `"techno"` → `"TECNO CAMON 30S"` does NOT contain `"techno"`

**Critical mismatch:** "techno" (the user-chosen app display name, from BLE advertisement) ≠ "TECNO" (the phone brand name in Wi-Fi Direct peer list). These are different words — "techno" has an 'h', "TECNO" does not. No amount of case-insensitive matching helps.

**Why DNS-SD fails:** Techno is in passive GO mode (hosting a Wi-Fi Direct group). While in this state, its Wi-Fi radio is primarily serving the group and does not reliably respond to DNS-SD service queries from other devices.

### Fix Applied

**File: `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt`**

**Step 1 — Add `triedPassiveGoJoin` flag** to prevent an infinite retry loop:

```kotlin
// True after fallbackToNameBased has already tried connectToGroupByUuid for the
// current connection attempt.
@Volatile private var triedPassiveGoJoin = false
```

**Step 2 — Reset flag on fresh connection attempts** (in `connectByUuid` main body):

```kotlin
// Detect a fresh user-initiated attempt by targetDeviceName being null
// (cleared by resetState between sessions). Retries from doGroupConnect.onFailure
// restore targetDeviceName before calling, so they leave the flag intact.
if (this.targetDeviceName == null) triedPassiveGoJoin = false

this.targetUuid       = targetUuid
this.targetDeviceName = fallbackName
```

**Step 3 — Add passive GO join path in `fallbackToNameBased`** (between cache check and name-based fallback):

```kotlin
// ── Passive GO join (API 29+) — try BEFORE name-based discovery ─────
// Since we know the target UUID, we can derive its passive-GO group
// credentials (deterministic SSID + passphrase) and join directly —
// bypassing DNS-SD and name matching entirely.
// Only tried once per connection attempt (triedPassiveGoJoin flag)
// to avoid looping when the target has no passive GO group.
if (savedUuid != null && !triedPassiveGoJoin &&
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
    triedPassiveGoJoin = true
    Log.d(tag, "fallbackToNameBased: DNS-SD cache miss — trying passive-GO join " +
            "for UUID=$savedUuid (once per attempt)")
    wifiP2pManager?.clearServiceRequests(p2pChannel, object : WifiP2pManager.ActionListener {
        override fun onSuccess() { connectToGroupByUuid(savedUuid, targetName) }
        override fun onFailure(r: Int) { connectToGroupByUuid(savedUuid, targetName) }
    })
    return
}
// ... name-based fallback follows ...
```

**How it works:**
- `connectToGroupByUuid` derives the SSID (`DIRECT-OL-{first8UUIDchars}`) and passphrase from the target UUID
- It directly joins the target's passive GO group using `WifiP2pConfig.Builder.setNetworkName().setPassphrase()` (no peer name or DNS-SD needed)
- The Techno device receives A06 as a new client to its passive GO group; the handshake identifies the connection as a direct chat (`relay=false`)

**Loop prevention:**
- If the target has no passive GO group, `doGroupConnect.onFailure` fires → restores `targetDeviceName` → calls `connectByUuid` again
- On the retry, `this.targetDeviceName != null` → `triedPassiveGoJoin` is NOT reset → second `fallbackToNameBased` sees `triedPassiveGoJoin = true` → skips passive GO join → falls through to name-based discovery
- Dart 50 s timeout is the final safety net

**Result:** A06 can connect to Techno even when DNS-SD fails and the Wi-Fi Direct hardware name ("TECNO CAMON 30S") doesn't match the app display name ("techno"). The passive GO join path resolves the UUID-to-group credentials locally without any network discovery.

---

## Summary of All Changes

### `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt`

| Change | Purpose |
|---|---|
| `connectionPhase.set(CONNECTING)` before `removeGroup()` in `connectByUuid` | Suppresses spurious CONNECTION_CHANGED broadcast from passive GO teardown |
| `connectionPhase.set(IDLE)` in `removeGroup` callbacks in `connectByUuid` | Resets phase so retry can proceed through normal flow |
| Same `CONNECTING`/`IDLE` pattern in `initiateConnection` fallback path | Same protection for name-based fallback's GO teardown |
| `@Volatile private var triedPassiveGoJoin = false` field | Prevents infinite loop in passive GO join fallback |
| `if (this.targetDeviceName == null) triedPassiveGoJoin = false` in `connectByUuid` | Resets flag on each fresh user-initiated connection attempt |
| Passive GO join path in `fallbackToNameBased` | Connects to target's passive GO group when DNS-SD + name matching both fail |

### `lib/services/communication/connection_manager.dart`

| Change | Purpose |
|---|---|
| `_connectionTimeoutSeconds` 30 → 50 | Prevents premature timeout before native 45 s watchdog fires |
| `error=null` spurious disconnect guard in `_handleWifiDirectState` | Ignores framework artifact disconnects during active connection attempts |
| `'clearing and retrying'` BUSY guard in `_handleWifiDirectState` | Treats transient P2P stack BUSY as "still connecting", not a failure |

---

## Connection Flow After All Fixes

```
User taps "Connect to Techno"
        │
        ▼
connectByUuid(uuid, "techno")
        │
        ├─ [passive GO active] → connectionPhase=CONNECTING
        │                      → removeGroup()  [spurious broadcast FILTERED]
        │                      → connectionPhase=IDLE → retry after 500ms
        │
        ▼
connectByUuid (retry, no passive GO)
        │
        ├─ triedPassiveGoJoin = false  (fresh attempt)
        ├─ Check peer name for UUID → not found
        │
        ▼
DNS-SD service discovery (15 s timeout)
        │
        ├─ [success] → connectToPeer(mac) → group forms → socket → CONNECTED ✓
        │
        ├─ [spurious disconnects during this window]
        │     → Dart guard: error=null + timer running + peerId set
        │     → ignored, UI stays "connecting" ✓
        │
        └─ [timeout] → fallbackToNameBased("techno")
                │
                ├─ Background cache hit? → connectToPeer(cached_mac) ✓
                │
                ├─ [API 29+, !triedPassiveGoJoin] → connectToGroupByUuid(uuid, "techno")
                │     → derives SSID=DIRECT-OL-D6B9A7CC, passphrase from UUID
                │     → joins Techno's passive GO group directly ✓
                │     → handshake: relay=false → chat screen opens ✓
                │
                └─ [API < 29 or triedPassiveGoJoin=true] → initiateConnection("techno")
                      → name-based peer discovery (last resort)
```
