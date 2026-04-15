import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../models/broadcast_message.dart';
import '../../providers/broadcast_provider.dart';
import 'broadcast_compose_sheet.dart';

/// Feed of all received and sent broadcasts.
///
/// Broadcasts flow through the DTN mesh — a message sent here reaches
/// every in-range peer and hops up to 5 times further through their
/// neighbours, covering a wide physical area without any internet.
///
/// When a Multi-GO group is active, messages are delivered to all connected
/// clients simultaneously (milliseconds) instead of the sequential DTN path.
class BroadcastScreen extends ConsumerWidget {
  const BroadcastScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(broadcastProvider);

    String subtitle;
    if (state.isGroupOwner) {
      subtitle = '🟢 Group Owner · ${state.groupMembers.length} member(s) live';
    } else if (state.isInGroup) {
      subtitle = '🔵 In group · simultaneous delivery active';
    } else {
      subtitle = 'Sent to all nearby peers · hops up to 5×';
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Broadcasts'),
            Text(
              subtitle,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
        actions: [
          // ── Group session actions ─────────────────────────────────
          if (!state.isInGroup)
            IconButton(
              icon: const Icon(Icons.group_add),
              tooltip: 'Start broadcast group (become GO)',
              onPressed: () => _onStartGroup(context, ref),
            ),
          if (state.isInGroup)
            IconButton(
              icon: const Icon(Icons.group_off),
              tooltip: 'Leave broadcast group',
              onPressed: () => ref
                  .read(broadcastProvider.notifier)
                  .leaveBroadcastGroup(),
            ),
          IconButton(
            icon: const Icon(Icons.campaign),
            tooltip: 'Send broadcast',
            onPressed: () => _openCompose(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Group session banner ──────────────────────────────────
          if (state.isInGroup) _GroupSessionBanner(state: state),

          // ── Broadcast feed ────────────────────────────────────────
          Expanded(
            child: state.isLoading
                ? const Center(child: CircularProgressIndicator())
                : state.broadcasts.isEmpty
                    ? _EmptyState(onCompose: () => _openCompose(context, ref))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: state.broadcasts.length,
                        itemBuilder: (context, index) =>
                            _BroadcastCard(msg: state.broadcasts[index]),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isSending ? null : () => _openCompose(context, ref),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
        icon: state.isSending
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.textLight)),
              )
            : const Icon(Icons.campaign),
        label: Text(state.isSending ? 'Sending…' : 'Broadcast'),
      ),
    );
  }

  void _openCompose(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BroadcastComposeSheet(),
    );
  }

  Future<void> _onStartGroup(BuildContext context, WidgetRef ref) async {
    final ok =
        await ref.read(broadcastProvider.notifier).startBroadcastGroup();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'Group started — waiting for clients to join…'
              : 'Failed to start group. Check Wi-Fi Direct permissions.'),
          backgroundColor: ok ? Colors.green : Colors.red,
        ),
      );
    }
  }
}

// ══════════════════════════════════════════════════════════════════════
// Group session banner
// ══════════════════════════════════════════════════════════════════════

class _GroupSessionBanner extends StatelessWidget {
  final BroadcastState state;
  const _GroupSessionBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final isGO = state.isGroupOwner;
    final color = isGO ? Colors.green : Colors.blue;
    final label = isGO
        ? 'You are the Group Owner'
        : 'Connected to Group Owner';
    final memberCount = isGO ? state.groupMembers.length : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: color.withOpacity(0.12),
      child: Row(
        children: [
          Icon(
            isGO ? Icons.wifi_tethering : Icons.wifi,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: color,
                  ),
                ),
                if (isGO && memberCount != null)
                  Text(
                    '$memberCount client${memberCount == 1 ? '' : 's'} connected',
                    style: TextStyle(fontSize: 11, color: color.withOpacity(0.8)),
                  ),
                if (isGO && state.groupMembers.isNotEmpty)
                  _MemberChips(members: state.groupMembers),
              ],
            ),
          ),
          // ── Delivery mode badge ───────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isGO ? '⚡ Instant' : '📡 Relayed',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberChips extends StatelessWidget {
  final Set<String> members;
  const _MemberChips({required this.members});

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 2,
        children: members.map((uuid) {
          final short = uuid.length > 8 ? uuid.substring(0, 8) : uuid;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              short,
              style: const TextStyle(
                  fontSize: 10, color: Colors.green),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Empty state
// ══════════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  final VoidCallback onCompose;
  const _EmptyState({required this.onCompose});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.campaign_outlined,
                size: 72, color: AppColors.textSecondary.withOpacity(0.4)),
            const SizedBox(height: 20),
            Text(
              'No broadcasts yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Broadcasts reach every peer in range and hop\n'
              'up to 5× further through their neighbours.\n'
              'No internet required.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary.withOpacity(0.8),
                  height: 1.5),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: onCompose,
              icon: const Icon(Icons.campaign),
              label: const Text('Send your first broadcast'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.textLight,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Broadcast card
// ══════════════════════════════════════════════════════════════════════

class _BroadcastCard extends StatelessWidget {
  final BroadcastMessage msg;
  const _BroadcastCard({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isSelf = msg.isSelf;
    final cardColor = isSelf
        ? AppColors.primary.withOpacity(0.08)
        : AppColors.surface;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelf
              ? AppColors.primary.withOpacity(0.3)
              : Colors.grey.withOpacity(0.15),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ───────────────────────────────────────────────
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: isSelf
                      ? AppColors.primary
                      : Colors.grey.shade300,
                  child: Text(
                    isSelf
                        ? 'Y'
                        : (msg.senderName.isNotEmpty
                            ? msg.senderName[0].toUpperCase()
                            : '?'),
                    style: TextStyle(
                      color: isSelf ? Colors.white : Colors.black54,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSelf ? 'You' : msg.senderName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isSelf
                              ? AppColors.primary
                              : AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        _relativeTime(msg.dateTime),
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                // ── Hop badge ────────────────────────────────────────
                if (msg.hopCount > 0)
                  _Badge(
                    icon: Icons.alt_route,
                    label: '${msg.hopCount} hop${msg.hopCount > 1 ? 's' : ''}',
                    color: Colors.blue,
                  ),
                if (isSelf)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: _Badge(
                      icon: Icons.campaign,
                      label: 'sent',
                      color: AppColors.primary,
                    ),
                  ),
              ],
            ),

            // ── Message text ─────────────────────────────────────────
            const SizedBox(height: 10),
            Text(
              msg.text,
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),

            // ── Location ─────────────────────────────────────────────
            if (msg.hasLocation) ...[
              const SizedBox(height: 10),
              _LocationChip(lat: msg.latitude!, lng: msg.longitude!),
            ],
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays}d ago';
  }
}

// ══════════════════════════════════════════════════════════════════════
// Location chip
// ══════════════════════════════════════════════════════════════════════

class _LocationChip extends StatelessWidget {
  final double lat;
  final double lng;
  const _LocationChip({required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.teal.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.teal.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on, size: 14, color: Colors.teal),
          const SizedBox(width: 4),
          Text(
            '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
            style: const TextStyle(fontSize: 12, color: Colors.teal),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Small badge
// ══════════════════════════════════════════════════════════════════════

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Badge({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
