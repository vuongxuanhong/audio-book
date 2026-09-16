import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import 'device_auth.dart';

/// Placeholder until a real host is chosen (see the backend repo's plan doc);
/// point this at wherever `audiobook-backend` ends up running.
const String remoteApiBaseUrl = 'http://localhost:8000';

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
          if (response?.statusCode == 401 && !_isRetry(error.requestOptions)) {
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
    // token shows up too) — added after the auth interceptor so it sees the
    // Authorization header once that's attached. Debug builds only.
    if (kDebugMode) {
      _dio.interceptors.add(LogInterceptor(
        requestHeader: true,
        responseHeader: true,
        logPrint: (obj) => debugPrint('[api] $obj'),
      ));
    }
  }

  final DeviceAuth _auth;
  late final Dio _dio;

  Dio get dio => _dio;

  bool _isRetry(RequestOptions options) => options.extra['retried'] == true;
}
