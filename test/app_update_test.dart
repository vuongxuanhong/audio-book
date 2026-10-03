import 'package:audio_book/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares versions numerically, not as strings', () {
    expect(AppUpdateService.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    expect(AppUpdateService.compareVersions('1.2', '1.2.0'), 0);
    expect(AppUpdateService.compareVersions('1.2.0+7', '1.2.0'), 0);
    expect(AppUpdateService.compareVersions('0.9.9', '1.0.0'), lessThan(0));
  });

  UpdateKind decide(String current, {String? skipped}) =>
      AppUpdateService.decide(
        current: current,
        minVersion: '1.2.0',
        latestVersion: '1.4.0',
        storeUrl: 'https://store',
        skippedVersion: skipped,
      ).kind;

  test('below the minimum is required, even if the latest was skipped', () {
    expect(decide('1.1.9'), UpdateKind.required);
    expect(decide('1.1.9', skipped: '1.4.0'), UpdateKind.required);
  });

  test(
    'between minimum and latest is optional until that version is skipped',
    () {
      expect(decide('1.2.0'), UpdateKind.optional);
      expect(decide('1.3.5', skipped: '1.4.0'), UpdateKind.none);
      expect(decide('1.3.5', skipped: '1.3.0'), UpdateKind.optional);
    },
  );

  test('at or above the latest needs nothing', () {
    expect(decide('1.4.0'), UpdateKind.none);
    expect(decide('2.0.0'), UpdateKind.none);
  });
}
