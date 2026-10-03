import 'package:audio_book/services/settings_store.dart';
import 'package:audio_book/state/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offers exactly four speeds', () {
    expect(AppSettings.speedSteps, [0.75, 1.0, 1.25, 1.5]);
  });

  test('a speed saved by an earlier version snaps to the nearest offered', () async {
    for (final (saved, expected) in [
      (0.5, 0.75),
      (0.9, 1.0),
      (1.1, 1.0),
      (1.75, 1.5),
      (2.0, 1.5),
    ]) {
      SharedPreferences.setMockInitialValues({'playback.speed': saved});
      final settings = AppSettings(await SettingsStore.open());
      expect(settings.speed, expected, reason: 'saved $saved');
    }
  });

  test('setSpeed only ever stores an offered speed', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.open();
    AppSettings(store).setSpeed(1.3);
    expect(store.speed, 1.25);
  });
}
