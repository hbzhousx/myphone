/// HTTP REST API client for communicating with the signaling server.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../app/auth_guard.dart';

class ApiClient {
  static const _baseUrl = 'https://api.myphone.example.com/v1';
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

  Future<Map<String, dynamic>> register({
    required String phoneNumber,
    required String identityPublicKey,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: await _authHeaders(),
      body: jsonEncode({
        'phone_number': phoneNumber,
        'identity_public_key': identityPublicKey,
      }),
    );
    return _handleResponse(response);
  }

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

  void dispose() => _client.close();
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException({required this.statusCode, required this.message});

  @override
  String toString() => 'ApiException($statusCode): $message';
}
