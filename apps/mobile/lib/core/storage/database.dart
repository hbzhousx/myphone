/// Encrypted local database using SQLCipher.
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'key_manager.dart';

class DatabaseManager {
  static const _databaseName = 'myphone.db';
  static const _schemaVersion = 4;
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
    await _createChatSchema(db);
  }

  /// 聊天相关的 4 张表（schema v4）。
  Future<void> _createChatSchema(sqlcipher.Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        remote_user_id TEXT NOT NULL,
        remote_display_name TEXT,
        disappearing_seconds INTEGER DEFAULT 0,
        last_message_at INTEGER,
        last_message_preview TEXT,
        unread_count INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id),
        direction TEXT NOT NULL CHECK(direction IN ('outgoing','incoming')),
        kind TEXT NOT NULL CHECK(kind IN ('text','emoji','image','video','file')),
        body TEXT,
        ciphertext BLOB,
        status TEXT CHECK(status IN ('sending','pending','sent','delivered','read','failed')),
        expires_in_seconds INTEGER DEFAULT 0,
        expires_at INTEGER,
        read_at INTEGER,
        sent_at INTEGER, received_at INTEGER,
        transfer_id TEXT,
        created_at INTEGER NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_attachments (
        id TEXT PRIMARY KEY,
        message_id TEXT REFERENCES messages(id),
        conversation_id TEXT,
        kind TEXT CHECK(kind IN ('image','video','file')),
        file_name TEXT, mime_type TEXT, size_bytes INTEGER,
        plaintext_sha256 TEXT,
        local_enc_path TEXT, local_plain_path TEXT,
        aes_key BLOB,
        status TEXT CHECK(status IN ('pending','transferring','done','failed')),
        created_at INTEGER NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_sessions (
        conversation_id TEXT PRIMARY KEY,
        session_json TEXT NOT NULL,
        remote_identity_pub TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, created_at)');
  }

  Future<void> _migrateSchema(sqlcipher.Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE call_history ADD COLUMN contact_name TEXT');
    }
    if (oldVersion < 4) {
      await _createChatSchema(db);
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
        await _copyTableIfPresent(legacyDb, encryptedDb, 'conversations');
        await _copyTableIfPresent(legacyDb, encryptedDb, 'messages');
        await _copyTableIfPresent(legacyDb, encryptedDb, 'message_attachments');
        await _copyTableIfPresent(legacyDb, encryptedDb, 'chat_sessions');
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

  /// 删除单条通话记录。
  Future<void> deleteCallHistory(String id) async {
    final db = await database;
    await db.delete('call_history', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空全部通话记录。
  Future<void> clearCallHistory() async {
    final db = await database;
    await db.delete('call_history');
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

  // ---- 聊天 DAO（schema v4） ----

  Future<void> upsertConversation(Map<String, dynamic> conv) async {
    final db = await database;
    conv['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    conv['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    await db.insert('conversations', conv,
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getConversations() async {
    final db = await database;
    return db.query('conversations', orderBy: 'last_message_at DESC');
  }

  Future<Map<String, dynamic>?> getConversation(String id) async {
    final db = await database;
    final rows = await db.query('conversations', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  /// 按对端用户 ID 找会话（存在则返回，否则 null）。
  Future<Map<String, dynamic>?> getConversationByRemote(String remoteUserId) async {
    final db = await database;
    final rows = await db.query('conversations',
        where: 'remote_user_id = ?', whereArgs: [remoteUserId]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<void> insertMessage(Map<String, dynamic> message) async {
    final db = await database;
    message['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    await db.insert('messages', message,
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace);
  }

  /// 取某会话的消息，返回**最新的 [limit] 条**（按时间正序，UI 直接渲染）。
  ///
  /// ★不能直接 `ORDER BY created_at ASC LIMIT n`——那会取到最旧的 n 条，
  ///   chat_screen 每次轮询 getMessages 时刚发送的新消息（created_at 最新）就
  ///   不在结果里 →「聊天页看不到自己发的消息，但会话列表能看到」。
  ///   先倒序取最新 n 条再反转为正序，与 Signal 的 SNIPPET_QUERY 按
  ///   DATE_RECEIVED DESC 取最新一行同理。
  Future<List<Map<String, dynamic>>> getMessages(String conversationId,
      {int limit = 100}) async {
    final db = await database;
    final rows = await db.query('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId],
        orderBy: 'created_at DESC', limit: limit);
    return rows.reversed.toList();
  }

  Future<Map<String, dynamic>?> getMessage(String id) async {
    final db = await database;
    final rows = await db.query('messages', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<void> updateMessageStatus(String id, String status,
      {int? deliveredAt, int? readAt}) async {
    final db = await database;
    final fields = <String, Object?>{'status': status};
    if (deliveredAt != null) fields['received_at'] = deliveredAt;
    if (readAt != null) fields['read_at'] = readAt;
    if (readAt != null && fields['status'] == 'read') {
      final msg = await getMessage(id);
      final expires = msg?['expires_in_seconds'] as int? ?? 0;
      if (expires > 0) fields['expires_at'] = readAt + expires * 1000;
    }
    await db.update('messages', fields,
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> insertAttachment(Map<String, dynamic> attachment) async {
    final db = await database;
    attachment['created_at'] ??= DateTime.now().millisecondsSinceEpoch;
    await db.insert('message_attachments', attachment,
        conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getAttachment(String id) async {
    final db = await database;
    final rows = await db.query('message_attachments',
        where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<void> updateAttachmentStatus(String id, String status) async {
    final db = await database;
    await db.update('message_attachments', {'status': status},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> saveChatSession(String conversationId, String sessionJson,
      {String? remoteIdentityPub}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('chat_sessions', {
      'conversation_id': conversationId,
      'session_json': sessionJson,
      'remote_identity_pub': remoteIdentityPub,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: sqlcipher.ConflictAlgorithm.replace);
  }

  Future<String?> getChatSessionJson(String conversationId) async {
    final db = await database;
    final rows = await db.query('chat_sessions',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    return rows.isNotEmpty ? rows.first['session_json'] as String? : null;
  }

  /// 删除已过期的阅后即焚消息（前台恢复 + 周期定时调用）。
  Future<int> deleteExpiredMessages() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query('messages',
        where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    // 诊断：上报被删的消息（id + expires_at + expires_in_seconds），定位"消息消失"。
    if (rows.isNotEmpty) {
      debugPrint('[DB] deleteExpiredMessages removing ${rows.length}: '
          '${rows.map((r) => '${r['id']}(exp=${r['expires_at']},ein=${r['expires_in_seconds']})').join(',')}');
    }
    for (final row in rows) {
      final id = row['id'] as String;
      await db.delete('messages', where: 'id = ?', whereArgs: [id]);
      final transferId = row['transfer_id'] as String?;
      if (transferId != null) {
        await db.delete('message_attachments',
            where: 'id = ?', whereArgs: [transferId]);
      }
    }
    return rows.length;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _dbFuture = null;
  }
}
