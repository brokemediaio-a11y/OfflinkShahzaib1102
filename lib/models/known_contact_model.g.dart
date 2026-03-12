// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'known_contact_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class KnownContactAdapter extends TypeAdapter<KnownContact> {
  @override
  final int typeId = 3;

  @override
  KnownContact read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return KnownContact(
      peerId: fields[0] as String,
      displayName: fields[1] as String,
      deviceAddress: fields[2] as String?,
      lastSeen: fields[3] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, KnownContact obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.peerId)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.deviceAddress)
      ..writeByte(3)
      ..write(obj.lastSeen);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KnownContactAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
