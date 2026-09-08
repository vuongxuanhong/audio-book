import 'package:audio_book/services/settings_store.dart';
import 'package:audio_book/state/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pacing defaults', () {
    // These three were tuned by ear on a Vietnamese web novel with the
    // VAIS 1000 voice. Pinning them so a refactor cannot quietly drift.
    late AppSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = AppSettings(await SettingsStore.open());
    });

    test('start at the tuned values', () {
      expect(settings.clausePauseMs, 300);
      expect(settings.sentencePauseMs, 700);
      expect(settings.paragraphPauseMs, 1100);
      expect(settings.beatPauseMs, 2000);
    });

    test('each tier is at least as long as the one below it', () {
      expect(settings.sentencePauseMs,
          greaterThanOrEqualTo(settings.clausePauseMs));
      expect(settings.paragraphPauseMs,
          greaterThan(settings.sentencePauseMs));
      expect(settings.beatPauseMs, greaterThan(settings.paragraphPauseMs));
    });

    test('clamp out-of-range values instead of storing them', () {
      settings
        ..setClausePauseMs(99999)
        ..setSentencePauseMs(-5)
        ..setParagraphPauseMs(99999)
        ..setBeatPauseMs(99999);
      expect(settings.clausePauseMs, 800);
      expect(settings.beatPauseMs, 3000);
      expect(settings.sentencePauseMs, 0);
      expect(settings.paragraphPauseMs, 1500);
    });

    test('persist a change back through the store', () async {
      settings.setParagraphPauseMs(900);
      final reloaded = AppSettings(await SettingsStore.open());
      expect(reloaded.paragraphPauseMs, 900);
    });
  });
}
