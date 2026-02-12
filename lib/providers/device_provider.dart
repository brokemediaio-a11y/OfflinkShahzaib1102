import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../models/device_model.dart';
import '../services/communication/connection_manager.dart';
import '../utils/logger.dart';

class DeviceState {
  final List<DeviceModel> discoveredDevices;
  final bool isScanning;
  final DeviceModel? selectedDevice;
  final String? error;

  DeviceState({
    this.discoveredDevices = const [],
    this.isScanning = false,
    this.selectedDevice,
    this.error,
  });

  DeviceState copyWith({
    List<DeviceModel>? discoveredDevices,
    bool? isScanning,
    DeviceModel? selectedDevice,
    String? error,
  }) {
    return DeviceState(
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      isScanning: isScanning ?? this.isScanning,
      selectedDevice: selectedDevice ?? this.selectedDevice,
      error: error ?? this.error,
    );
  }
}

class DeviceNotifier extends StateNotifier<DeviceState> {
  final ConnectionManager _connectionManager;
  StreamSubscription<List<DeviceModel>>? _deviceSubscription;
  Timer? _scanTimer;

  DeviceNotifier(this._connectionManager) : super(DeviceState()) {
    _setupListeners();
  }

  void _setupListeners() {
    _deviceSubscription =
        _connectionManager.getDiscoveredDevices().listen((devices) {
      state = state.copyWith(discoveredDevices: devices);
    });
  }

  Future<void> startScan() async {
    try {
      _scanTimer?.cancel();
      state = state.copyWith(
        discoveredDevices: [],
        isScanning: true,
        error: null,
      );
      await _connectionManager.startScan();
      _scanTimer = Timer(AppConstants.bleScanTimeout, () async {
        await _connectionManager.stopScan();
        if (mounted) {
          state = state.copyWith(isScanning: false);
        }
      });
      Logger.info('Device scan started');
    } catch (e) {
      _scanTimer?.cancel();
      // Extract user-friendly error message
      String errorMessage = e.toString();
      if (errorMessage.contains('Exception: ')) {
        errorMessage = errorMessage.replaceFirst('Exception: ', '');
      }
      
      state = state.copyWith(
        isScanning: false,
        error: errorMessage,
      );
      Logger.error('Error starting scan', e);
    }
  }

  Future<void> stopScan() async {
    try {
      _scanTimer?.cancel();
      await _connectionManager.stopScan();
      state = state.copyWith(isScanning: false);
      Logger.info('Device scan stopped');
    } catch (e) {
      state = state.copyWith(
        isScanning: false,
        error: 'Failed to stop scan: ${e.toString()}',
      );
      Logger.error('Error stopping scan', e);
    }
  }

  void selectDevice(DeviceModel device) {
    state = state.copyWith(selectedDevice: device);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _deviceSubscription?.cancel();
    super.dispose();
  }
}

// Provider for ConnectionManager instance
final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final manager = ConnectionManager();
  ref.onDispose(() => manager.dispose());
  return manager;
});

// Provider for DeviceNotifier
final deviceProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  final connectionManager = ref.watch(connectionManagerProvider);
  return DeviceNotifier(connectionManager);
});

