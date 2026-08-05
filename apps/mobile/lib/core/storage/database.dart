/// Encrypted local database using SQLCipher.
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'key_manager.dart';

class DatabaseManager {
  static const _databaseName = 'myphone.db';
  static const _schemaVersion = 3;
  static const _plaintextBackupSuffix = '.plaintext-migration';
  static DatabaseManager? _instance;
  sqlcipher.Database? _db;
  Future<sqlcipher.Database>? _dbFuture;
  DatabaseManager._();
  static DatabaseManager get instance {
    _instance ??= DatabaseManager._();
    return _instance!;
  }

  Future<sqlcipher.Database> get database {
    // Serialize concurrent opens — a single shared future ensures the
    // database is opened exactly once even when callers race (e.g. call
    // accept + contact-name lookup both hitting `database` at once).
    return _dbFuture ??= _initDb().then((db) {
      _db = db;
      return db;
    });
  }

  Future<sqlcipher.Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _databaseName);
    final password = await KeyManager.getOrCreateDbKey();

    // Delete stale WAL/journal files that can cause SQLITE_READONLY_DBMOVED.
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      try { if (await f.exists()) await f.delete(); } catch (_) {}
    }

    await _migratePlaintextDatabaseIfNeeded(path, password);

    return _openEncryptedDatabase(
      path,
      password,
    );
  }

  Future<sqlcipher.Database> _openEncryptedDatabase(
    String path,
    String password,
  ) {
    return sqlcipher.openDatabase(
      path,
      password: password,
      version: _schemaVersion,
      // NOTE: onConfigure is deliberately absent (see comment above).
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _migrateSchema(db, oldVersion, newVersion);
      },
    );
  }

  Future<void> _createSchema(sqlcipher.Database db) async {
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
        contact_name TEXT,
        contact_phone TEXT,
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
  }

  Future<void> _migrateSchema(sqlcipher.Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE call_history ADD COLUMN contact_name TEXT');
    }
  }

  Future<void> _migratePlaintextDatabaseIfNeeded(
    String path,
    String password,
  ) async {
    final dbFile = File(path);
    if (!await dbFile.exists()) {
      return;
    }

    if (await dbFile.length() == 0) {
      await dbFile.delete();
      return;
    }

    if (!await _looksLikePlaintextSqlite(dbFile)) {
      return;
    }

    final legacyPath = '$path$_plaintextBackupSuffix';
    await _deleteMigrationFiles(legacyPath);
    await dbFile.rename(legacyPath);

    final legacyDb = await sqflite.openDatabase(
      legacyPath,
      readOnly: true,
      singleInstance: false,
    );

    try {
      final encryptedDb = await _openEncryptedDatabase(path, password);
      try {
        await _copyTableIfPresent(legacyDb, encryptedDb, 'contacts');
        await _copyTableIfPresent(legacyDb, encryptedDb, 'call_history');
        await _copyTableIfPresent(legacyDb, encryptedDb, 'key_store');
      } finally {
        await encryptedDb.close();
      }
    } catch (_) {
      await _deleteMigrationFiles(path);
      await File(legacyPath).rename(path);
      rethrow;
    } finally {
      await legacyDb.close();
    }

    await _deleteMigrationFiles(legacyPath);
  }

  Future<bool> _looksLikePlaintextSqlite(File file) async {
    final header = await file.openRead(0, 16).fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    if (header.length < 16) {
      return false;
    }
    return String.fromCharCodes(header) == 'SQLite format 3\x00';
  }

  Future<void> _copyTableIfPresent(
    sqflite.Database source,
    sqlcipher.Database target,
    String table,
  ) async {
    final exists = await source.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    if (exists.isEmpty) {
      return;
    }

    final rows = await source.query(table);
    if (rows.isEmpty) {
      return;
    }

    final batch = target.batch();
    for (final row in rows) {
      batch.insert(
        table,
        Map<String, Object?>.from(row),
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> _deleteMigrationFiles(String basePath) async {
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      final file = File('$basePath$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> upsertContact(Map<String, dynamic> contact) async {
    final db = await database;
    contact['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    contact['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    await db.insert('contacts', contact,
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getContacts() async {
    final db = await database;
    return db.query('contacts', orderBy: 'display_name ASC');
  }

  Future<Map<String, dynamic>?> getContact(String id) async {
    final db = await database;
    final results =
        await db.query('contacts', where: 'id = ?', whereArgs: [id]);
    return results.isNotEmpty ? results.first : null;
  }

  Future<void> updateContactFingerprint(
    String contactId,
    String fingerprint,
  ) async {
    final db = await database;
    await db.update(
      'contacts',
      {
        'public_key_fingerprint': fingerprint,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [contactId],
    );
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
    await db.insert(
        'key_store',
        {
          'key_type': keyType,
          'key_data': keyData,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace);
  }

  Future<List<int>?> getKey(String keyType) async {
    final db = await database;
    final results = await db
        .query('key_store', where: 'key_type = ?', whereArgs: [keyType]);
    if (results.isEmpty) return null;
    return results.first['key_data'] as List<int>;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _dbFuture = null;
  }
}
