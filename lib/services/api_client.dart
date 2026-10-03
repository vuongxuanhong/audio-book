import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import 'device_auth.dart';

/// Where `audiobook-backend` runs. Defaults to the Railway deployment;
/// override for local dev with
/// `--dart-define=API_BASE_URL=http://localhost:8000`.
const String remoteApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://audiobook-backend-production-6632.up.railway.app',
);

/// A [Dio] instance wired to attach the device/user bearer token to every
/// request and to retry once, after a token refresh, on a 401.
class ApiClient {
  ApiClient(this._auth) {
    _dio = Dio(BaseOptions(baseUrl: remoteApiBaseUrl));

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _auth.ensureAccessToken();
          options.headers['Authorization'] = 'Bearer $token';
          handler.next(options);
        },
        onError: (error, handler) async {
          final response = error.response;
          // A 401 with {"error": "login_required"} means the device isn't
          // signed in, not that the token expired — a fresh token can't fix
          // it, so it isn't retried.
          if (response?.statusCode == 401 &&
              !_isLoginRequired(response) &&
              !_isRetry(error.requestOptions)) {
            final token = await _auth.ensureAccessToken(forceRefresh: true);
            final retryOptions = error.requestOptions;
            retryOptions.headers['Authorization'] = 'Bearer $token';
            retryOptions.extra['retried'] = true;
            try {
              final retryResponse = await _dio.fetch(retryOptions);
              handler.resolve(retryResponse);
              return;
            } on DioException catch (retryError) {
              handler.next(retryError);
              return;
            }
          }
          handler.next(error);
        },
      ),
    );

    // Debug-only request/response logging, including headers (so the bearer
    // token shows up too) and response bodies — added after the auth
    // interceptor so it sees the Authorization header once that's attached.
    // Debug builds only.
    if (kDebugMode) {
      _dio.interceptors.add(LogInterceptor(
        requestHeader: true,
        responseHeader: true,
        responseBody: true,
        logPrint: (obj) => debugPrint('[api] $obj'),
      ));
    }
  }

  final DeviceAuth _auth;
  late final Dio _dio;

  Dio get dio => _dio;

  /// Whether a user (not just this device) is signed in, as of the last
  /// token — see [checkLoggedIn] before any request has been made.
  bool get isLoggedIn => _auth.isLoggedIn;

  /// Like [isLoggedIn], after making sure there is a token to tell from.
  Future<bool> checkLoggedIn() async {
    await _auth.ensureAccessToken();
    return _auth.isLoggedIn;
  }

  bool _isRetry(RequestOptions options) => options.extra['retried'] == true;

  static bool _isLoginRequired(Response<dynamic>? response) {
    final data = response?.data;
    return data is Map && data['error'] == 'login_required';
  }
}
