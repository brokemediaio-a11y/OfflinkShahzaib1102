import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'core/app_colors.dart';
import 'screens/splash/splash_screen.dart';
import 'models/message_model.dart';
import 'services/storage/message_storage.dart';
import 'services/storage/device_storage.dart';
import 'models/conversation_model.dart';
import 'providers/conversations_provider.dart';
import 'providers/connection_provider.dart';
import 'screens/messages/messages_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'models/device_model.dart';
import 'core/app_strings.dart';
import 'core/constants.dart';
import 'utils/logger.dart';
import 'dart:async';
import 'dart:convert';

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

