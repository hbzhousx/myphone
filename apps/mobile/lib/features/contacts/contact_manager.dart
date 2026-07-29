/// Contact management — local storage, phone hash discovery, sync.
library;

import '../../core/storage/database.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/network/api_client.dart';
import '../../shared/models/contact.dart';

class ContactManager {
  final ApiClient _api;
  ContactManager(this._api);

  Future<List<Contact>> discoverFromPhoneBook({
    required List<String> phoneNumbers,
    String salt = '',
  }) async {
    final hashes = phoneNumbers
        .map((num) => CryptoManager.sha256Hash(num, salt: salt))
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
    String salt = '',
  }) async {
    final phoneHash = CryptoManager.sha256Hash(phoneNumber, salt: salt);
    await DatabaseManager.instance.upsertContact({
      'id': phoneHash,
      'display_name': displayName,
      'phone_hash': phoneHash,
      'public_key_fingerprint': publicKeyFingerprint,
      'is_registered': 0,
    });
  }

  Future<void> deleteContact(String id) async {
    final db = await DatabaseManager.instance.database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }
}
