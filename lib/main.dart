import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/app_colors.dart';
import 'screens/splash/splash_screen.dart';
import 'models/message_model.dart';
import 'services/storage/message_storage.dart';
import 'services/storage/device_storage.dart';
import 'models/conversation_model.dart';
import 'utils/logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive
  await Hive.initFlutter();
  
  // Register Hive adapters
  // Note: Run 'flutter pub run build_runner build' to generate adapters
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(MessageModelAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(MessageStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(2)) {
    Hive.registerAdapter(ConversationModelAdapter());
  }
  
  // Initialize storage
  await MessageStorage.init();
  await DeviceStorage.init();
  
  // MIGRATION: Clear message storage for multi-hop architecture update
  // This is acceptable for FYP demo purposes
  // The new MessageModel has additional routing fields that are incompatible with old messages
  try {
    final messageBox = await Hive.openBox<MessageModel>('messages');
    if (messageBox.isNotEmpty) {
      Logger.info('MIGRATION: Clearing ${messageBox.length} old messages for multi-hop update');
      await messageBox.clear();
      Logger.info('MIGRATION: Message storage cleared successfully');
    }
    
    // Also clear conversations since they reference old messages
    final conversationBox = await Hive.openBox<ConversationModel>('conversations');
    if (conversationBox.isNotEmpty) {
      Logger.info('MIGRATION: Clearing ${conversationBox.length} old conversations');
      await conversationBox.clear();
      Logger.info('MIGRATION: Conversations cleared successfully');
    }
  } catch (e) {
    Logger.error('MIGRATION: Error clearing storage', e);
    // Continue anyway - app will work with empty storage
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

