import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'api_client.dart' show remoteApiBaseUrl;

/// Owns the device's identity with the backend: anonymous registration,
/// access-token refresh, and linking the device to a user via Google/Apple
/// Sign-In. Deliberately uses its own bare [Dio] (no interceptor) — [ApiClient]
/// depends on this class to attach tokens, so routing auth's own calls
/// through that same interceptor would recurse.
class DeviceAuth {
  DeviceAuth({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        _dio = Dio(BaseOptions(baseUrl: remoteApiBaseUrl));

  final FlutterSecureStorage _storage;
  final Dio _dio;

  static const _kDeviceId = 'remote.deviceId';
  static const _kRefreshToken = 'remote.refreshToken';

  String? _accessToken;
  DateTime? _accessTokenExpiresAt;

  /// True once the current access token carries a `user_id` claim (i.e. this
  /// device has been linked to a user via [signInWithGoogle]/[signInWithApple]).
  /// Only meaningful after at least one [ensureAccessToken] call.
  bool get isLoggedIn =>
      _accessToken != null && _decodeUserId(_accessToken!) != null;

  Future<String> ensureAccessToken({bool forceRefresh = false}) async {
    if (!forceRefresh && _accessToken != null && _accessTokenExpiresAt != null) {
      final buffer = const Duration(seconds: 30);
      if (DateTime.now().isBefore(_accessTokenExpiresAt!.subtract(buffer))) {
        return _accessToken!;
      }
    }

    final ids = await _ensureDeviceRegistered();
    final response = await _dio.post(
      '/v1/auth/token',
      data: {'device_id': ids.deviceId, 'refresh_token': ids.refreshToken},
    );
    _cacheAccessToken(response.data as Map<String, dynamic>);
    return _accessToken!;
  }

  Future<void> signInWithGoogle() async {
    final googleSignIn = GoogleSignIn();
    final account = await googleSignIn.signIn();
    if (account == null) return; // user cancelled
    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null) {
      throw StateError('Google sign-in did not return an id_token');
    }
    await _socialLogin(provider: 'google', idToken: idToken);
  }

  Future<void> signInWithApple() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email],
    );
    final idToken = credential.identityToken;
    if (idToken == null) {
      throw StateError('Sign in with Apple did not return an identityToken');
    }
    await _socialLogin(provider: 'apple', idToken: idToken);
  }

  Future<void> _socialLogin({required String provider, required String idToken}) async {
    final accessToken = await ensureAccessToken();
    final response = await _dio.post(
      '/v1/auth/social-login',
      data: {'provider': provider, 'id_token': idToken},
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    _cacheAccessToken(response.data as Map<String, dynamic>);
  }

  void _cacheAccessToken(Map<String, dynamic> body) {
    _accessToken = body['access_token'] as String;
    final expiresIn = body['expires_in'] as int;
    _accessTokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
  }

  Future<_DeviceIds> _ensureDeviceRegistered() async {
    final existingId = await _storage.read(key: _kDeviceId);
    final existingRefresh = await _storage.read(key: _kRefreshToken);
    if (existingId != null && existingRefresh != null) {
      return _DeviceIds(existingId, existingRefresh);
    }

    final response = await _dio.post('/v1/auth/register-device', data: {});
    final body = response.data as Map<String, dynamic>;
    final deviceId = body['device_id'] as String;
    final refreshToken = body['refresh_token'] as String;
    await _storage.write(key: _kDeviceId, value: deviceId);
    await _storage.write(key: _kRefreshToken, value: refreshToken);
    return _DeviceIds(deviceId, refreshToken);
  }

  /// Reads the `user_id` claim out of an access JWT's payload without
  /// verifying its signature — this is only ever used to decide local UI
  /// state ("show login vs. show account"), never as a security check; the
  /// server independently verifies the token on every request.
  String? _decodeUserId(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)))
          as Map<String, dynamic>;
      return payload['user_id'] as String?;
    } on Object {
      return null;
    }
  }
}

class _DeviceIds {
  _DeviceIds(this.deviceId, this.refreshToken);
  final String deviceId;
  final String refreshToken;
}
