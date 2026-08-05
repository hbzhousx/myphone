/// Contact management — local storage, phone hash discovery, sync.
library;

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
      'is_registered': isRegistered ? 1 : 0,
    });
  }

  Future<void> deleteContact(String id) async {
    final db = await DatabaseManager.instance.database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }
}
