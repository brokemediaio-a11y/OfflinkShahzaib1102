# OffLink Architecture Documentation

## Table of Contents
1. [High-Level Overview](#high-level-overview)
2. [Dual-Radio Architecture](#dual-radio-architecture)
3. [Layer-by-Layer Breakdown](#layer-by-layer-breakdown)
4. [Message Flow](#message-flow)
5. [Message Hopping Implementation](#message-hopping-implementation)
6. [Key Components](#key-components)
7. [Data Models](#data-models)

---

## High-Level Overview

**OffLink** is a peer-to-peer messaging application that enables offline communication between Android devices using a **dual-radio architecture**:

- **BLE (Bluetooth Low Energy)** → Control Plane (device discovery only)
- **Wi-Fi Direct** → Data Plane (actual message transport)

The app uses **UUID-based device identification** (not MAC addresses) to ensure consistent peer identity across connection sessions.

---

## Dual-Radio Architecture

### Why Two Radios?

1. **BLE Advantages:**
   - Low power consumption for continuous advertising/scanning
   - Fast device discovery (scans every few seconds)
   - Works reliably on all Android devices (with native scanner fallback)

2. **BLE Limitations:**
   - Very low bandwidth (~1-2 KB/s)
   - Not suitable for chat payload
   - Android 13+ restrictions on concurrent advertising + scanning

3. **Wi-Fi Direct Advantages:**
   - High bandwidth (~10-50 MB/s)
   - Perfect for real-time chat
   - Direct P2P connection (no router needed)

4. **Wi-Fi Direct Limitations:**
   - Higher power consumption
   - Slower discovery (requires active scanning)
   - Can only connect to one peer at a time (Android limitation)

### Solution: Hybrid Approach

```
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATION LAYER                         │
│  (ChatProvider, ConversationsProvider, UI Screens)          │
└─────────────────────────────────────────────────────────────┘
                            ↕
┌─────────────────────────────────────────────────────────────┐
│                  CONNECTION MANAGER                         │
│  (Orchestrates discovery, connection, message routing)     │
└─────────────────────────────────────────────────────────────┘
         ↕                              ↕
┌─────────────────────┐      ┌──────────────────────┐
│   CONTROL PLANE      │      │    DATA PLANE        │
│                      │      │                      │
│  BLE Discovery       │      │  Wi-Fi Direct        │
│  - Scan for peers   │      │  - TCP Socket        │
│  - Extract UUID      │      │  - Message Transport│
│  - Extract username  │      │  - High Bandwidth    │
│                      │      │                      │
│  BLE Peripheral      │      │  TransportManager    │
│  - Advertise UUID    │      │  - Route bytes       │
│  - Advertise username│      │  - Manage neighbors  │
└─────────────────────┘      └──────────────────────┘
```

---

## Layer-by-Layer Breakdown

### 1. **Application Layer** (`lib/providers/`, `lib/screens/`)

**Purpose:** UI state management and user interaction

**Components:**
- `ChatProvider` - Manages chat screen state, sends/receives messages
- `ConversationsProvider` - Manages conversation list
- `DeviceProvider` - Manages discovered devices list
- `ConnectionProvider` - Manages connection state

**Key Files:**
- `lib/providers/chat_provider.dart`
- `lib/providers/conversations_provider.dart`
- `lib/providers/device_provider.dart`
- `lib/providers/connection_provider.dart`

---

### 2. **Connection Manager** (`lib/services/communication/connection_manager.dart`)

**Purpose:** Central orchestrator for all communication

**Responsibilities:**
- Initialize BLE discovery and Wi-Fi Direct services
- Coordinate device scanning
- Handle Wi-Fi Direct connection lifecycle
- Route incoming messages to `RoutingManager`
- Manage UUID handshake (identifies peers before chat opens)
- Expose streams to UI providers

**Key Methods:**
- `initialize()` - Sets up all services
- `startScan()` - Starts BLE device discovery
- `initiateWifiDirectConnection()` - Connects to a peer via Wi-Fi Direct
- `sendMessage()` - Sends a message (creates MessageModel, routes through RoutingManager)
- `_handleIncomingMessage()` - Receives raw JSON, parses to MessageModel, routes

**State Management:**
- `_currentConnectionType` - Current active connection (wifiDirect/none)
- `_connectedPeerId` - UUID of currently connected peer
- `_connectedDevice` - DeviceModel cache for connected peer

---

### 3. **Routing Manager** (`lib/services/routing/routing_manager.dart`)

**Purpose:** Message routing, deduplication, and forwarding logic

**Responsibilities:**
- **Deduplication** - Prevents infinite loops using `messageId` cache
- **TTL Management** - Checks `hopCount` vs `maxHops`
- **Local Delivery** - Delivers messages destined for this device
- **Forwarding** - ⚠️ **CURRENTLY DISABLED** (stub implementation)

**Key Methods:**
- `routeMessage(MessageModel)` - Main entry point for all messages
- `_isDuplicate()` - Checks if message was already processed
- `_isForThisDevice()` - Checks if `finalReceiverId == myDeviceId`
- `_shouldForwardMessage()` - Checks if message should be forwarded
- `_forwardToNeighbors()` - ⚠️ **STUB** - Currently does nothing

**Message Flow:**
```
routeMessage() called
  ↓
1. Check duplicate → if duplicate, return false
  ↓
2. Mark as processed → add messageId to cache
  ↓
3. Check if for this device → if yes, deliver locally
  ↓
4. Check if should forward → if yes, call _forwardToNeighbors() (currently disabled)
  ↓
5. Drop message (TTL exceeded or other condition)
```

---

### 4. **Transport Manager** (`lib/services/communication/transport_manager.dart`)

**Purpose:** Transport-agnostic byte routing

**Responsibilities:**
- Maintain map of active peer connections (`peerId → PeerConnection`)
- Route outgoing bytes to correct transport service
- Expose `incomingBytes` stream for upper layers
- Abstract transport details from routing layer

**Key Methods:**
- `addNeighbor(PeerConnection)` - Register a new peer connection
- `removeNeighbor(String peerId)` - Remove a peer connection
- `sendToPeer(String peerId, Uint8List)` - Send bytes to specific peer
- `broadcastToAllPeers(Uint8List)` - Broadcast to all neighbors (for forwarding)
- `onBytesReceived(Uint8List, fromPeerId)` - Called when bytes arrive

**Current Limitation:**
- **Single-connection mode** - Only one peer connection at a time
- When a new peer connects, previous peer is cleared
- This prevents multi-hop forwarding (need multiple simultaneous connections)

---

### 5. **BLE Discovery Service** (`lib/services/communication/ble_discovery_service.dart`)

**Purpose:** Scan for nearby Offlink peers via BLE

**Responsibilities:**
- Scan for BLE advertisements
- Extract Device UUID from manufacturer data (`0xFFFF`)
- Extract username from scan response (`0xFFFE`)
- Emit discovered devices stream

**Key Methods:**
- `startScan()` - Starts BLE scan with flutter_blue_plus
- `stopScan()` - Stops scanning
- `_processScanResults()` - Processes scan results, extracts UUID/username

**Advertisement Format:**
- **Primary Ad (`0xFFFF`):** UUID (16 bytes)
- **Scan Response (`0xFFFE`):** Username length (1 byte) + Username bytes (up to 20 bytes)

---

### 6. **BLE Peripheral Service** (`lib/services/communication/ble_peripheral_service.dart`)

**Purpose:** Advertise this device's UUID and username

**Responsibilities:**
- Start/stop BLE advertising
- Construct advertisement packet (UUID in primary, username in scan response)
- Handle native scanner fallback (for problematic devices like TECNO/Infinix)
- Suspend/resume GATT server for scanning (Android 13+ requirement)

**Key Methods:**
- `initialize()` - Sets up GATT server
- `startAdvertising()` - Starts BLE advertisement
- `suspendForScanning()` - Stops advertising, closes GATT server
- `resumeAfterScanning()` - Restarts advertising, reopens GATT server
- `startNativeScan()` - Native Android scanner (fallback for problematic devices)

---

### 7. **Wi-Fi Direct Service** (`lib/services/communication/wifi_direct_service.dart`)

**Purpose:** Wi-Fi Direct P2P connection and TCP socket management

**Responsibilities:**
- Initiate Wi-Fi Direct connections
- Handle Group Owner / Client role negotiation
- Establish TCP socket (port 8988)
- Send/receive messages over socket
- Emit connection state changes

**Key Methods:**
- `initiateConnection(String peerMacAddress)` - Connect to a peer
- `sendMessage(String message)` - Send message over TCP socket
- `disconnect()` - Close connection

**Native Integration:**
- Calls `WifiDirectManager.kt` via MethodChannel
- Receives events via EventChannel

---

### 8. **Native Android Layer** (`android/app/src/main/kotlin/com/offlink/app/`)

**Purpose:** Low-level Android API access

**Key Files:**
- `BlePeripheralManager.kt` - BLE advertising and native scanning
- `WifiDirectManager.kt` - Wi-Fi Direct P2P management, TCP socket

**WifiDirectManager Features:**
- Passive discovery heartbeat (keeps device discoverable)
- Consent dialog for incoming connections
- Group Owner / Client role handling
- TCP socket server/client
- UUID handshake

---

## Message Flow

### Sending a Message

```
User types message in ChatScreen
  ↓
ChatProvider.sendMessage()
  ↓
ConnectionManager.sendMessage()
  ↓
Create MessageModel with:
  - messageId (UUID)
  - originalSenderId (my UUID)
  - finalReceiverId (peer UUID)
  - hopCount = 0
  - maxHops = 3
  ↓
RoutingManager.routeMessage()
  ↓
Check if for this device → NO (it's for peer)
  ↓
Check if should forward → NO (hopCount < maxHops, but forwarding disabled)
  ↓
Actually: Direct send via TransportManager.sendToPeer()
  ↓
TransportManager routes to WifiDirectService
  ↓
WifiDirectService sends over TCP socket
  ↓
Message arrives at peer device
```

### Receiving a Message

```
Bytes arrive on TCP socket (WifiDirectManager.kt)
  ↓
WifiDirectService emits message string
  ↓
ConnectionManager._handleIncomingMessage()
  ↓
Parse JSON → MessageModel.fromJson()
  ↓
RoutingManager.routeMessage()
  ↓
1. Check duplicate → if duplicate, drop
  ↓
2. Mark as processed
  ↓
3. Check if for this device → YES
  ↓
4. Deliver locally → RoutingManager._deliverLocally()
  ↓
5. RoutingManager.localMessages stream emits
  ↓
ConnectionManager listens → forwards to _messageController
  ↓
ChatProvider listens → updates UI
```

---

## Message Hopping Implementation

### ✅ **Already Implemented (Data Structures)**

The message hopping infrastructure is **fully implemented** in the data model and routing logic:

#### 1. **MessageModel Fields** (`lib/models/message_model.dart`)

```dart
@HiveField(10)
final int hopCount; // Number of hops taken

@HiveField(11)
final int maxHops; // Maximum hops allowed (TTL)
```

- `hopCount` - Tracks how many times message has been forwarded (starts at 0)
- `maxHops` - Maximum allowed hops (default: 3, acts as TTL)

#### 2. **RoutingManager Logic** (`lib/services/routing/routing_manager.dart`)

The routing logic is **complete**:

- ✅ Deduplication (`_isDuplicate()`)
- ✅ TTL checking (`hopCount >= maxHops`)
- ✅ Local delivery (`_isForThisDevice()`)
- ✅ Forwarding decision (`_shouldForwardMessage()`)
- ⚠️ **Forwarding implementation** (`_forwardToNeighbors()`) - **STUB**

#### 3. **TransportManager Support** (`lib/services/communication/transport_manager.dart`)

- ✅ `broadcastToAllPeers(Uint8List)` - Already implemented
- ✅ `getNeighbors()` - Returns list of active peer connections
- ⚠️ **Single-connection limitation** - Only one peer at a time

---

### ⚠️ **What's Missing (To Enable Hopping)**

#### 1. **Implement `RoutingManager._forwardToNeighbors()`**

**Current State:**
```dart
Future<void> _forwardToNeighbors(MessageModel message) async {
  // STUB: Forwarding disabled for FYP stability
  Logger.debug('RoutingManager: Forwarding is currently disabled (stub method)');
  
  // Future implementation:
  // 1. Increment hop count
  // final forwardedMessage = message.copyWith(hopCount: message.hopCount + 1);
  // 
  // 2. Get neighbors from TransportManager
  // final neighbors = _transportManager.getNeighbors();
  // 
  // 3. Serialize message
  // final messageBytes = _serializeMessage(forwardedMessage);
  // 
  // 4. Broadcast to all neighbors
  // await _transportManager.broadcastToAllPeers(messageBytes);
  //
  // 5. Log forwarding action
  // Logger.info('RoutingManager: Forwarded message ${message.messageId} to ${neighbors.length} neighbors');
}
```

**What Needs to Be Done:**
```dart
Future<void> _forwardToNeighbors(MessageModel message) async {
  // 1. Increment hop count
  final forwardedMessage = message.copyWith(hopCount: message.hopCount + 1);
  
  // 2. Get neighbors from TransportManager
  final neighbors = TransportManager().getNeighbors();
  if (neighbors.isEmpty) {
    Logger.warning('RoutingManager: No neighbors to forward to');
    return;
  }
  
  // 3. Serialize message to JSON bytes
  final messageJson = jsonEncode(forwardedMessage.toJson());
  final messageBytes = Uint8List.fromList(utf8.encode(messageJson));
  
  // 4. Broadcast to all neighbors (except sender - but TransportManager doesn't track sender)
  // Note: We'd need to track the sender peerId to exclude it
  final successCount = await TransportManager().broadcastToAllPeers(messageBytes);
  
  Logger.info('RoutingManager: Forwarded message ${message.messageId} '
      'to $successCount/${neighbors.length} neighbors (hopCount: ${forwardedMessage.hopCount})');
}
```

#### 2. **Enable Multi-Connection Mode in TransportManager**

**Current Limitation:**
```dart
void addNeighbor(PeerConnection peer) {
  // Single-connection mode — clear any previous peer.
  // Future: remove this clear() to support multiple simultaneous connections.
  if (_neighbors.isNotEmpty) {
    Logger.info('TransportManager: replacing existing neighbor (single-connection mode)');
    _neighbors.clear(); // ⚠️ This prevents multiple neighbors
  }
  _neighbors[peer.peerId] = peer;
}
```

**What Needs to Be Done:**
- Remove the `clear()` call
- Allow multiple `PeerConnection` entries in `_neighbors` map
- Update `getPrimaryNeighbor()` to return the most recent or highest-priority neighbor

#### 3. **Track Message Sender in RoutingManager**

**Current Issue:**
- When forwarding, we need to exclude the peer we received the message from
- `TransportManager.broadcastToAllPeers()` doesn't know which peer sent the original message

**Solution:**
- Modify `routeMessage()` to accept optional `senderPeerId` parameter
- Pass `senderPeerId` to `_forwardToNeighbors()`
- Exclude sender from broadcast list

#### 4. **Update ConnectionManager to Support Multiple Connections**

**Current State:**
- `_connectedPeerId` - Single UUID
- `_connectedDevice` - Single DeviceModel

**What Needs to Be Done:**
- Change to `Map<String, DeviceModel>` for multiple connections
- Update `initiateWifiDirectConnection()` to not disconnect existing peers
- Update `_handleWifiDirectState()` to handle multiple simultaneous connections

---

### 📋 **Enabling Hopping: Step-by-Step Checklist**

1. ✅ **Data Model** - Already complete (`hopCount`, `maxHops` fields)
2. ✅ **Deduplication** - Already complete (`_processedMessageIds` cache)
3. ✅ **TTL Logic** - Already complete (`_shouldForwardMessage()`)
4. ✅ **Broadcast Method** - Already complete (`broadcastToAllPeers()`)
5. ⚠️ **Implement Forwarding** - Need to uncomment and complete `_forwardToNeighbors()`
6. ⚠️ **Multi-Connection Support** - Remove single-connection limitation in `TransportManager`
7. ⚠️ **Sender Tracking** - Track sender peerId to exclude from forwarding
8. ⚠️ **Multiple Wi-Fi Direct Connections** - Android limitation (can only connect to one peer at a time via Wi-Fi Direct)

---

### 🚧 **Android Wi-Fi Direct Limitation**

**Critical Constraint:**
- Android Wi-Fi Direct **only supports one active P2P group at a time**
- A device can be either:
  - Group Owner (connected to one client)
  - Client (connected to one Group Owner)
  - Not connected

**Implications for Multi-Hop:**
- **True multi-hop forwarding** (Device A → Device B → Device C) requires:
  - Device B to maintain connections to both A and C simultaneously
  - This is **not possible** with standard Android Wi-Fi Direct API

**Possible Workarounds:**
1. **Sequential Forwarding** - Disconnect from sender, connect to next hop
   - Slow (connection setup takes 2-5 seconds)
   - Unreliable (connection may fail)
   
2. **Hybrid Approach** - Use BLE as secondary transport for forwarding
   - BLE can maintain multiple connections
   - Low bandwidth but acceptable for forwarding small messages
   
3. **Store-and-Forward** - Queue messages when not connected to next hop
   - When next hop becomes available, forward queued messages
   - Requires persistent message queue

---

## Key Components

### Data Models

#### **MessageModel** (`lib/models/message_model.dart`)
```dart
class MessageModel {
  final String id;                    // Legacy ID (backward compat)
  final String messageId;             // Unique message ID (for deduplication)
  final String content;                // Message text
  final String senderId;              // Immediate sender (legacy)
  final String originalSenderId;      // Original creator UUID
  final String receiverId;            // Immediate receiver (legacy)
  final String finalReceiverId;       // Final destination UUID
  final DateTime timestamp;
  final MessageStatus status;
  final bool isSent;
  final int hopCount;                 // Current hop count
  final int maxHops;                  // Maximum hops (TTL, default: 3)
}
```

#### **DeviceModel** (`lib/models/device_model.dart`)
```dart
class DeviceModel {
  final String id;                    // Device UUID (primary identifier)
  final String name;                  // Display name (username)
  final String address;               // MAC address (for Wi-Fi Direct connection)
  final DeviceType type;              // ble / wifiDirect / classicBluetooth
  final int rssi;                     // Signal strength
  final DateTime lastSeen;            // Last discovery time
  final bool isConnected;              // Currently connected?
}
```

#### **PeerConnection** (`lib/models/peer_connection_model.dart`)
```dart
class PeerConnection {
  final String peerId;                // Peer UUID
  final TransportType transportType;  // wifiDirect / ble / classicBluetooth
  final ConnectionRole role;           // central (client) / peripheral (GO)
  final DateTime lastSeen;
  final String? ipAddress;            // Wi-Fi Direct IP
  final bool socketActive;            // TCP socket ready?
}
```

---

## Summary

### ✅ **What's Working**
- Dual-radio architecture (BLE discovery + Wi-Fi Direct transport)
- UUID-based device identification
- Direct peer-to-peer messaging
- Message routing infrastructure (deduplication, TTL checking)
- Consent dialog for incoming connections
- Passive discovery heartbeat

### ⚠️ **What's Partially Implemented**
- **Message Hopping** - Data structures and logic complete, forwarding disabled
- Multi-connection support - Single connection mode enforced

### 🚧 **Limitations**
- Android Wi-Fi Direct only supports one active connection at a time
- True multi-hop forwarding requires multiple simultaneous connections
- Forwarding implementation is stubbed out (needs completion)

### 🎯 **To Enable Hopping**
1. Complete `RoutingManager._forwardToNeighbors()` implementation
2. Enable multi-connection mode in `TransportManager`
3. Add sender tracking to exclude from forwarding
4. Consider hybrid BLE+Wi-Fi Direct approach for true multi-hop

---

**Last Updated:** Based on codebase analysis as of current date
**Architecture Version:** 1.0
