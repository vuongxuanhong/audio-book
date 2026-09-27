import 'package:audio_book/models/voice.dart';
import 'package:audio_book/models/voice_speakers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pack = 'some-multi-speaker-pack';

  group('speakerChoices', () {
    test('numbers speakers from one for display', () {
      expect(speakerChoices(pack, 3).first.name, 'Giọng 1');
      expect(speakerChoices(pack, 3).last.name, 'Giọng 3');
    });

    test('degrades to a plain list for an unmeasured pack', () {
      final choices = speakerChoices('some-other-pack', 4);
      expect(choices.length, 4);
      expect(choices.every((c) => c.pitchHz == 0), isTrue);
      expect(choices.every((c) => c.detail.isEmpty), isTrue);
      expect(choices.every((c) => !c.isMale), isTrue);
    });
  });

  group('catalogue', () {
    test('every entry has a unique id and slot', () {
      final ids = kVoiceCatalog.map((e) => e.id).toSet();
      final slots = kVoiceCatalog.map((e) => e.slot).toSet();
      expect(ids.length, kVoiceCatalog.length);
      expect(slots.length, kVoiceCatalog.length);
    });

    test('slots stay one character so the espeak path budget holds', () {
      expect(kVoiceCatalog.every((e) => e.slot.length == 1), isTrue);
    });

    test('every download url points at the sherpa-onnx release', () {
      for (final e in kVoiceCatalog) {
        expect(
          e.url,
          startsWith(
              'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'),
        );
        expect(e.url, endsWith('.tar.bz2'));
      }
    });

    test('exactly one voice is marked recommended', () {
      expect(kVoiceCatalog.where((e) => e.recommended).length, 1);
    });
  });

  group('InstalledVoice', () {
    test('reports single- and multi-speaker packs apart', () {
      const single = InstalledVoice(
          id: 'a', name: 'a', modelPath: '', tokensPath: '', dataDir: '');
      const many = InstalledVoice(
          id: 'b',
          name: 'b',
          modelPath: '',
          tokensPath: '',
          dataDir: '',
          numSpeakers: 65);
      expect(single.isMultiSpeaker, isFalse);
      expect(many.isMultiSpeaker, isTrue);
    });
  });
}
