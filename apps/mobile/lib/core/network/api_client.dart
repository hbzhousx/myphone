/// HTTP REST API client for communicating with the signaling server.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../../app/auth_guard.dart';
import 'server_config.dart';

class ApiClient {
  final String _baseUrl = ServerConfig.apiBase;
  final http.Client _client;

  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, String>> _authHeaders() async {
    final token = await AuthGuard.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // --- Auth ---

  Future<Map<String, dynamic>> login({
    required String phoneNumber,
    required String password,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: await _authHeaders(),
      body: jsonEncode({'phone_number': phoneNumber, 'password': password}),
    );
    return _handleResponse(response);
  }

  // --- Pre-Keys ---

  Future<void> uploadPreKeys(List<Map<String, dynamic>> preKeys) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/keys/prekeys'),
      headers: await _authHeaders(),
      body: jsonEncode({'pre_keys': preKeys}),
    );
    _handleResponse(response);
  }

  Future<Map<String, dynamic>> getPreKeys(String userId) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/keys/prekeys/$userId'),
      headers: await _authHeaders(),
    );
    return _handleResponse(response);
  }

  /// 上传签名预密钥（聊天/通话 X3DH 用）。
  Future<void> uploadSignedPreKey({
    required int keyId,
    required String publicKey,
    required String signature,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/keys/signed-prekey'),
      headers: await _authHeaders(),
      body: jsonEncode({
        'key_id': keyId,
        'public_key': publicKey,
        'signature': signature,
      }),
    );
    _handleResponse(response);
  }

  /// 同步本地 identity 公钥到服务器。
  /// ★关键：登录/重装后本地可能生成了新 identity，而服务器还是旧值 → 对端取
  ///   bundle 拿到旧 IK、本机用新 IK → X3DH DH2 不对称 → 解密 MAC 失败。
  ///   每次 publishPrekeyBundle 时调用，保证服务器 identity 与本地一致。
  Future<void> updateIdentity({required String identityPublicKey}) async {
    final response = await _client.put(
      Uri.parse('$_baseUrl/keys/identity'),
      headers: await _authHeaders(),
      body: jsonEncode({'identity_public_key': identityPublicKey}),
    );
    _handleResponse(response);
  }

  /// 取目标用户的完整 prekey 束（identity + signed-prekey + 一次性 prekey）。
  Future<Map<String, dynamic>> fetchKeyBundle(String userId) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/keys/bundle/$userId'),
      headers: await _authHeaders(),
    );
    return _handleResponse(response);
  }

  // --- Contact Discovery ---

  Future<List<Map<String, dynamic>>> discoverContacts(List<String> phoneHashes) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/contacts/discover'),
      headers: await _authHeaders(),
      body: jsonEncode({'phone_hashes': phoneHashes}),
    );
    final data = _handleResponse(response);
    return List<Map<String, dynamic>>.from(data['matches']);
  }

  // --- User Lookup ---

  Future<String?> lookupUserByPhoneHash(String phoneHash) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/users/by-phone/$phoneHash'),
      headers: await _authHeaders(),
    );
    if (response.statusCode == 404) return null;
    final data = _handleResponse(response);
    return data['user_id'] as String?;
  }

  /// Batch online/offline presence for a list of user IDs.
  /// Returns a map of userID → true (online) / false (offline).
  Future<Map<String, bool>> fetchPresence(List<String> userIds) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/users/presence'),
      headers: await _authHeaders(),
      body: jsonEncode({'user_ids': userIds}),
    );
    final data = _handleResponse(response);
    final presence = (data['presence'] as Map<String, dynamic>?) ?? {};
    return presence.map(
      (id, v) => MapEntry(id, v == 'online'),
    );
  }

  Future<Map<String, dynamic>?> lookupUserById(String userId) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/users/$userId'),
      headers: await _authHeaders(),
    );
    if (response.statusCode == 404) return null;
    return _handleResponse(response);
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw ApiException(
        statusCode: response.statusCode,
        message: body['error'] as String? ?? 'Unknown error',
      );
    }
    return body;
  }

  // --- OTA ---

  /// 查询服务器最新版本元数据(公开接口,无需鉴权)。
  Future<Map<String, dynamic>> checkForUpdate() async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/ota/check'),
      headers: await _authHeaders(),
    );
    return _handleResponse(response);
  }

  /// 下载 APK 到 [destPath],返回文件大小。流式写入,不整包载入内存。
  /// [onProgress] 可选:下载进度回调(received 已接收字节,total 总字节,未知为 -1)。
  Future<int> downloadApk(String destPath,
      {void Function(int received, int total)? onProgress}) async {
    final request = http.Request('GET', Uri.parse('$_baseUrl/ota/download'));
    final token = await AuthGuard.getToken();
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    final streamed = await _client.send(request);
    if (streamed.statusCode >= 400) {
      throw ApiException(
        statusCode: streamed.statusCode,
        message: 'OTA download failed: ${streamed.statusCode}',
      );
    }
    final total = streamed.contentLength ?? -1;
    final file = File(destPath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var received = 0;
    try {
      await streamed.stream.listen(
        (chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (onProgress != null) onProgress(received, total);
        },
        onError: (Object e) async {
          await sink.close();
          throw ApiException(statusCode: 0, message: 'download error: $e');
        },
      ).asFuture();
      await sink.close();
      if (onProgress != null) onProgress(received, total);
      return received;
    } catch (e) {
      await sink.close();
      rethrow;
    }
  }

  // --- 附件（服务器中转，密文）---

  /// 上传已加密的附件密文，返回 {attachment_id, url, size_bytes}。
  /// 服务器只存密文、不解密（Signal 附件 CDN 同理，E2EE 不破坏）。
  Future<Map<String, dynamic>> uploadAttachment(
    List<int> ciphertext,
    String fileName,
  ) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/attachments'),
    );
    request.headers.addAll(await _authHeaders());
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      ciphertext,
      filename: fileName,
    ));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    return _handleResponse(response);
  }

  /// 按 [url]（如 /v1/attachments/<id>）下载附件密文，返回字节。
  /// ★url 已含 /v1 前缀，故用 httpBase（不含 /v1）拼接，避免 /v1/v1 重复 404。
  Future<Uint8List> downloadAttachment(String url) async {
    final uri = url.startsWith('http')
        ? Uri.parse(url)
        : Uri.parse(ServerConfig.httpBase + (url.startsWith('/') ? url : '/$url'));
    final request = http.Request('GET', uri);
    request.headers.addAll(await _authHeaders());
    final streamed = await _client.send(request);
    if (streamed.statusCode >= 400) {
      throw ApiException(
        statusCode: streamed.statusCode,
        message: 'attachment download failed: ${streamed.statusCode}',
      );
    }
    final bytes = <int>[];
    await streamed.stream.listen(bytes.addAll).asFuture();
    return Uint8List.fromList(bytes);
  }

  /// 删除服务器上的附件密文（接收方下载完成并本地解密写盘后调用）。
  /// 服务器文件不存在时返回 200（幂等），404 不视为错误。
  Future<void> deleteAttachment(String url) async {
    final uri = url.startsWith('http')
        ? Uri.parse(url)
        : Uri.parse(ServerConfig.httpBase + (url.startsWith('/') ? url : '/$url'));
    final request = http.Request('DELETE', uri);
    request.headers.addAll(await _authHeaders());
    final streamed = await _client.send(request);
    if (streamed.statusCode >= 400 && streamed.statusCode != 404) {
      throw ApiException(
        statusCode: streamed.statusCode,
        message: 'attachment delete failed: ${streamed.statusCode}',
      );
    }
    await streamed.stream.drain();
  }

  void dispose() => _client.close();
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException({required this.statusCode, required this.message});

  @override
  String toString() => 'ApiException($statusCode): $message';
}
