import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/app_colors.dart';
import '../../providers/broadcast_provider.dart';

/// Bottom sheet for composing a broadcast message with an optional
/// GPS location attachment.
///
/// The user types a message, optionally toggles "Share location",
/// and taps Send.  The broadcast is routed through the DTN mesh
/// and queued for delivery if no peers are currently connected.
class BroadcastComposeSheet extends ConsumerStatefulWidget {
  const BroadcastComposeSheet({super.key});

  @override
  ConsumerState<BroadcastComposeSheet> createState() =>
      _BroadcastComposeSheetState();
}

class _BroadcastComposeSheetState
    extends ConsumerState<BroadcastComposeSheet> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();

  bool _shareLocation = false;
  bool _gettingLocation = false;
  double? _lat;
  double? _lng;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    // Register the listener once here — NOT inside build() to avoid
    // accumulating duplicate listeners on every rebuild.
    _textController.addListener(_onTextChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  void _onTextChanged() => setState(() {});

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Location ───────────────────────────────────────────────────────────

  Future<void> _toggleLocation(bool value) async {
    if (!value) {
      setState(() {
        _shareLocation = false;
        _lat = null;
        _lng = null;
        _locationError = null;
      });
      return;
    }

    setState(() {
      _shareLocation = true;
      _gettingLocation = true;
      _locationError = null;
    });

    try {
      // Check / request location permission using permission_handler.
      var status = await Permission.location.status;
      if (status.isDenied) {
        status = await Permission.location.request();
      }
      if (!status.isGranted) {
        if (!mounted) return;
        setState(() {
          _locationError = 'Location permission denied';
          _gettingLocation = false;
          _shareLocation = false;
        });
        return;
      }

      // Check whether location services are enabled.
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() {
          _locationError = 'Location services are disabled';
          _gettingLocation = false;
          _shareLocation = false;
        });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      if (!mounted) return; // sheet may have been dismissed while awaiting
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        _gettingLocation = false;
      });
    } catch (e) {
      if (!mounted) return; // sheet may have been dismissed while awaiting
      setState(() {
        _locationError = 'Could not get location';
        _gettingLocation = false;
        _shareLocation = false;
      });
    }
  }

  // ── Send ───────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final notifier = ref.read(broadcastProvider.notifier);
    await notifier.sendBroadcast(
      text,
      lat: _shareLocation ? _lat : null,
      lng: _shareLocation ? _lng : null,
    );

    if (mounted) Navigator.of(context).pop();
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isSending = ref.watch(broadcastProvider).isSending;
    final canSend = _textController.text.trim().isNotEmpty && !isSending;

    final viewInsets = MediaQuery.of(context).viewInsets;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + viewInsets.bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Handle ──────────────────────────────────────────────────
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Title ────────────────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.campaign, color: AppColors.primary),
              const SizedBox(width: 8),
              const Text(
                'New Broadcast',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                'Hops up to 5×',
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Text field ───────────────────────────────────────────────
          TextField(
            controller: _textController,
            focusNode: _focusNode,
            maxLines: 4,
            minLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Type a message to broadcast to all nearby peers…',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 2),
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
              contentPadding: const EdgeInsets.all(14),
            ),
          ),
          const SizedBox(height: 14),

          // ── Location toggle ──────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.location_on_outlined,
                  size: 20, color: Colors.teal),
              const SizedBox(width: 6),
              const Text('Share location',
                  style: TextStyle(fontSize: 14)),
              Switch(
                value: _shareLocation,
                onChanged: _gettingLocation ? null : _toggleLocation,
                activeColor: Colors.teal,
              ),
              // Status indicator — flexible so it never overflows
              Expanded(child: _locationStatus()),
            ],
          ),
          const SizedBox(height: 14),

          // ── Info banner ──────────────────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 15,
                    color: AppColors.primary.withOpacity(0.7)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sent to ALL nearby peers and relayed up to 5 hops further. '
                    'Queued for delivery when no one is in range.',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.primary.withOpacity(0.8),
                        height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Send button ──────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: canSend ? _send : null,
              icon: isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white)),
                    )
                  : const Icon(Icons.send),
              label: Text(isSending ? 'Sending…' : 'Send Broadcast'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns the appropriate status widget for the location toggle row.
  Widget _locationStatus() {
    if (_gettingLocation) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.teal),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Getting location…',
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    if (_shareLocation && _lat != null) {
      return Text(
        '${_lat!.toStringAsFixed(4)}, ${_lng!.toStringAsFixed(4)}',
        style: const TextStyle(fontSize: 12, color: Colors.teal),
        overflow: TextOverflow.ellipsis,
      );
    }
    if (_locationError != null) {
      return Text(
        _locationError!,
        style: const TextStyle(fontSize: 12, color: Colors.red),
        overflow: TextOverflow.ellipsis,
      );
    }
    return const SizedBox.shrink();
  }
}
