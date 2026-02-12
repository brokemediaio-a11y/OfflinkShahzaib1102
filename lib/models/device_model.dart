class DeviceModel {
  final String id; // Device UUID (primary identifier)
  final String name;
  final String? address; // MAC address (optional, only for BLE connection purposes)
  final DeviceType type;
  final int rssi;
  final bool isConnected;
  final DateTime? lastSeen;

  DeviceModel({
    required this.id,
    required this.name,
    this.address, // Optional - only needed for BLE connections
    required this.type,
    this.rssi = 0,
    this.isConnected = false,
    this.lastSeen,
  });

  DeviceModel copyWith({
    String? id,
    String? name,
    String? address,
    DeviceType? type,
    int? rssi,
    bool? isConnected,
    DateTime? lastSeen,
  }) {
    return DeviceModel(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      type: type ?? this.type,
      rssi: rssi ?? this.rssi,
      isConnected: isConnected ?? this.isConnected,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'address': address, // May be null
      'type': type.name,
      'rssi': rssi,
      'isConnected': isConnected,
      'lastSeen': lastSeen?.toIso8601String(),
    };
  }

  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    return DeviceModel(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String?, // Optional
      type: DeviceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => DeviceType.ble,
      ),
      rssi: json['rssi'] as int? ?? 0,
      isConnected: json['isConnected'] as bool? ?? false,
      lastSeen: json['lastSeen'] != null
          ? DateTime.parse(json['lastSeen'] as String)
          : null,
    );
  }

  @override
  String toString() {
    return 'DeviceModel(id: $id, name: $name, address: $address, type: $type, rssi: $rssi, isConnected: $isConnected)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceModel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

enum DeviceType {
  ble,
  classicBluetooth,
  wifiDirect,
}




