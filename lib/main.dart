import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/app_colors.dart';
import 'models/broadcast_message.dart';
import 'models/message_model.dart';
import 'models/conversation_model.dart';
import 'models/known_contact_model.dart';
import 'providers/broadcast_provider.dart';
import 'screens/broadcast/broadcast_screen.dart';
import 'screens/splash/splash_screen.dart';
import 'services/storage/message_storage.dart';
import 'services/storage/device_storage.dart';
import 'services/hop_simulator.dart';
import 'services/storage/known_contacts_storage.dart';
import 'services/storage/pending_message_storage.dart';
import 'services/database_helper.dart';
import 'services/dtn_queue.dart';
import 'utils/logger.dart';
import 'utils/file_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Initialize Hive ───────────────────────────────────────────────
  await Hive.initFlutter();

  // ── Register Hive adapters ────────────────────────────────────────
  // typeId 0 — MessageModel
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(MessageModelAdapter());
  }
  // typeId 1 — MessageStatus enum
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(MessageStatusAdapter());
  }
  // typeId 2 — ConversationModel
  if (!Hive.isAdapterRegistered(2)) {
    Hive.registerAdapter(ConversationModelAdapter());
  }
  // typeId 3 — KnownContact (new: store-and-forward known peers)
  if (!Hive.isAdapterRegistered(3)) {
    Hive.registerAdapter(KnownContactAdapter());
  }

  // ── Initialize storage services ───────────────────────────────────
  await MessageStorage.init();
  await DeviceStorage.init();
  HopSimulator.load();
  await KnownContactsStorage.init();
  await PendingMessageStorage.init();

  // ── Initialize SQLite (DTN routing / seen cache / outbound queue) ────
  await DatabaseHelper.database;

  // ── Initialize file logger (hop-test branch) ──────────────────────────
  // Names the log file after the device's display name (set it to A / B / C
  // in Settings before each test run so files are easy to identify).
  final _logDeviceName = DeviceStorage.getDisplayName() ?? 'unknown';
  final _logDeviceId   = DeviceStorage.getDeviceId();
  await FileLogger.instance.init(
    deviceName: _logDeviceName,
    deviceId:   _logDeviceId,
  );
  Logger.info('FileLogger ready — device=$_logDeviceName  file=${FileLogger.instance.filePath}');

  // Expire any broadcast packets left over from a previous session that are
  // now older than the 15-minute delivery window.
  await DtnQueue.expireStaleBroadcasts();

  // ── MIGRATION: one-time clear of pre-routing messages ────────────
  // The MessageModel gained routing fields (messageId, hopCount, etc.)
  // Old Hive boxes may contain objects with missing fields.
  // Guard with a flag so this only runs once per install.
  const _migrationKey = 'routing_v1';
  if (!DeviceStorage.getMigrationFlag(_migrationKey)) {
    try {
      final messageBox = await Hive.openBox<MessageModel>('messages');
      if (messageBox.isNotEmpty) {
        Logger.info(
            'MIGRATION: Clearing ${messageBox.length} old messages '
            'for multi-hop architecture update');
        await messageBox.clear();
        Logger.info('MIGRATION: Message storage cleared successfully');
      }

      final conversationBox =
          await Hive.openBox<ConversationModel>('conversations');
      if (conversationBox.isNotEmpty) {
        Logger.info(
            'MIGRATION: Clearing ${conversationBox.length} old conversations');
        await conversationBox.clear();
        Logger.info('MIGRATION: Conversations cleared successfully');
      }

      await DeviceStorage.setMigrationFlag(_migrationKey);
      Logger.info('MIGRATION: Flag set — will not run again');
    } catch (e) {
      Logger.error('MIGRATION: Error clearing storage', e);
      // Continue anyway — app will work with empty storage
    }
  }

  runApp(
    const ProviderScope(
      child: OfflinkApp(),
    ),
  );
}

// ── Global keys for ScaffoldMessenger and Navigator ──────────────────────────
// These allow broadcast pop-ups to be shown from any screen without a
// BuildContext reference.
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey =
    GlobalKey<NavigatorState>();

class OfflinkApp extends ConsumerWidget {
  const OfflinkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ── Global broadcast pop-up listener ─────────────────────────────────
    // Fires whenever a NEW broadcast arrives. We compare list lengths — a new
    // broadcast prepends to the list, so length increases by 1.
    // We only show a banner for messages from OTHER peers (not our own sends).
    ref.listen<BroadcastState>(broadcastProvider, (previous, next) {
      if (previous == null) return;
      if (next.broadcasts.length > previous.broadcasts.length) {
        final latest = next.broadcasts.first;
        if (!latest.isSelf) {
          _showBroadcastBanner(latest);
        }
      }
    });

    return MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      navigatorKey: navigatorKey,
      title: 'OFFLINK',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.background,
      ),
      home: const SplashScreen(),
    );
  }
}

/// Show a top-anchored [MaterialBanner] whenever a broadcast is received.
///
/// The banner shows: sender name · hop count · first 100 chars of text.
/// Two actions: VIEW (opens BroadcastScreen) and DISMISS.
/// Auto-dismisses after 8 seconds.
void _showBroadcastBanner(BroadcastMessage msg) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;

  // Replace any existing broadcast banner (don't stack them).
  messenger.clearMaterialBanners();

  final senderLabel =
      msg.senderName.isNotEmpty ? msg.senderName : 'Unknown peer';
  final preview =
      msg.text.length > 100 ? '${msg.text.substring(0, 100)}…' : msg.text;

  messenger.showMaterialBanner(
    MaterialBanner(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      dividerColor: AppColors.primary.withOpacity(0.2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.campaign, color: AppColors.primary, size: 20),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  'Broadcast · $senderLabel',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppColors.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (msg.hopCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${msg.hopCount} hop${msg.hopCount > 1 ? 's' : ''}',
                    style: const TextStyle(fontSize: 10, color: Colors.blue),
                  ),
                ),
              ],
              if (msg.hasLocation) ...[
                const SizedBox(width: 4),
                const Icon(Icons.location_on, size: 13, color: Colors.teal),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            preview,
            style: const TextStyle(fontSize: 14, height: 1.35),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            messenger.clearMaterialBanners();
            navigatorKey.currentState?.push(
              MaterialPageRoute(
                  builder: (_) => const BroadcastScreen()),
            );
          },
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          child: const Text('VIEW'),
        ),
        TextButton(
          onPressed: () => messenger.clearMaterialBanners(),
          style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary),
          child: const Text('DISMISS'),
        ),
      ],
    ),
  );

  // Auto-dismiss after 8 s so it doesn't obstruct the UI permanently.
  Future.delayed(const Duration(seconds: 8), () {
    messenger.clearMaterialBanners();
  });
}
