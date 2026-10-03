import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart' show remoteApiBaseUrl;

enum UpdateKind { none, optional, required }

class UpdateCheck {
  const UpdateCheck(this.kind, {this.latestVersion = '', this.storeUrl = ''});

  static const none = UpdateCheck(UpdateKind.none);

  final UpdateKind kind;
  final String latestVersion;
  final String storeUrl;
}

/// Asks the backend which app versions it still accepts. A failed check
/// (offline, server down) never blocks: listening to cached chapters has to
/// keep working without a network.
class AppUpdateService {
  AppUpdateService(this._prefs);

  final SharedPreferences _prefs;

  // A bare Dio, not ApiClient's: the check mustn't depend on device auth,
  // and mustn't hang the launch on a slow network.
  final _dio = Dio(
    BaseOptions(
      baseUrl: remoteApiBaseUrl,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );

  static const _kSkippedVersion = 'update.skippedVersion';

  Future<UpdateCheck> check() async {
    if (!Platform.isIOS && !Platform.isAndroid) return UpdateCheck.none;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/v1/app/version',
        queryParameters: {'platform': Platform.isIOS ? 'ios' : 'android'},
      );
      final data = response.data!;
      final current = (await PackageInfo.fromPlatform()).version;
      return decide(
        current: current,
        minVersion: data['min_version'] as String,
        latestVersion: data['latest_version'] as String,
        storeUrl: data['store_url'] as String,
        skippedVersion: _prefs.getString(_kSkippedVersion),
      );
    } on Object {
      return UpdateCheck.none;
    }
  }

  /// The optional prompt for [version] isn't shown again; a newer
  /// latest version brings it back.
  Future<void> skip(String version) =>
      _prefs.setString(_kSkippedVersion, version);

  static UpdateCheck decide({
    required String current,
    required String minVersion,
    required String latestVersion,
    required String storeUrl,
    String? skippedVersion,
  }) {
    if (compareVersions(current, minVersion) < 0) {
      return UpdateCheck(
        UpdateKind.required,
        latestVersion: latestVersion,
        storeUrl: storeUrl,
      );
    }
    if (compareVersions(current, latestVersion) < 0 &&
        skippedVersion != latestVersion) {
      return UpdateCheck(
        UpdateKind.optional,
        latestVersion: latestVersion,
        storeUrl: storeUrl,
      );
    }
    return UpdateCheck.none;
  }

  /// Compares "major.minor.patch" numerically ("1.10.0" > "1.9.0"). Missing
  /// parts count as 0; anything after `+` or `-` is ignored.
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .split(RegExp('[+-]'))
        .first
        .split('.')
        .map((p) => int.tryParse(p.trim()) ?? 0)
        .toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
}
