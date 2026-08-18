/// Contact management — local storage, phone hash discovery, sync.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/database.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/network/api_client.dart';
import '../../shared/models/contact.dart';

class ContactManager {
  final ApiClient _api;
  ContactManager(this._api);

  // Must match server auth.hashPhone: SHA256("myphone-salt:" + phoneNumber)
  static const _phoneSalt = 'myphone-salt:';

  Future<List<Contact>> discoverFromPhoneBook({
    required List<String> phoneNumbers,
  }) async {
    final hashes = phoneNumbers
        .map((phoneNumber) => CryptoManager.sha256Hash(phoneNumber, salt: _phoneSalt))
        .toList();
    final matches = await _api.discoverContacts(hashes);
    final contacts = matches.map((m) => Contact.fromJson(m)).toList();
    for (final contact in contacts) {
      await DatabaseManager.instance.upsertContact(contact.toJson());
    }
    return contacts;
  }

  Future<List<Contact>> getLocalContacts() async {
    final rows = await DatabaseManager.instance.getContacts();
    return rows.map((r) => Contact.fromJson(r)).toList();
  }

  Future<Contact?> getContact(String id) async {
    final row = await DatabaseManager.instance.getContact(id);
    if (row == null) return null;
    return Contact.fromJson(row);
  }

  Future<void> addContact({
    required String displayName,
    required String phoneNumber,
    String? publicKeyFingerprint,
    String? avatarPath,
  }) async {
    final phoneHash = CryptoManager.sha256Hash(phoneNumber, salt: _phoneSalt);
    // Try to resolve the user UUID from the server.
    String contactId = phoneHash;
    bool isRegistered = false;
    try {
      final userId = await _api.lookupUserByPhoneHash(phoneHash);
      if (userId != null) {
        contactId = userId;
        isRegistered = true;
      }
    } catch (_) {
      // Offline or server unreachable — fall back to phone_hash as id.
    }
    await DatabaseManager.instance.upsertContact({
      'id': contactId,
      'display_name': displayName,
      'phone_hash': phoneHash,
      'public_key_fingerprint': publicKeyFingerprint,
      if (avatarPath != null) 'avatar_path': avatarPath,
      'is_registered': isRegistered ? 1 : 0,
    });
  }

  static final _uuidRe = RegExp(r'^[0-9a-f]{32}$');

  /// Fetch online/offline presence for registered contacts.
  /// Only contacts whose id is a server UUID can be online; phone-hash ids
  /// are local-only and skipped.
  Future<Map<String, bool>> refreshPresence(List<Contact> contacts) async {
    final userIds = contacts
        .where((c) => c.isRegistered && _uuidRe.hasMatch(c.id))
        .map((c) => c.id)
        .toList();
    if (userIds.isEmpty) return {};
    return _api.fetchPresence(userIds).timeout(const Duration(seconds: 5));
  }
}

/// In-memory online/offline presence for contacts, keyed by contact user ID.
/// Presence is transient (WebSocket-derived) and deliberately not persisted.
class ContactPresenceNotifier extends StateNotifier<Map<String, bool>> {
  ContactPresenceNotifier() : super(const {});

  Future<void> refresh() async {
    try {
      final rows = await DatabaseManager.instance.getContacts();
      final contacts = rows.map((r) => Contact.fromJson(r)).toList();
      final manager = ContactManager(ApiClient());
      final presence = await manager.refreshPresence(contacts);
      state = {...state, ...presence};
    } catch (_) {
      // Keep the last known presence on failure (offline / slow server).
    }
  }
}

final contactPresenceProvider =
    StateNotifierProvider<ContactPresenceNotifier, Map<String, bool>>(
        (ref) => ContactPresenceNotifier());
