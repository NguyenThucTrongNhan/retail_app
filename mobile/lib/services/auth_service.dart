import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class AuthService {
  static final AuthService instance = AuthService._();
  AuthService._();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyAccessToken  = 'auth_access_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyExpiryMs    = 'auth_expiry_ms';
  static const _keyStoreCode   = 'auth_store_code';

  String? _accessToken;
  String? _refreshToken;
  String? _storeCode;
  int _expiryMs = 0;

  /// Call once in main() before runApp to rehydrate tokens from secure storage.
  Future<void> init() async {
    _accessToken  = await _storage.read(key: _keyAccessToken);
    _refreshToken = await _storage.read(key: _keyRefreshToken);
    _storeCode    = await _storage.read(key: _keyStoreCode);
    final exp     = await _storage.read(key: _keyExpiryMs);
    _expiryMs     = int.tryParse(exp ?? '0') ?? 0;
  }

  bool get isAuthenticated =>
      _accessToken != null && DateTime.now().millisecondsSinceEpoch < _expiryMs;

  String? get storeCode => _storeCode;

  /// Login with store code + credentials. Returns true on success.
  Future<bool> login(
    String authBaseUrl,
    String storeCode,
    String username,
    String password,
  ) async {
    try {
      final res = await http
          .post(
            Uri.parse('$authBaseUrl/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'store_code': storeCode.trim(),
              'username': username.trim(),
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        _storeCode = storeCode.trim();
        await _storeTokens(
          accessToken:  body['access_token'] as String,
          refreshToken: body['refresh_token'] as String,
          expiresIn:    body['expires_in'] as int,
        );
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Returns a valid access token. Auto-refreshes if expired.
  /// Returns null if refresh also fails — caller should redirect to login.
  Future<String?> getValidAccessToken(String authBaseUrl) async {
    if (isAuthenticated) return _accessToken;
    if (_refreshToken == null || _storeCode == null) return null;

    try {
      final res = await http
          .post(
            Uri.parse('$authBaseUrl/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'store_code': _storeCode,
              'refresh_token': _refreshToken,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        await _storeTokens(
          accessToken:  body['access_token'] as String,
          refreshToken: body['refresh_token'] as String,
          expiresIn:    body['expires_in'] as int,
        );
        return _accessToken;
      }
      await clearTokens();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Revoke tokens at Keycloak (best-effort) and clear local storage.
  Future<void> logout(String authBaseUrl) async {
    if (_refreshToken != null && _storeCode != null) {
      try {
        await http
            .post(
              Uri.parse('$authBaseUrl/auth/logout'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'store_code': _storeCode,
                'refresh_token': _refreshToken,
              }),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // best-effort — always clear locally
      }
    }
    await clearTokens();
  }

  Future<void> clearTokens() async {
    _accessToken = _refreshToken = _storeCode = null;
    _expiryMs = 0;
    await _storage.deleteAll();
  }

  Future<void> _storeTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresIn,
  }) async {
    _accessToken  = accessToken;
    _refreshToken = refreshToken;
    // Subtract 30-second safety buffer before the actual expiry
    _expiryMs = DateTime.now().millisecondsSinceEpoch + (expiresIn - 30) * 1000;
    await Future.wait([
      _storage.write(key: _keyAccessToken,  value: accessToken),
      _storage.write(key: _keyRefreshToken, value: refreshToken),
      _storage.write(key: _keyStoreCode,    value: _storeCode ?? ''),
      _storage.write(key: _keyExpiryMs,     value: _expiryMs.toString()),
    ]);
  }
}
