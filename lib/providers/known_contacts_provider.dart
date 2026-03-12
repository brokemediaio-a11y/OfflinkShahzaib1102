import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/known_contact_model.dart';
import '../services/storage/known_contacts_storage.dart';

/// Exposes the list of all previously discovered peers to the UI.
///
/// This is a simple synchronous read from [KnownContactsStorage] because Hive
/// boxes are loaded eagerly at startup.  Rebuild is triggered manually via
/// `ref.invalidate(knownContactsProvider)` when a new contact is saved.
final knownContactsProvider = Provider<List<KnownContact>>((ref) {
  return KnownContactsStorage.getAllContacts()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen)); // newest first
});
