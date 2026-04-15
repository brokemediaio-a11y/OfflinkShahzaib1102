# OffLink — Full Implementation Reference

> **Purpose:** Complete technical documentation of everything implemented in the OffLink offline mesh-messaging app, with deep focus on the Broadcast feature, DTN delivery engine, and all bug fixes applied.

---

## Table of Contents

1. [App Overview](#1-app-overview)
2. [Architecture at a Glance](#2-architecture-at-a-glance)
3. [Transport Layer — BLE + WiFi Direct](#3-transport-layer--ble--wifi-direct)
4. [DTN Mesh Layer](#4-dtn-mesh-layer)
5. [Broadcast Feature — Complete Design](#5-broadcast-feature--complete-design)
6. [Broadcast Delivery Pipeline — Step by Step](#6-broadcast-delivery-pipeline--step-by-step)
7. [Sequential Auto-Delivery to All Peers](#7-sequential-auto-delivery-to-all-peers)
8. [Pop-up Notification (MaterialBanner)](#8-pop-up-notification-materialbanner)
9. [Storage Layer](#9-storage-layer)
10. [Riverpod State Management](#10-riverpod-state-management)
11. [WiFi Direct Reconnection & Multi-Connection Fixes](#11-wifi-direct-reconnection--multi-connection-fixes)
12. [Bug Fixes Applied](#12-bug-fixes-applied)
13. [File Reference](#13-file-reference)
14. [Key Constants & Tunable Values](#14-key-constants--tunable-values)

---

## 1. App Overview

OffLink is a **fully offline peer-to-peer messaging app** for Android. It requires **no internet connection, no SIM card, and no server** of any kind. Communication happens entirely over local radio links:

| Radio | Role |
|-------|------|
| BLE (Bluetooth Low Energy) | Device discovery — peers advertise their UUID and username in BLE scan responses |
| WiFi Direct (P2P) | Data transport — TCP socket over a WiFi Direct group carries all messages |

All message routing uses a **DTN (Delay-Tolerant Networking)** model: messages are stored locally and forwarded whenever a link becomes available. Messages survive app restarts, device sleep, and out-of-range periods.

---

## 2. Architecture at a Glance

```
┌─────────────────────────────────────────────────────────┐
│                      Flutter UI                          │
│  HomeScreen  BroadcastScreen  ChatScreen  BroadcastBanner│
└──────────────────┬──────────────────────────────────────┘
                   │ Riverpod providers
┌──────────────────▼──────────────────────────────────────┐
│              Riverpod Providers                          │
│  broadcastProvider  connectionProvider  chatProvider      │
│  conversationsProvider  deviceProvider                   │
└──────────────────┬──────────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────────┐
│            ConnectionManager (singleton)                 │
│  • Owns BLE discovery + WiFi Direct service             │
│  • Owns MeshHandler (routing/relay)                     │
│  • Drives broadcast delivery rounds                     │
│  • 30-second heartbeat timer (failsafe)                 │
└──────┬──────────────────────────────────────┬───────────┘
       │                                      │
┌──────▼──────┐                    ┌──────────▼──────────┐
│ MeshHandler │                    │   Transport Layer    │
│ • SeenCache │                    │  BleDiscoveryService │
│ • DtnQueue  │                    │  BlePeripheralService│
│ • RoutingEng│                    │  WifiDirectService   │
│ • DTNRetry  │                    │  TransportManager    │
└─────────────┘                    └─────────────────────┘
       │
┌──────▼──────────────────────────────────────────────────┐
│                    SQLite Database                       │
│  outbound_queue  broadcast_messages  routing_table       │
│  seen_cache      conversations       messages            │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Transport Layer — BLE + WiFi Direct

### BLE — Discovery Plane

**Advertising (sender side — `BlePeripheralService.kt` / `BlePeripheralManager.kt`):**
- Every device continuously advertises a BLE packet
- **Primary advertisement:** Manufacturer data containing the device's stable UUID (16 bytes)
- **Scan response:** Service data on UUID `0xFFFE` containing the user's display name (e.g., "shazu")
- Advertisement mode: `ADVERTISE_MODE_LOW_LATENCY`, TX power: `HIGH`
- UUID is derived from Android `Settings.Secure.ANDROID_ID` and stored persistently

**Scanning (receiver side — `BleDiscoveryService` + `BlePeripheralService.kt`):**
- Continuous BLE scan for manufacturer data matching the OffLink identifier
- Parses UUID from manufacturer data (method 1: raw bytes, method 2: fallback string parsing)
- Extracts username from `0xFFFE` service data in scan response
- Emits `List<DeviceModel>` on `discoveredDevices` stream → consumed by `ConnectionManager`

**Native scan fallback:** On some OEM devices (e.g., TECNO) the Flutter BLE plugin misses advertisements. A native Kotlin scanner (`BlePeripheralManager.kt`) runs in parallel and emits results via a method channel to `_handleNativeScanResult` in ConnectionManager.

### WiFi Direct — Data Plane

**Connection flow:**
```
Initiator                         Acceptor
─────────                         ────────
connectToDevice(DeviceModel)
  └─ WifiDirectService.connect(name)
     └─ WifiP2pManager.connect()
                                  discoverPeers() running
                                  PEERS_CHANGED → peer status = INVITED
                                  auto-accept: WifiP2pManager.connect() ← same peer
GROUP_FORMED (both sides)
Initiator: startServerSocket()    Acceptor: startServerSocket()
Socket TCP connection (port 8988)
UUID handshake exchange
SOCKET_CONNECTED (both sides)
_syncPendingMessages() called
```

**Key file:** `lib/services/communication/wifi_direct_service.dart` (Dart wrapper) + `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt` (native)

**Single connection constraint:** Android WiFi Direct supports only one P2P group at a time. Connecting to a second device requires disconnecting from the first.

**Port:** `8988` (hardcoded TCP socket)

**UUID handshake:** On socket open, both sides exchange a JSON message:
```json
{
  "type": "uuid_handshake",
  "senderUuid": "07c299cb-...",
  "senderName": "A52",
  "timestamp": 1712345678000
}
```
This resolves the WiFi Direct MAC-based name to the stable application UUID.

---

## 4. DTN Mesh Layer

### What is DTN?

DTN (Delay-Tolerant Networking) is a store-and-forward protocol. When no route exists to the destination, messages are buffered locally and retried whenever connectivity is available. This means messages **survive being out of range** — they are delivered automatically when peers come back in range.

### MessagePacket — Wire Format

Every message on the wire is a `MessagePacket` serialised as JSON:

```json
{
  "msgId":      "550e8400-e29b-41d4-a716-446655440000",
  "toUserId":   "07c299cb-60c8-4295-a646-f6f59f8505e7",
  "fromUserId": "753748a3-af30-4e1d-9556-f61ea0be5c09",
  "payload":    "Hello, world!",
  "ttl":        7,
  "hopCount":   0,
  "timestamp":  1712345678000,
  "type":       "message"
}
```

| Field | Description |
|-------|-------------|
| `msgId` | UUID v4, globally unique, set by originator, never changed |
| `toUserId` | Destination UUID. `'*'` for broadcasts |
| `fromUserId` | Originator UUID |
| `payload` | Message text (unicast) or JSON object (broadcast) |
| `ttl` | Decremented at each relay hop. Packet dropped when `ttl ≤ 0` |
| `hopCount` | Incremented at each hop (diagnostic only) |
| `timestamp` | Unix ms, set once by originator |
| `type` | `"message"` \| `"broadcast"` \| `"ack"` \| `"route_advert"` |

### MeshHandler — Routing Logic

**File:** `lib/services/mesh_handler.dart`

`MeshHandler` is transport-agnostic. It receives two injected callbacks from `ConnectionManager`:

| Callback | Type | Purpose |
|----------|------|---------|
| `sendViaTransport` | `Future<bool> Function(String)` | Send to one connected peer |
| `broadcastViaTransport` | `Future<int> Function(String)` | Send to ALL registered neighbours |

**Receive path (`onRawReceived`):**
```
Raw wire string
  └─ Parse to MessagePacket
  └─ type == 'broadcast' → _handleIncomingBroadcast()
  └─ type == 'route_advert' → _processRouteAdvert()
  └─ SeenCache.hasSeen? → drop (dedup)
  └─ SeenCache.markSeen()
  └─ toUserId == myUserId? → _deliverToSelf() + _sendAck()
  └─ ttl ≤ 0? → drop
  └─ _forward(packet.hop(), currentPeers)
```

**Send path (`sendMessage`):**
```
Outbound MessagePacket
  └─ type == 'broadcast' → SeenCache.markSeen() + broadcastViaTransport()
       └─ sentCount == 0 → DtnQueue.enqueue() (no peers in range)
  └─ unicast → RoutingEngine.resolve() → direct/relay/store
       └─ store → DtnQueue.enqueue()
```

### SeenCache

**File:** `lib/services/seen_cache.dart`

SQLite table `seen_cache` with columns `(msg_id TEXT PRIMARY KEY, seen_at INTEGER)`.

- `hasSeen(msgId)` — returns true if already processed
- `markSeen(msgId)` — inserts with current timestamp
- Purged after 24 hours to prevent unbounded growth
- Prevents broadcast relay loops: every device only relays each unique `msgId` once

### DtnQueue

**File:** `lib/services/dtn_queue.dart`

SQLite table `outbound_queue`:

| Column | Type | Description |
|--------|------|-------------|
| `msg_id` | TEXT PK | Packet UUID |
| `to_user_id` | TEXT | `'*'` for broadcasts |
| `payload` | TEXT | Full wire JSON |
| `ttl` | INTEGER | Remaining TTL |
| `hop_count` | INTEGER | Current hop count |
| `created_at` | INTEGER | Unix ms when enqueued |
| `attempts` | INTEGER | Number of delivery attempts |
| `last_attempt` | INTEGER | Unix ms of last attempt |
| `status` | TEXT | `'pending'` \| `'expired'` |

**Key methods:**

| Method | Behaviour |
|--------|-----------|
| `enqueue(packet)` | Insert with `CONFLICT IGNORE` (idempotent) |
| `getPendingPackets()` | Unicast packets due for retry (throttled: 30s between attempts) |
| `getPendingBroadcasts()` | ALL pending broadcasts created within last 15 min — **no throttle** |
| `recordAttempt(id, delivered: true)` | Delete row (unicast delivery confirmed) |
| `recordAttempt(id, delivered: false)` | Increment attempts; mark expired after 20 |
| `recordBroadcastSent(id)` | Update `last_attempt` only — **does NOT delete** (other peers still need it) |
| `expireStaleBroadcasts()` | Mark broadcasts older than 15 min as expired |
| `purgeExpired()` | Hard-delete expired/delivered rows older than 7 days |

### RoutingEngine

**File:** `lib/services/routing_engine.dart`

SQLite table `routing_table` maps `(user_id, next_hop_address, hop_distance, transport)`.

- Populated by route advertisements exchanged after every handshake
- `resolve(toUserId, connectedPeers)` returns `RouteDecision`:
  - `direct` — destination is directly connected
  - `relay` — a known relay path exists
  - `store` — no route known; buffer in DtnQueue

### DtnRetryLoop

**File:** `lib/services/dtn_retry_loop.dart`

Polls `DtnQueue.getPendingPackets()` every 30 seconds. For each packet, calls `MeshHandler.forward()`. This ensures buffered messages are retried when a peer connects without the app needing to explicitly manage retry state.

---

## 5. Broadcast Feature — Complete Design

### Concept

A broadcast is a **one-to-all** message that:
- Reaches every device running OffLink that is in range **or reachable within 5 relay hops**
- Requires **no manual connection** — delivery is fully automatic
- Can carry **optional GPS coordinates** from the sender
- Appears instantly as a **pop-up banner** on every recipient's screen, regardless of which screen they are on
- Is stored persistently on every device that receives it

### Broadcast vs Unicast

| Property | Unicast | Broadcast |
|----------|---------|-----------|
| `toUserId` | Target UUID | `'*'` (wildcard) |
| `type` | `"message"` | `"broadcast"` |
| Routing | RoutingEngine (direct/relay/store) | `broadcastViaTransport` (all peers) |
| Dedup | SeenCache | SeenCache |
| Queue removal | On delivery confirmation | After 15-minute window (not on first delivery) |
| Auto-connect | Only to specific peer | To ALL visible BLE peers |
| UI notification | Chat screen | MaterialBanner on any screen |

### Payload Structure

The `payload` field of a broadcast `MessagePacket` is a JSON string:

```json
{
  "text": "This is the broadcast message text",
  "senderName": "Alice",
  "lat": 1.3521,
  "lng": 103.8198
}
```

`lat` and `lng` are optional. If the user did not enable "Share location", these keys are omitted entirely.

### TTL and Hop Range

```
TTL = 5
Single WiFi Direct hop range ≈ 50 m (real-world indoors)
Logical range = TTL × single-hop range = 5 × 50 = 250+ m

Topology example:
  [Sender] ──50m──► [Peer A, hop 1] ──50m──► [Peer B, hop 2]
                                             ──50m──► [Peer C, hop 2]
              ──50m──► [Peer D, hop 1] ──50m──► [Peer E, hop 2]

All 5 peers receive the broadcast. TTL decremented at each hop.
SeenCache ensures no peer processes the same msgId twice.
```

---

## 6. Broadcast Delivery Pipeline — Step by Step

### Sending (UI → Wire)

```
User taps "Send Broadcast" in BroadcastComposeSheet
  │
  ▼
BroadcastNotifier.sendBroadcast(text, lat?, lng?)
  │
  ├─ Build payload JSON: { text, senderName, lat?, lng? }
  ├─ Create MessagePacket: toUserId='*', type='broadcast', ttl=5
  ├─ Create BroadcastMessage(isSelf=true) → BroadcastStorage.save()
  ├─ Update UI state immediately (message shows in list)
  │
  ▼
ConnectionProvider.routePacket(packet)
  │
  ▼
ConnectionManager.routePacket(packet)
  │
  ▼
MeshHandler.sendMessage(packet, currentPeers)
  │
  ├─ SeenCache.markSeen(msgId) — prevents relay loop-back
  ├─ broadcastViaTransport(packet.toWire())
  │     └─ TransportManager.broadcastToAllPeers(bytes)
  │           └─ For each registered neighbour: sendToPeer(bytes)
  │
  ├─ sentCount > 0 → sent over air now → return true
  └─ sentCount == 0 → DtnQueue.enqueue(packet) → return false
                       (delivered later by auto-connect delivery round)
```

### Receiving (Wire → UI)

```
WiFi Direct socket receives raw JSON string
  │
  ▼
ConnectionManager message stream
  │
  ▼
ConnectionProvider._handleIncomingMessageGlobally(json)
  │
  ├─ Parse JSON → check __type field
  ├─ __type == '__delivery_ack__' → _handleDeliveryAck()
  ├─ __type == '__broadcast__' → _handleIncomingBroadcast()
  └─ (else) → MessageModel unicast path
  │
  ▼ (broadcast path)
ConnectionProvider._handleIncomingBroadcast(json)
  │
  ▼
BroadcastNotifier.addReceived(json)
  │
  ├─ BroadcastMessage.fromMeshEvent(json) — parse payload JSON
  ├─ Dedup check: state.broadcasts.any(b.id == msg.id) → skip if exists
  ├─ BroadcastStorage.save(msg)
  └─ state.copyWith(broadcasts: [msg, ...state.broadcasts])
        │
        ▼
     OfflinkApp.build() ref.listen(broadcastProvider)
        │
        └─ latest.isSelf == false → _showBroadcastBanner(msg)
```

### How MeshHandler Routes Incoming Broadcasts

```
MeshHandler.onRawReceived(raw)
  │
  ├─ MessagePacket.fromWire(raw)
  ├─ type == 'broadcast' → _handleIncomingBroadcast(packet)
  │
  ▼
_handleIncomingBroadcast()
  │
  ├─ SeenCache.hasSeen(msgId)? → drop (already relayed)
  ├─ SeenCache.markSeen(msgId)
  ├─ packet.fromUserId != myUserId → _deliverBroadcastToSelf(packet)
  │     └─ Emit __broadcast__ JSON on deliveredMessages stream
  ├─ packet.isExpired (ttl ≤ 0)? → stop here
  └─ hopped = packet.hop() — ttl-1, hopCount+1
     broadcastViaTransport(hopped.toWire())
       └─ All connected neighbours receive the relayed broadcast
```

---

## 7. Sequential Auto-Delivery to All Peers

This is the core mechanism that ensures broadcasts reach **every** nearby peer without any user action.

### Problem

WiFi Direct supports **one connection at a time**. Broadcasting to N peers requires N sequential connections. The naive approach (connect to first peer, deliver, stop) meant peers 2..N never received the broadcast.

### Solution — Delivery Round

`ConnectionManager` maintains three new fields:

```dart
// msgId → set of peerIds that already received this broadcast
final Map<String, Set<String>> _broadcastDeliveredTo = {};

// Ordered list of peers still waiting for broadcast delivery
final List<DeviceModel> _broadcastDeliveryQueue = [];

// True when current WiFi Direct connection is auto-managed (not user-initiated)
bool _isAutoBroadcastConnection = false;
```

### Delivery Round Flow

```
Trigger: BLE scan / WiFi Direct DNS-SD / 30s heartbeat
  │
  ▼
_checkAndAutoConnectForPendingMessages(deviceList)
  │
  ├─ DtnQueue.getPendingBroadcasts() → active broadcasts (15 min window)
  ├─ For each visible device:
  │     allDelivered = broadcasts.every(pkt =>
  │         _broadcastDeliveredTo[pkt.msgId]?.contains(device.id) ?? false)
  │     if !allDelivered → add to _broadcastDeliveryQueue
  ├─ _broadcastDeliveryQueue not empty:
  │     target = queue.removeAt(0)
  │     _isAutoBroadcastConnection = true
  └─   connectToDevice(target)
            │
            ▼
         WiFi Direct connects (auto-accepted by target)
         UUID handshake
            │
            ▼
         _syncPendingMessages(connectedPeerId)
            │
            ├─ DtnQueue.getPendingBroadcasts() — no throttle
            ├─ Skip if _broadcastDeliveredTo[msgId].contains(peerId)
            ├─ _wifiDirectService.sendMessage(packet.toWire())
            ├─ _broadcastDeliveredTo[msgId].add(peerId)
            └─ DtnQueue.recordBroadcastSent(msgId) — update last_attempt, DO NOT DELETE
                  │
                  ▼
               .then(_scheduleNextBroadcastDelivery(peerId))
                  │
                  ├─ _isAutoBroadcastConnection == false → no-op (user connection)
                  ├─ _broadcastDeliveryQueue empty → delivery round complete
                  └─ queue not empty:
                        _lastConnectedDevice = null (suppress auto-reconnect to old peer)
                        _sendGracefulDisconnect()
                        _wifiDirectService.disconnect()
                        wait 600ms
                        next = queue.removeAt(0)
                        connectToDevice(next) ← repeat loop
```

### Why Broadcasts Are NOT Deleted from DtnQueue on First Delivery

Previously, `_syncPendingMessages` called `DtnQueue.recordAttempt(msgId, delivered: true)` which **deleted the row**. When the second peer connected, there was nothing left to send.

Now, `recordBroadcastSent(msgId)` only updates `last_attempt`. The broadcast stays in `outbound_queue` with `status = 'pending'` until:
- It is 15 minutes old (`getPendingBroadcasts()` 15-minute window filter)
- Or `expireStaleBroadcasts()` is called on next app launch

### Heartbeat Failsafe (30-Second Timer)

Production logs showed BLE scanning can silently fail. Without a fallback, broadcasts would be stuck in the queue until the user manually connects.

```dart
_broadcastHeartbeatTimer = Timer.periodic(
  const Duration(seconds: 30),
  (_) => unawaited(_triggerBroadcastDelivery()),
);
// Also fires 4 seconds after app start for queued broadcasts from previous session
Future.delayed(const Duration(seconds: 4), () => _triggerBroadcastDelivery());
```

`_triggerBroadcastDelivery()` builds the combined device list (BLE + WiFi Direct DNS-SD + native scan) and calls `_checkAndAutoConnectForPendingMessages()`. This means delivery is attempted every 30 seconds regardless of whether BLE scanning is working.

### Three Discovery Sources → All Trigger Auto-Connect

`_emitDiscoveredDevices()` is now the single place that triggers `_checkAndAutoConnectForPendingMessages`. It fires from:
1. BLE scan results (`_bleDevices`)
2. WiFi Direct background DNS-SD discoveries (`_wifiDirectDiscoveredDevices`)
3. Native BLE scan results (`_nativeScanDevices`)

Previously only BLE triggered it — WiFi Direct DNS-SD (which continued working even when BLE failed) was ignored.

---

## 8. Pop-up Notification (MaterialBanner)

### Implementation

`main.dart` — `OfflinkApp` is a `ConsumerWidget` that calls `ref.listen` on `broadcastProvider`:

```dart
ref.listen<BroadcastState>(broadcastProvider, (previous, next) {
  if (previous == null) return;
  if (next.broadcasts.length > previous.broadcasts.length) {
    final latest = next.broadcasts.first;
    if (!latest.isSelf) {
      _showBroadcastBanner(latest);
    }
  }
});
```

### Global Keys

Two `GlobalKey` instances allow the banner and navigation to work from anywhere without a `BuildContext`:

```dart
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = ...;
final GlobalKey<NavigatorState> navigatorKey = ...;
```

Both are wired into `MaterialApp(scaffoldMessengerKey: ..., navigatorKey: ...)`.

### Banner Content

```
┌─────────────────────────────────────────────────────────┐
│ 📣  Broadcast · Alice      [2 hops] 📍                  │
│     First 100 characters of the message text…            │
│                              [VIEW]  [DISMISS]           │
└─────────────────────────────────────────────────────────┘
```

- Appears at the **top** of every screen (Material 3 `MaterialBanner`)
- Shows: sender name, hop-count badge (blue), location pin (teal, if location attached)
- **VIEW** pushes `BroadcastScreen` onto the navigator stack
- **DISMISS** or **auto-dismiss after 8 seconds** removes the banner
- Multiple incoming broadcasts replace (not stack) the banner via `clearMaterialBanners()`

---

## 9. Storage Layer

### SQLite Tables

All SQLite tables share a single database instance via `DatabaseHelper`.

| Table | File | Purpose |
|-------|------|---------|
| `outbound_queue` | `dtn_queue.dart` | Store-and-forward packet buffer |
| `broadcast_messages` | `broadcast_storage.dart` | Received/sent broadcast history |
| `seen_cache` | `seen_cache.dart` | Deduplication (broadcast + unicast) |
| `routing_table` | `routing_engine.dart` | Next-hop routing entries |
| `scan_log` | `scan_log_storage.dart` | Diagnostic event log |

### `broadcast_messages` Schema

```sql
CREATE TABLE IF NOT EXISTS broadcast_messages (
  id           TEXT PRIMARY KEY,
  from_user_id TEXT NOT NULL,
  sender_name  TEXT NOT NULL DEFAULT '',
  text         TEXT NOT NULL DEFAULT '',
  latitude     REAL,
  longitude    REAL,
  timestamp    INTEGER NOT NULL,
  hop_count    INTEGER NOT NULL DEFAULT 0,
  is_self      INTEGER NOT NULL DEFAULT 0
);
```

`BroadcastStorage.getAll()` returns rows sorted by `timestamp DESC`, newest first. Maximum 200 rows returned (configurable). Rows older than 7 days are pruned by `BroadcastNotifier.pruneOld()`.

### Hive (Legacy)

`PendingMessageStorage` uses Hive (box `pending_messages`) as a legacy path for messages sent before the DTN queue was introduced. Still read during `_syncPendingMessages` for backward compatibility.

---

## 10. Riverpod State Management

### `broadcastProvider`

```
StateNotifierProvider<BroadcastNotifier, BroadcastState>
```

**`BroadcastState`:**
```dart
class BroadcastState {
  final List<BroadcastMessage> broadcasts; // newest first
  final bool isSending;
  final bool isLoading;
}
```

**`BroadcastNotifier` methods:**

| Method | Description |
|--------|-------------|
| `_load()` | Load from `BroadcastStorage` on init |
| `addReceived(json)` | Called by `ConnectionProvider` on `__broadcast__` event |
| `sendBroadcast(text, lat?, lng?)` | Build + route packet; persist immediately |
| `pruneOld()` | Delete broadcasts > 7 days |

### `connectionProvider`

```
StateNotifierProvider<ConnectionNotifier, ConnectionProviderState>
```

The `ConnectionNotifier` has a **global message listener** (`_messageSubscription`) that dispatches all incoming socket messages:

```dart
_messageSubscription = _connectionManager.incomingMessages.listen((json) {
  _handleIncomingMessageGlobally(json);
});
```

Dispatch logic:
```dart
if (jsonMap['__type'] == '__delivery_ack__') → _handleDeliveryAck()
if (jsonMap['__type'] == '__broadcast__')    → _handleIncomingBroadcast()
else                                          → MessageModel unicast path
```

### Message Flow: Broadcast Wire → UI

```
Socket → ConnectionManager._messageController
  → ConnectionProvider._messageSubscription
    → _handleIncomingMessageGlobally()
      → __type == '__broadcast__'
        → BroadcastNotifier.addReceived()
          → state.broadcasts prepend
            → ref.listen in OfflinkApp
              → _showBroadcastBanner()
```

---

## 11. WiFi Direct Reconnection & Multi-Connection Fixes

### Reconnecting Dialog Race Condition Fix

**Problem:** After `connectToDevice()` returned, the dialog could show even though the connection had already succeeded.

**Fix in `chat_screen.dart`:**
```dart
final stateAfter = ref.read(connectionProvider);
final alreadyConnected = stateAfter.state == ConnectionStateType.connected &&
    stateAfter.connectedDevice?.id == widget.device.id;
if (!alreadyConnected) {
  _showReconnectingDialog();
}
```

A safety dismiss is also added in `build()`:
```dart
if (isConnectedToThis && _reconnectDialogOpen) {
  WidgetsBinding.instance.addPostFrameCallback((_) => _dismissReconnectDialog());
}
```

### Multiple Connections Fix

**Problem:** Connecting to device B while connected to device A failed silently — the native layer returned `{"duplicate": true}` and no invitation reached device B.

**Fix in `ConnectionManager.connectToDevice()`:**
```dart
if (isConnected() && _connectedPeerId != null && _connectedPeerId != device.id) {
  await _sendGracefulDisconnect();
  _userInitiatedDisconnect = true;
  _lastConnectedDevice = null;
  _cancelReconnect();
  await _wifiDirectService.disconnect();
  // ... cleanup TransportManager + PeerDiscovery
  await Future.delayed(const Duration(milliseconds: 1500));
}
```

### WiFi Direct FAILED State Recovery

**Problem:** When `discoverPeers()` fails (non-BUSY error), the phase locks to `FAILED`. The passive-discovery heartbeat excluded `FAILED` and never called `discoverPeers()` again — device stuck permanently.

**Fix in `WifiDirectManager.kt` `schedulePassiveDiscovery()`:**

Removed `phase != ConnectionPhase.FAILED` from the heartbeat guard. Now:
- `FAILED` from discovery failure → heartbeat retries `discoverPeers()` every 30s
- `discoverPeers()` success → phase transitions to `DISCOVERING`
- Active-connection phases (`CONNECTING`, `GROUP_FORMED`, `SOCKET_*`) still protected

Also removed the FAILED exclusion from `runBackgroundServiceDiscovery()` so DNS-SD also retries.

---

## 12. Bug Fixes Applied

### Bug 1 — `_toggleLocation` crash (setState after dispose)

**File:** `lib/screens/broadcast/broadcast_compose_sheet.dart`

**Problem:** `_toggleLocation` is an `async` method that calls `Geolocator.getCurrentPosition()`. If the user dismisses the bottom sheet while the GPS fetch is in progress, the widget is disposed. When the GPS result arrives, `setState()` throws `"setState called on disposed widget"`.

**Fix:** `if (!mounted) return;` guards added before every `setState()` in the async paths:
- After permission request
- After location service check
- After `getCurrentPosition()`
- In the `catch` block

### Bug 2 — `addListener` in `build()` (exponential listeners)

**File:** `lib/screens/broadcast/broadcast_compose_sheet.dart`

**Problem:** The original code called `_textController.addListener(() => setState(() {}))` inside `build()`. Every rebuild added another listener, causing "Skipped 45 frames" jank and exponential rebuilds.

**Fix:** Listener registered once in `initState()` and removed in `dispose()`:
```dart
void initState() {
  _textController.addListener(_onTextChanged);
}
void _onTextChanged() => setState(() {});
void dispose() {
  _textController.removeListener(_onTextChanged);
}
```

### Bug 3 — BLE scan failure → auto-connect never triggers

**Problem:** `_checkAndAutoConnectForPendingMessages` was called exclusively from the BLE scan subscription. If BLE scanning silently failed, the function never ran and broadcasts stayed in `DtnQueue` indefinitely.

**Fix:**
1. Moved auto-connect trigger into `_emitDiscoveredDevices()` — now fires from BLE, WiFi Direct DNS-SD, and native scan
2. Added 30-second `Timer.periodic` heartbeat as an unconditional fallback

### Bug 4 — Broadcasts deleted after first delivery

**Problem:** `_syncPendingMessages` called `DtnQueue.recordAttempt(msgId, delivered: true)` which **deleted the row** from the queue. The second and third nearby peers never received the broadcast.

**Fix:**
- New `DtnQueue.getPendingBroadcasts()` method — returns broadcasts within 15-minute window, no throttle
- New `DtnQueue.recordBroadcastSent(msgId)` — updates `last_attempt` only, does not delete
- `_syncPendingMessages` uses these new methods for broadcast packets
- In-memory `_broadcastDeliveredTo` map tracks per-peer delivery to prevent re-sending within the same session

### Bug 5 — WiFi Direct FAILED state sticky

**Problem:** After `discoverPeers()` failed, the device stayed in `FAILED` phase permanently. Passive discovery heartbeat never retried.

**Fix:** Removed `phase != ConnectionPhase.FAILED` from heartbeat guard in `WifiDirectManager.kt`. See Section 11.

### Bug 6 — `ProviderScope.parent` deprecated

**Problem:** The original `_openCompose()` wrapped `BroadcastComposeSheet` in a `ProviderScope(parent: ...)` which was deprecated and caused runtime errors.

**Fix:** Removed the wrapper entirely. Flutter routes inherit the parent `ProviderScope` automatically.

### Bug 7 — RenderFlex overflow in compose sheet

**Problem:** The location toggle `Row` had multiple `Text` widgets with no overflow constraints, causing `RenderFlex overflowed` errors on narrow screens.

**Fix:** Extracted a `_locationStatus()` helper widget that wraps all status text in `Expanded` / `Flexible` with `TextOverflow.ellipsis`. The status area is the only `Expanded` widget in the row, leaving fixed-width widgets (icon, label, switch) at their natural size.

---

## 13. File Reference

### New Files (Broadcast Feature)

| File | Purpose |
|------|---------|
| `lib/models/broadcast_message.dart` | Data model; `fromMeshEvent()` parser; SQLite serialisation |
| `lib/services/storage/broadcast_storage.dart` | SQLite CRUD for `broadcast_messages` table |
| `lib/providers/broadcast_provider.dart` | Riverpod `StateNotifier`; send + receive + load logic |
| `lib/screens/broadcast/broadcast_screen.dart` | Feed UI (list of cards + FAB) |
| `lib/screens/broadcast/broadcast_compose_sheet.dart` | Bottom sheet; text input + GPS toggle + send |

### Modified Files

| File | Changes |
|------|---------|
| `lib/main.dart` | `OfflinkApp` → `ConsumerWidget`; `ref.listen` for banner; global keys; `expireStaleBroadcasts()` on init |
| `lib/services/dtn_queue.dart` | `getPendingBroadcasts()`, `recordBroadcastSent()`, `expireStaleBroadcasts()` |
| `lib/services/mesh_handler.dart` | `broadcastViaTransport` callback; `_handleIncomingBroadcast()`; `_deliverBroadcastToSelf()`; broadcast send/forward paths |
| `lib/services/communication/connection_manager.dart` | Delivery queue fields; `_emitDiscoveredDevices` auto-connect trigger; heartbeat timer; `_triggerBroadcastDelivery()`; `_scheduleNextBroadcastDelivery()`; `_syncPendingMessages` broadcast section; FAILED-recovery; multi-connect fix |
| `lib/providers/connection_provider.dart` | `__broadcast__` dispatch; `_handleIncomingBroadcast()` |
| `lib/screens/home/home_screen.dart` | Broadcast icon button in AppBar |
| `lib/screens/chat/chat_screen.dart` | Reconnecting dialog race fix; safety dismiss |
| `android/app/src/main/kotlin/.../WifiDirectManager.kt` | FAILED state heartbeat recovery; DNS-SD FAILED unblock |

---

## 14. Key Constants & Tunable Values

| Constant | Value | Location | Description |
|----------|-------|----------|-------------|
| Broadcast TTL | `5` | `broadcast_provider.dart` | Max relay hops for broadcasts |
| Unicast TTL | `7` | `chat_provider.dart` | Max relay hops for chat messages |
| Broadcast delivery window | `15 minutes` | `dtn_queue.dart` | How long a broadcast stays deliverable |
| Broadcast history retention | `7 days` | `broadcast_provider.dart` | Older broadcasts pruned from storage |
| DTN retry interval | `30 seconds` | `dtn_queue.dart` | Unicast retry throttle |
| DTN max attempts | `20` | `dtn_queue.dart` | Give up after 20 failed unicast attempts |
| Broadcast heartbeat | `30 seconds` | `connection_manager.dart` | Failsafe delivery trigger period |
| Heartbeat startup delay | `4 seconds` | `connection_manager.dart` | Delay before first heartbeat |
| Auto-disconnect pause | `600 ms` | `connection_manager.dart` | Wait after disconnect before next connect |
| WiFi Direct port | `8988` | `WifiDirectManager.kt` | TCP socket port |
| Passive discovery interval | `30 seconds` | `WifiDirectManager.kt` | How often `discoverPeers()` is called |
| Connection timeout | `30 seconds` | `connection_manager.dart` | Abort connect attempt after this |
| Broadcast banner auto-dismiss | `8 seconds` | `main.dart` | Banner disappears after 8 s |
| SeenCache TTL | `24 hours` | `seen_cache.dart` | When dedup entries are purged |
| Max WiFi Direct reconnect attempts | `8` | `connection_manager.dart` | Before giving up auto-reconnect |
| Multi-hop disconnect pause | `1500 ms` | `connection_manager.dart` | Wait before connecting to new peer after switching |

---

*Generated from OffLink source — April 2026*
