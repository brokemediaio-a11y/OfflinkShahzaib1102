import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/communication/connection_manager.dart';
import '../../services/dtn_queue.dart';
import '../../services/routing_engine.dart';
import '../../services/seen_cache.dart';
import '../../services/peer_discovery.dart';
import '../../services/storage/device_storage.dart';
import '../../services/hop_simulator.dart';
import '../../models/device_model.dart';
import '../../utils/file_logger.dart';

/// ──────────────────────────────────────────────────────────────────────────
/// Relay Debug Panel  (hop-test branch only — do NOT merge to main)
///
/// Shows live state of every layer involved in multi-hop relay:
///   • This device's identity (UUID + name)
///   • Live peers (PeerDiscovery)
///   • BLE scan results with RSSI
///   • DTN outbound queue (all rows, all statuses)
///   • Routing table
///   • Seen-cache entry count
///   • WiFi Direct connection state
///
/// Manual triggers:
///   • Force DTN check  — runs _checkAndAutoConnectForPendingMessages now
///   • Force retry tick — runs DtnRetryLoop._tick() now
///   • Clear DTN queue  — wipe outbound_queue (reset between test runs)
///   • Clear routing    — wipe routing_table
///   • Clear seen cache — wipe seen_messages (allows re-delivering same msg)
/// ──────────────────────────────────────────────────────────────────────────
class RelayDebugScreen extends StatefulWidget {
  const RelayDebugScreen({super.key});

  @override
  State<RelayDebugScreen> createState() => _RelayDebugScreenState();
}

class _RelayDebugScreenState extends State<RelayDebugScreen> {
  Timer? _refreshTimer;

  // Snapshot data refreshed every 3 s
  String _myId      = '';
  String _myName    = '';
  String _logPath   = '';
  int    _logBytes  = 0;
  List<Map<String, dynamic>> _queueRows   = [];
  List<Map<String, dynamic>> _routeRows   = [];
  int    _seenCount  = 0;
  Map<String, dynamic> _peers = {};
  List<Map<String, dynamic>> _bleDevices  = [];
  bool   _isDtnActive = false;
  String _wifiState   = '—';

  bool _loading = false;

  // Hop simulation state
  bool _hopSimEnabled = false;
  String _hopTopology = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final cm = ConnectionManager();

    final id   = DeviceStorage.getDeviceId();
    final name = DeviceStorage.getDisplayName() ?? '(unnamed)';
    final logPath  = FileLogger.instance.filePath ?? '—';
    int logBytes = 0;
    try {
      if (logPath != '—') logBytes = await File(logPath).length();
    } catch (_) {}
    final q    = await DtnQueue.debugGetAllRows();
    final r    = await RoutingEngine.debugGetAllRoutes();
    final sc   = await SeenCache.debugGetCount();
    final peers = PeerDiscovery.instance.currentPeers;
    final ble  = cm.debugBleDevices
        .map((d) => {'name': d.name, 'id': d.id, 'rssi': d.rssi})
        .toList();
    final dtnActive = cm.debugIsDtnAutoConnection;
    final connType  = cm.currentConnectionType.name;
    final connDev   = cm.connectedDevice?.name ?? '—';
    final wState    = connType == 'none' ? 'Idle' : '$connType → $connDev';

    // Build hop sim topology description from current BLE peer list
    final hopSimEnabled = HopSimulator.isEnabled;
    final hopTopology = HopSimulator.topologyDescription(
      id,
      ble.map((d) => DeviceModel(
        id: d['id'] as String,
        name: d['name'] as String? ?? '',
        type: DeviceType.ble,
        rssi: d['rssi'] as int? ?? 0,
      )).toList(),
    );

    if (!mounted) return;
    setState(() {
      _myId       = id;
      _myName     = name;
      _logPath    = logPath;
      _logBytes   = logBytes;
      _queueRows  = q;
      _routeRows  = r;
      _seenCount  = sc;
      _peers      = {for (final e in peers.entries) e.key: e.value};
      _bleDevices = ble;
      _isDtnActive = dtnActive;
      _wifiState  = wState;
      _hopSimEnabled = hopSimEnabled;
      _hopTopology   = hopTopology;
    });
  }

  Future<void> _runAction(Future<void> Function() action, String label) async {
    setState(() => _loading = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ $label'), duration: const Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ $label failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      await _refresh();
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;

  String _ago(int? ms) {
    if (ms == null) return '—';
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60000) return '${(diff / 1000).round()}s ago';
    if (diff < 3600000) return '${(diff / 60000).round()}m ago';
    return '${(diff / 3600000).round()}h ago';
  }

  Color _rssiColor(dynamic rssi) {
    final v = rssi is int ? rssi : -100;
    if (v >= -65) return Colors.green;
    if (v >= -75) return Colors.orange;
    return Colors.red;
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'pending':   return Colors.orange;
      case 'expired':   return Colors.red;
      case 'delivered': return Colors.green;
      default:          return Colors.grey;
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        foregroundColor: Colors.white,
        title: const Text('🛰 Relay Debug', style: TextStyle(fontFamily: 'monospace')),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh now',
              onPressed: _refresh,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildHopSimCard(),
          const SizedBox(height: 10),
          _buildIdentityCard(),
          const SizedBox(height: 10),
          _buildActionsCard(),
          const SizedBox(height: 10),
          _buildConnectionCard(),
          const SizedBox(height: 10),
          _buildLivePeersCard(),
          const SizedBox(height: 10),
          _buildBleCard(),
          const SizedBox(height: 10),
          _buildQueueCard(),
          const SizedBox(height: 10),
          _buildRoutingCard(),
          const SizedBox(height: 10),
          _buildSeenCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Cards ─────────────────────────────────────────────────────────────────

  Widget _buildHopSimCard() {
    return Container(
      decoration: BoxDecoration(
        color: _hopSimEnabled
            ? const Color(0xFF1A2A1A)
            : const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _hopSimEnabled
              ? Colors.greenAccent.withOpacity(0.6)
              : const Color(0xFF30363D),
          width: _hopSimEnabled ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row with toggle ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Row(
              children: [
                const Text('🧪 Desk-Test: Hop Simulation',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 0.3)),
                const Spacer(),
                Switch(
                  value: _hopSimEnabled,
                  activeColor: Colors.greenAccent,
                  onChanged: (v) async {
                    await HopSimulator.setEnabled(v);
                    FileLogger.instance.separator(
                        'HOP SIM ${v ? "ENABLED" : "DISABLED"}');
                    await _refresh();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF30363D)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Mode description ───────────────────────────────────
                Text(
                  _hopSimEnabled
                      ? '🟢 ON — RSSI overrides active. Physical distance ignored.'
                      : '⚪ OFF — Real RSSI used. Move devices apart to test hopping.',
                  style: TextStyle(
                    color: _hopSimEnabled ? Colors.greenAccent : Colors.white54,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                // ── Explanation box ────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1117),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Sorts all 3 device UUIDs → assigns virtual positions '
                    '[0]──[1]──[2].\n'
                    'Adjacent devices get −60 dBm (NEAR).\n'
                    'Non-adjacent get −96 dBm (FAR, below −90 threshold) '
                    '→ forces relay hop.',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontFamily: 'monospace'),
                  ),
                ),
                // ── Live topology (only when enabled and peers visible) ─
                if (_hopSimEnabled && _hopTopology.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1, color: Color(0xFF30363D)),
                  const SizedBox(height: 8),
                  const Text('Simulated topology:',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    _hopTopology,
                    style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityCard() => _card(
    '📱 This Device',
    [
      _row('Name', _myName),
      _row('UUID', _myId, monospace: true, copyable: true),
      _row('UUID[0:8]', _shortId(_myId), monospace: true),
      const Divider(height: 16, color: Color(0xFF30363D)),
      _row('Log file', _logPath, monospace: true, copyable: true),
      _row('Log size', '${(_logBytes / 1024).toStringAsFixed(1)} KB'),
    ],
  );

  Widget _buildActionsCard() => _card(
    '⚡ Manual Triggers',
    [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _actionButton('Force DTN Check', Icons.search, Colors.blue, () =>
              _runAction(() => ConnectionManager().debugTriggerDtnCheck(), 'DTN check triggered')),
          _actionButton('Force Retry Tick', Icons.replay, Colors.purple, () =>
              _runAction(() => ConnectionManager().debugTriggerRetryTick(), 'Retry tick fired')),
          _actionButton('Clear DTN Queue', Icons.delete_sweep, Colors.orange, () =>
              _runAction(() => DtnQueue.debugClearAll(), 'DTN queue cleared')),
          _actionButton('Clear Routing', Icons.alt_route, Colors.orange, () =>
              _runAction(() => RoutingEngine.debugClearAll(), 'Routing table cleared')),
          _actionButton('Clear Seen Cache', Icons.visibility_off, Colors.orange, () =>
              _runAction(() => SeenCache.debugClearAll(), 'Seen cache cleared')),
        ],
      ),
      const SizedBox(height: 10),
      const Divider(height: 1, color: Color(0xFF30363D)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _actionButton('Mark Test Start', Icons.flag, Colors.green, () =>
              _runAction(() async {
                FileLogger.instance.separator('TEST START');
              }, 'Test marker written to log')),
          _actionButton('Mark Test End', Icons.flag_outlined, Colors.green, () =>
              _runAction(() async {
                FileLogger.instance.separator('TEST END');
                await FileLogger.instance.flush();
              }, 'Test end marker + flush written')),
          _actionButton('Flush Log', Icons.save, Colors.teal, () =>
              _runAction(() => FileLogger.instance.flush(), 'Log flushed to disk')),
          _actionButton('Copy Log Path', Icons.copy, Colors.blueGrey, () async {
            await Clipboard.setData(ClipboardData(text: _logPath));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Log path copied — use: adb pull <path>'),
                duration: Duration(seconds: 3),
              ));
            }
          }),
          _actionButton('View Log Tail', Icons.article_outlined, Colors.blueGrey,
              _showLogTail),
        ],
      ),
    ],
  );

  Future<void> _showLogTail() async {
    await FileLogger.instance.flush();
    String tail = '(no log file yet)';
    try {
      final file = File(_logPath);
      if (file.existsSync()) {
        final lines = await file.readAsLines();
        final last = lines.length > 120 ? lines.sublist(lines.length - 120) : lines;
        tail = last.join('\n');
      }
    } catch (e) {
      tail = 'Error reading log: $e';
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF0D1117),
        child: Column(
          children: [
            AppBar(
              backgroundColor: const Color(0xFF161B22),
              foregroundColor: Colors.white,
              title: const Text('Log tail (last 120 lines)',
                  style: TextStyle(fontSize: 13)),
              actions: [
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy all',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: tail));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')));
                  },
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  tail,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard() => _card(
    '📡 WiFi Direct State',
    [
      _row('Status', _wifiState),
      _row('DTN auto-conn', _isDtnActive ? '🟡 ACTIVE' : '⚪ idle'),
    ],
  );

  Widget _buildLivePeersCard() {
    final entries = _peers.entries.toList();
    return _card(
      '🤝 Live Peers (${entries.length})',
      entries.isEmpty
          ? [_emptyLabel('No peers connected')]
          : entries.map((e) {
              final info = e.value as PeerInfo;
              return _row(
                _shortId(info.userId),
                '${info.address}  [${info.transport}]',
                monospace: true,
              );
            }).toList(),
    );
  }

  Widget _buildBleCard() {
    return _card(
      '🔵 BLE Scan (${_bleDevices.length})',
      _bleDevices.isEmpty
          ? [_emptyLabel('No BLE devices visible')]
          : _bleDevices.map((d) {
              final rssi = d['rssi'] as int? ?? -100;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: _rssiColor(rssi)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${d['name']}  ${_shortId(d['id'] as String)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    Text(
                      '$rssi dBm',
                      style: TextStyle(
                        color: _rssiColor(rssi),
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
    );
  }

  Widget _buildQueueCard() {
    return _card(
      '📦 DTN Queue (${_queueRows.length})',
      _queueRows.isEmpty
          ? [_emptyLabel('Queue empty')]
          : _queueRows.map((r) {
              final status   = r['status'] as String? ?? '?';
              final msgId    = _shortId(r['msg_id'] as String? ?? '');
              final toUser   = _shortId(r['to_user_id'] as String? ?? '');
              final attempts = r['attempts'] as int? ?? 0;
              final hop      = r['hop_count'] as int? ?? 0;
              final ttl      = r['ttl'] as int? ?? 0;
              final created  = _ago(r['created_at'] as int?);
              final lastTry  = _ago(r['last_attempt'] as int?);
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C2128),
                  borderRadius: BorderRadius.circular(6),
                  border: Border(left: BorderSide(color: _statusColor(status), width: 3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _chip(status.toUpperCase(), _statusColor(status)),
                        const SizedBox(width: 8),
                        _mono('id: $msgId'),
                        const Spacer(),
                        _mono('hop $hop  ttl $ttl'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _mono('to: $toUser   attempts: $attempts'),
                    _mono('created: $created   last try: $lastTry'),
                  ],
                ),
              );
            }).toList(),
    );
  }

  Widget _buildRoutingCard() {
    return _card(
      '🗺 Routing Table (${_routeRows.length})',
      _routeRows.isEmpty
          ? [_emptyLabel('No routes learned yet')]
          : _routeRows.map((r) {
              final userId   = _shortId(r['user_id'] as String? ?? '');
              final nextHop  = r['next_hop_address'] as String? ?? '—';
              final dist     = r['hop_distance'] as int? ?? 0;
              final transport = r['transport'] as String? ?? '?';
              final seen     = _ago(r['last_seen'] as int?);
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C2128),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    _mono('$userId'),
                    const Text(' → ', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    Expanded(child: _mono(nextHop)),
                    const SizedBox(width: 8),
                    _chip('$dist hop', Colors.blueGrey),
                    const SizedBox(width: 4),
                    _chip(transport, Colors.teal.shade700),
                    const SizedBox(width: 4),
                    Text(seen, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
              );
            }).toList(),
    );
  }

  Widget _buildSeenCard() => _card(
    '👁 Seen Cache',
    [_row('Entries', '$_seenCount message IDs cached (48 h TTL)')],
  );

  // ── Widget primitives ─────────────────────────────────────────────────────

  Widget _card(String title, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.3)),
          ),
          const Divider(height: 1, color: Color(0xFF30363D)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value,
      {bool monospace = false, bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: GestureDetector(
              onLongPress: copyable
                  ? () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied to clipboard'),
                            duration: Duration(seconds: 1)),
                      );
                    }
                  : null,
              child: Text(
                value,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: monospace ? 'monospace' : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mono(String text) => Text(
        text,
        style: const TextStyle(
            color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
      );

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration:
            BoxDecoration(color: color.withOpacity(0.25), borderRadius: BorderRadius.circular(4)),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      );

  Widget _emptyLabel(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      );

  Widget _actionButton(
      String label, IconData icon, Color color, VoidCallback onPressed) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withOpacity(0.15),
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.4)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        textStyle: const TextStyle(fontSize: 12),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label),
      onPressed: _loading ? null : onPressed,
    );
  }
}
