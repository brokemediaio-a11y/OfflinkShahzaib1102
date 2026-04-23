# Broadcast implementation on Main

This document describes **exactly how “Broadcast” works on the `main` branch** of this repo (OffLink). It is written so another GPT/Codex can re-implement the same functionality (including DTN multi-hop behavior, local persistence, UI, and the Wi‑Fi Direct “Multi‑GO” instant-delivery mode).

---

## What “Broadcast” is in this app

Broadcast = a message sent to **all reachable peers**, not a single recipient.

- **Wire representation**: a `MessagePacket` with:
  - `type: "broadcast"`
  - `toUserId: "*"` (wildcard = everyone)
  - `ttl: 5` (maximum hop relay count)
  - `payload`: JSON string: `{ "text": "...", "senderName": "...", "lat"?: <double>, "lng"?: <double> }`
- **Delivery modes**:
  - **DTN epidemic broadcast (default/fallback)**: relay broadcast to all neighbors; buffer when no neighbors; retry and “deliver to all peers that come into range” within a 15-minute window.
  - **Multi‑GO group mode (fast path)**: a Wi‑Fi Direct Group Owner runs a **multi-client TCP server** and broadcasts to all connected client sockets simultaneously (milliseconds). Clients send to the GO; GO relays to other clients.

---

## File map (everything involved)

### Flutter UI / State

- `lib/screens/broadcast/broadcast_screen.dart`
  - Broadcast feed UI and “Start group / Leave group / Send broadcast” actions.
- `lib/screens/broadcast/broadcast_compose_sheet.dart`
  - Compose bottom sheet; optional location attachment; calls `BroadcastNotifier.sendBroadcast`.
- `lib/providers/broadcast_provider.dart`
  - `BroadcastNotifier` and `BroadcastState`.
  - Sends broadcast packets; receives broadcast events routed from the mesh layer.
- `lib/main.dart`
  - Global listener that shows a **MaterialBanner** whenever a new broadcast arrives.

### Broadcast model + persistence

- `lib/models/broadcast_message.dart`
  - Parses `__broadcast__` mesh events into UI model.
  - SQLite map serialization.
- `lib/services/storage/broadcast_storage.dart`
  - SQLite table `broadcast_messages`.

### DTN mesh + queueing + retry

- `lib/models/message_packet.dart`
  - The wire packet. Supports `hop()` and `ttl` decrement.
- `lib/services/mesh_handler.dart`
  - Core DTN routing/forwarding.
  - Special handling for `type == "broadcast"`:
    - local delivery as `__broadcast__` event
    - relay to all neighbors
    - queue when sending with no neighbors
- `lib/services/dtn_queue.dart`
  - SQLite queue table `outbound_queue`.
  - Broadcast-specific helpers:
    - `getPendingBroadcasts()` (15-minute window, no throttle)
    - `recordBroadcastSent()` (does NOT delete row)
    - `expireStaleBroadcasts()` (called at startup)
- `lib/services/dtn_retry_loop.dart`
  - 30-second periodic retry for DTN queue + housekeeping.

### Connection orchestration / broadcast delivery “rounds”

- `lib/providers/connection_provider.dart`
  - Global incoming message handler; routes `__broadcast__` events to `BroadcastProvider`.
- `lib/services/communication/connection_manager.dart`
  - Initializes MeshHandler, Wi‑Fi Direct, DTN retry loop.
  - Implements:
    - broadcast heartbeat (every 30s) calling `_triggerBroadcastDelivery()`
    - auto-connect delivery rounds for queued broadcasts to every visible peer
    - Multi‑GO group APIs: `startBroadcastGroup()`, `routeBroadcastPacket()`
- `lib/services/communication/transport_manager.dart`
  - Wraps Wi‑Fi Direct and provides:
    - `broadcastToAllPeers(...)` (DTN broadcast)
    - `sendToAllClients(...)` and `sendToGroupOwner(...)` (Multi‑GO)
- `lib/services/communication/wifi_direct_service.dart`
  - Dart `MethodChannel`/`EventChannel` wrapper around Android `WifiDirectManager.kt`.

### Android native (Wi‑Fi Direct + Multi‑GO)

- `android/app/src/main/kotlin/com/offlink/app/MainActivity.kt`
  - Wires method + event channels.
  - Provides Wi‑Fi Direct methods:
    - `initialize`, `initiateConnection`, `acceptInvitation`, `disconnect`, `sendMessage`, etc.
    - Multi‑GO methods: `startAsGroupOwner`, `joinGroupAsClient`, `broadcastToAllClients`, `getGroupMemberUuids`, …
- `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt`
  - The Wi‑Fi Direct engine + strict state machine.
  - Implements:
    - UUID-based connection via DNS‑SD (`_offlink._tcp`)
    - TCP socket transport
    - Multi‑GO multi-client TCP server accept-loop and relay.

---

## Data structures / formats

### 1) Wire packet: `MessagePacket`

Defined in `lib/models/message_packet.dart`.

- Fields: `msgId`, `toUserId`, `fromUserId`, `payload`, `ttl`, `hopCount`, `timestamp`, `type`
- Hop logic:
  - `hop()` returns a copy with `ttl - 1` and `hopCount + 1`
  - `isExpired` when `ttl <= 0`

Broadcast is just a `MessagePacket` with `type="broadcast"` and `toUserId="*"`.

### 2) Broadcast payload JSON (inside `MessagePacket.payload`)

Produced in `BroadcastNotifier.sendBroadcast()` (`lib/providers/broadcast_provider.dart`):

```json
{
  "text": "…",
  "senderName": "Alice",
  "lat": 12.3456,
  "lng": 65.4321
}
```

- `lat/lng` are optional; omitted if the user didn’t share location.

### 3) Mesh delivered event for broadcasts: `__broadcast__`

Emitted by `MeshHandler._deliverBroadcastToSelf()` (`lib/services/mesh_handler.dart`) as a JSON string on `MeshHandler.deliveredMessages`:

```json
{
  "__type": "__broadcast__",
  "msgId": "...",
  "fromUserId": "...",
  "payload": "{\"text\":\"...\",\"senderName\":\"...\"}",
  "timestamp": 1234567890,
  "hopCount": 2
}
```

Routing:

- `ConnectionManager` forwards `MeshHandler.deliveredMessages` to `ConnectionProvider` via its `_messageController`.
- `ConnectionProvider._handleIncomingMessageGlobally` detects `__type == "__broadcast__"` and calls `BroadcastNotifier.addReceived(jsonMap)`.

### 4) Local persisted model: `BroadcastMessage`

Defined in `lib/models/broadcast_message.dart`.

- `BroadcastMessage.fromMeshEvent` parses the `payload` JSON string and maps:
  - `senderName`, `text`, optional `lat/lng`
  - `timestamp`, `hopCount`
- Stored in SQLite with `BroadcastStorage` table `broadcast_messages`:
  - `id` (primary key = `msgId`)
  - `from_user_id`, `sender_name`, `text`, `latitude`, `longitude`, `timestamp`, `hop_count`, `is_self`

---

## Runtime flow (end-to-end)

### A) User sends a broadcast (default DTN mode)

1) UI opens composer
   - `BroadcastScreen` → `BroadcastComposeSheet`
2) `BroadcastComposeSheet._send()`
   - calls `broadcastProvider.notifier.sendBroadcast(text, lat?, lng?)`
3) `BroadcastNotifier.sendBroadcast`
   - builds `payloadMap` with `text`, `senderName`, and optional location
   - builds a `MessagePacket`:
     - `msgId = uuid.v4()`
     - `toUserId = "*"`
     - `type = "broadcast"`
     - `ttl = 5`
     - `hopCount = 0`
   - persists a local `BroadcastMessage(isSelf=true)` immediately so it appears in the feed even offline
   - calls `ConnectionProvider.routeBroadcastPacket(packet, senderUuid: myId)`
4) `ConnectionManager.routeBroadcastPacket` chooses path:
   - If Multi‑GO GO: send to all clients (instant)
   - Else if Multi‑GO client: send to GO (GO relays)
   - Else: `routePacket(packet)` → goes through mesh layer:
5) `MeshHandler.sendMessage` (broadcast fast path)
   - marks `SeenCache` for `msgId` to avoid echo loops
   - tries `_broadcastViaTransport(packet.toWire())`
   - if `sentCount == 0`, enqueue into `DtnQueue` (buffer until peers appear)

Result:

- If any neighbor connected now: it goes out immediately.
- If not: it is buffered and later delivered during automatic delivery rounds.

### B) A device receives a broadcast

1) Wi‑Fi Direct socket delivers a raw line string (wire JSON for `MessagePacket`)
2) `ConnectionManager._handleIncomingMessage(...)` parses:
   - Packets vs legacy JSON are distinguished using `MessagePacket.looksLikePacket(...)`.
3) `MeshHandler.onRawReceived(raw, currentPeers: ...)`
   - If `packet.type == "broadcast"` → `_handleIncomingBroadcast(...)`
4) `_handleIncomingBroadcast`
   - SeenCache dedup: drop if already seen
   - if `packet.fromUserId != myUserId`: local delivery:
     - emits `__broadcast__` event JSON onto `deliveredMessages`
   - if `!packet.isExpired`: relays hopped copy:
     - `packet.hop()` decreases TTL and increments hopCount
     - broadcast to all neighbors via transport
5) `ConnectionProvider` receives `__broadcast__` and routes to `BroadcastProvider.addReceived`
6) `BroadcastProvider.addReceived`
   - parses into `BroadcastMessage`
   - dedup by `id`
   - saves to SQLite and prepends in state
7) `main.dart` global listener shows a top `MaterialBanner` for *non-self* broadcasts.

### C) Offline / queued delivery to “all peers that come into range”

This is the “broadcast delivery round” system in `ConnectionManager`.

Key behaviors:

- Broadcast packets are kept in `DtnQueue` for a **15-minute delivery window**.
- Every time device discovery updates (BLE, native scan, Wi‑Fi Direct DNS‑SD):
  - `_emitDiscoveredDevices()` triggers `_checkAndAutoConnectForPendingMessages(deviceList)`.
- There is also a **30-second heartbeat** (`_broadcastHeartbeatTimer`) that calls `_triggerBroadcastDelivery()` even if BLE scanning silently stopped.

Delivery round:

1) `_checkAndAutoConnectForPendingMessages(discoveredDevices)`
   - If any broadcasts exist:
     - load `DtnQueue.getPendingBroadcasts()` (15-minute window)
     - build `_broadcastDeliveryQueue` with all visible devices that have NOT received every active broadcast in this session
     - set `_isAutoBroadcastConnection = true` and connect to first queued peer
2) When a Wi‑Fi Direct connection becomes fully connected:
   - `_syncPendingMessages(connectedPeerId)` runs
   - broadcast flush:
     - iterates pending broadcasts
     - skips if `_broadcastDeliveredTo[msgId]` already contains this peer
     - sends each broadcast packet to the peer via `_wifiDirectService.sendMessage(packet.toWire())`
     - records `_broadcastDeliveredTo[msgId].add(peerId)` (in-memory per session)
     - calls `DtnQueue.recordBroadcastSent(msgId)` (updates last_attempt but DOES NOT delete)
3) After sync completes, `_scheduleNextBroadcastDelivery(peerId)`:
   - if this was an auto broadcast connection:
     - gracefully disconnect
     - wait 2500ms for P2P stack cooldown
     - connect to next peer in `_broadcastDeliveryQueue`
   - if it was last peer:
     - clears `_isAutoBroadcastConnection` and emits disconnected

Important: `_broadcastDeliveredTo` is an in-memory per-session map used to prevent redundant sends during a delivery round.

---

## Multi‑GO (instant group broadcasts)

Multi‑GO exists to bypass sequential DTN delivery when a stable broadcast group is active.

### User-visible UX

- `BroadcastScreen`:
  - If not in group: “Start broadcast group (become GO)” action.
  - If in group: “Leave broadcast group”.
  - Subtitle changes:
    - GO: member count
    - Client: “simultaneous delivery active”

### Dart-side control flow

- Start GO:
  - `BroadcastNotifier.startBroadcastGroup()` → `ConnectionProvider.startBroadcastGroup()` → `ConnectionManager.startBroadcastGroup()` → `WifiDirectService.startAsGroupOwner()` → native.
- While GO is active and `socketActive == true`:
  - `ConnectionManager` calls `GroupSessionManager.becomeGroupOwner(...)`
- Member updates:
  - Native emits join/leave events on `com.offlink.wifi_direct/group_members`
  - Dart `WifiDirectService.groupMemberEvents` → `ConnectionManager` → `GroupSessionManager.handleNativeMemberEvent(...)`
  - `BroadcastProvider` listens to `GroupSessionManager().memberEvents` and syncs state for UI chips.

### Sending in Multi‑GO mode

`BroadcastNotifier.sendBroadcast()` always builds a `MessagePacket(type="broadcast", toUserId="*")`.

Routing decision is in `ConnectionManager.routeBroadcastPacket(packet, senderUuid: ...)`:

- **If GO** (`GroupSessionManager.isGroupOwner == true`):
  - Sends `packet.toWire()` to native `broadcastToAllClients(message, senderUuid)` via:
    - `TransportManager.sendToAllClients(...)` → `WifiDirectService.broadcastToAllClients(...)` → native
  - `senderUuid` is used to skip echo-back for client-originated sends that the GO is relaying.
- **If client in group**:
  - Sends `packet.toWire()` to GO using the existing socket (`WifiDirectService.sendMessage`).
  - GO’s native per-client loop relays to other clients and also delivers to GO’s Dart layer.
- **If not in group**:
  - Falls back to DTN epidemic path (`routePacket(packet)`).

### Native Multi‑GO behavior (Android)

In `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt`:

- GO creates group and runs a multi-client TCP server:
  - `startAsGroupOwner()` → `createGroup()` then (when group formed) starts `startMultiClientServer()`
  - `startMultiClientServer()`:
    - sets `connectionPhase = SOCKET_CONNECTED` immediately for GO
    - opens `ServerSocket(TCP_PORT)` and runs an accept loop
    - for each accepted socket, runs `initMultiClientStreams(sock)` in a thread
- Per client:
  - `initMultiClientStreams(sock)`:
    - sends a minimal JSON handshake: `{"__type":"__uuid_handshake__","senderUuid":"<goUuid>"}`
    - reads client’s first line expecting `__uuid_handshake__` to capture client UUID
    - stores `BufferedWriter` per client UUID in `clientSocketMap`
    - emits join event to Dart (`groupMemberJoinedListener`)
    - sends an ack JSON: `{"__type":"__group_joined__","groupOwnerUuid":"...","yourUuid":"..."}`
    - read loop:
      - for each line (except `__PING__`):
        - relays to other clients immediately: `broadcastToAllClients(line, senderUuid = clientUuid)`
        - also delivers to GO’s Dart via `messageListener(line)`
- GO broadcast API:
  - `broadcastToAllClients(message, senderUuid)` iterates `clientSocketMap` and writes to all except sender UUID.

Note: On the Dart side, `ConnectionManager` intercepts `__uuid_handshake__` messages and uses them to resolve peer identity and cache display names (see below).

---

## Identity handshake (UUID-only identity)

The system uses **UUID as the only cross-layer identity**. MAC addresses stay native-only.

### Dart handshake format

`ConnectionManager._sendUuidHandshake()` sends:

```json
{
  "__type": "__uuid_handshake__",
  "senderUuid": "<myUuid>",
  "senderName": "<myDisplayName>"
}
```

### Handling

`ConnectionManager._handleIncomingMessage(...)` intercepts `__uuid_handshake__` before routing.

`ConnectionManager._handleUuidHandshake(handshakeMap)`:

- Receiving side:
  - when `_connectedPeerId == null` (peer UUID unknown):
    - resolves `senderUuid` and updates `_connectedPeerId`
    - registers transport neighbor and emits connected state
- Initiator side:
  - updates peer name if the handshake includes a better `senderName`
- Also persists name mappings in `DeviceStorage` for future UI display.

Native Multi‑GO also uses a handshake, but its GO→client handshake is “senderUuid only”; Dart-side still has a richer handshake used across the app.

---

## Location attachment (optional)

Implemented in `BroadcastComposeSheet`:

- Uses `permission_handler` for `Permission.location`
- Uses `geolocator` to read `getCurrentPosition` with 15s timeout
- Stores `lat/lng` into the broadcast payload JSON if enabled

UI indicates:

- chip on broadcast card if `msg.hasLocation`
- banner icon if broadcast has location

---

## Persistence / cleanup rules

- Broadcasts are stored in SQLite table `broadcast_messages`.
- Broadcast UI can prune old items:
  - `BroadcastNotifier.pruneOld()` calls `BroadcastStorage.deleteOlderThan(Duration(days: 7))`.
- DTN broadcast queue:
  - Broadcast packets remain pending for up to 15 minutes via `DtnQueue.getPendingBroadcasts()` window.
  - On app start (`main.dart`): `DtnQueue.expireStaleBroadcasts()` is called.

---

## Channels / APIs that must match

### Dart ↔ Android channel names (Wi‑Fi Direct)

Defined in `WifiDirectService` and wired in `MainActivity.kt`:

- Method channel: `com.offlink.wifi_direct`
- Event channels:
  - `com.offlink.wifi_direct/messages`
  - `com.offlink.wifi_direct/connection_state`
  - `com.offlink.wifi_direct/peers`
  - `com.offlink.wifi_direct/invitation`
  - `com.offlink.wifi_direct/discovered_services`
  - `com.offlink.wifi_direct/group_members`

### Multi‑GO method names

On the Wi‑Fi Direct method channel:

- `startAsGroupOwner`
- `joinGroupAsClient`
- `broadcastToAllClients` (args: `message`, optional `senderUuid`)
- `isMultiGoOwner`
- `getGroupMemberCount`
- `getGroupMemberUuids`

---

## “Do not miss these details” checklist

- **Broadcast is a packet type**, not a different transport message. It flows through MeshHandler.
- **Local persistence happens immediately on send** (shows in UI even with no peers).
- **Dedup is enforced at multiple layers**:
  - Wire/mesh: `SeenCache` (prevents loops / duplicates)
  - UI/DB: `BroadcastProvider.addReceived` checks `state.broadcasts.any(id == msg.id)`
- **TTL/hop count**:
  - TTL starts at 5 for broadcasts and decrements on relay.
  - hopCount increments on relay.
  - UI displays hop badge when `hopCount > 0`.
- **Queued delivery to all peers**:
  - broadcast packets are held for 15 minutes and re-sent to every peer that appears during that time
  - delivery rounds sequentially connect to peers and flush broadcasts, auto-disconnecting between peers.
- **Multi‑GO**:
  - GO uses multi-client TCP server and iterates writers for true simultaneity.
  - Client→GO messages are relayed by GO to other clients and also delivered to GO’s Dart.
- **Global banner notifications**:
  - `main.dart` listens to `broadcastProvider` changes and shows a MaterialBanner for new non-self broadcasts.

---

## Primary source files (copy/port these first)

If you are rebuilding elsewhere and want the minimal “core” set to recreate the behavior, start with:

- `lib/providers/broadcast_provider.dart`
- `lib/models/broadcast_message.dart`
- `lib/services/storage/broadcast_storage.dart`
- `lib/services/mesh_handler.dart`
- `lib/services/dtn_queue.dart`
- `lib/services/dtn_retry_loop.dart`
- `lib/providers/connection_provider.dart`
- `lib/services/communication/connection_manager.dart` (broadcast delivery rounds + Multi‑GO routing)
- `lib/services/communication/transport_manager.dart`
- `lib/services/communication/wifi_direct_service.dart`
- `android/app/src/main/kotlin/com/offlink/app/MainActivity.kt`
- `android/app/src/main/kotlin/com/offlink/app/WifiDirectManager.kt`
- `lib/screens/broadcast/broadcast_screen.dart`
- `lib/screens/broadcast/broadcast_compose_sheet.dart`
- `lib/main.dart` (broadcast banner listener)

