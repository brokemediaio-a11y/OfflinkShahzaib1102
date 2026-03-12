import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/app_colors.dart';
import 'screens/splash/splash_screen.dart';
import 'models/message_model.dart';
import 'models/conversation_model.dart';
import 'models/known_contact_model.dart';
import 'services/storage/message_storage.dart';
import 'services/storage/device_storage.dart';
import 'services/storage/known_contacts_storage.dart';
import 'services/storage/pending_message_storage.dart';
import 'utils/logger.dart';

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
  await KnownContactsStorage.init();
  await PendingMessageStorage.init();

  // ── MIGRATION: clear old messages incompatible with new schema ────
  // The MessageModel gained routing fields (messageId, hopCount, etc.)
  // Old Hive boxes may contain objects with missing fields → clear once.
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
  } catch (e) {
    Logger.error('MIGRATION: Error clearing storage', e);
    // Continue anyway — app will work with empty storage
  }

  runApp(
    const ProviderScope(
      child: OfflinkApp(),
    ),
  );
}

class OfflinkApp extends StatelessWidget {
  const OfflinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
