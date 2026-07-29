/// Encrypted local database using SQLCipher via sqflite platform channel.
/// Android: sqlcipher_flutter_libs replaces native SQLite with SQLCipher .so
library;

import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class DatabaseManager {
  static DatabaseManager? _instance;
  sqflite.Database? _db;
  String? _dbPassword;

  DatabaseManager._();
  static DatabaseManager get instance {
    _instance ??= DatabaseManager._();
    return _instance!;
  }

  void setEncryptionKey(String key) => _dbPassword = key;

  Future<sqflite.Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<sqflite.Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'myphone.db');
    final pw = _dbPassword;

    return await sqflite.openDatabase(
      path,
      version: 1,
      onConfigure: pw != null
          ? (db) async => db.execute("PRAGMA key = '$pw';")
          : null,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            id TEXT PRIMARY KEY, display_name TEXT NOT NULL,
            phone_hash TEXT NOT NULL, public_key_fingerprint TEXT,
            avatar_path TEXT, last_seen INTEGER,
            is_registered INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
        ''');
        await db.execute('''
          CREATE TABLE call_history (
            id TEXT PRIMARY KEY, contact_id TEXT NOT NULL,
            direction TEXT NOT NULL CHECK(direction IN ('outgoing','incoming','missed')),
            status TEXT NOT NULL CHECK(status IN ('answered','missed','rejected','busy')),
            duration_seconds INTEGER DEFAULT 0,
            call_type TEXT NOT NULL DEFAULT 'audio',
            codec_used TEXT, avg_bitrate_bps INTEGER,
            started_at INTEGER NOT NULL, ended_at INTEGER,
            FOREIGN KEY (contact_id) REFERENCES contacts(id))
        ''');
        await db.execute('''
          CREATE TABLE key_store (
            key_type TEXT PRIMARY KEY, key_data BLOB NOT NULL,
            created_at INTEGER NOT NULL)
        ''');
      },
    );
  }

  Future<void> upsertContact(Map<String, dynamic> contact) async {
    final db = await database;
    contact['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    contact['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    await db.insert('contacts', contact,
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getContacts() async {
    final db = await database;
    return db.query('contacts', orderBy: 'display_name ASC');
  }

  Future<Map<String, dynamic>?> getContact(String id) async {
    final db = await database;
    final results = await db.query('contacts', where: 'id = ?', whereArgs: [id]);
    return results.isNotEmpty ? results.first : null;
  }

  Future<void> insertCallHistory(Map<String, dynamic> call) async {
    final db = await database;
    await db.insert('call_history', call);
  }

  Future<List<Map<String, dynamic>>> getCallHistory({int limit = 50}) async {
    final db = await database;
    return db.query('call_history', orderBy: 'started_at DESC', limit: limit);
  }

  Future<void> storeKey(String keyType, List<int> keyData) async {
    final db = await database;
    await db.insert('key_store', {
      'key_type': keyType,
      'key_data': keyData,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  Future<List<int>?> getKey(String keyType) async {
    final db = await database;
    final results = await db.query('key_store', where: 'key_type = ?', whereArgs: [keyType]);
    if (results.isEmpty) return null;
    return results.first['key_data'] as List<int>;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
