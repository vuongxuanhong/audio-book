import 'package:audio_book/state/reader_controller.dart';
import 'package:flutter_test/flutter_test.dart';

double _pause({
  bool isFirst = false,
  bool afterBeat = false,
  bool newParagraph = false,
  bool startsSentence = true,
}) =>
    pauseMsFor(
      isFirst: isFirst,
      afterBeat: afterBeat,
      newParagraph: newParagraph,
      startsSentence: startsSentence,
      beatMs: 2000,
      paragraphMs: 1100,
      sentenceMs: 700,
      clauseMs: 300,
    );

void main() {
  group('pauseMsFor', () {
    test('says nothing before the first line — play should speak at once', () {
      expect(_pause(isFirst: true), 0);
      // Even when every other flag argues for a long wait.
      expect(
        _pause(isFirst: true, afterBeat: true, newParagraph: true),
        0,
      );
    });

    test('a scene break outranks a paragraph break', () {
      expect(_pause(afterBeat: true, newParagraph: true), 2000);
    });

    test('a paragraph break outranks a full stop', () {
      expect(_pause(newParagraph: true), 1100);
    });

    test('a full stop for a new sentence, a comma for a continuation', () {
      expect(_pause(), 700);
      expect(_pause(startsSentence: false), 300);
    });

    test('the tiers stay ordered longest to shortest', () {
      final beat = _pause(afterBeat: true);
      final paragraph = _pause(newParagraph: true);
      final sentence = _pause();
      final clause = _pause(startsSentence: false);
      expect(beat, greaterThan(paragraph));
      expect(paragraph, greaterThan(sentence));
      expect(sentence, greaterThan(clause));
    });
  });
}
