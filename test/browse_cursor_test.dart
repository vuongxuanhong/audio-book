import 'package:audio_book/services/text_parser.dart';
import 'package:audio_book/state/reader_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Three paragraphs; the middle one holds three sentences.
  final paragraphs = segment(
    'Mở đầu.\n'
    'Câu một. Câu hai. Câu ba.\n'
    'Kết thúc.',
  );

  int sentenceAt(int paragraph, int nth) =>
      paragraphs[paragraph].sentences.where((s) => s.isSpeakable).toList()[nth].index;

  group('resolveBrowseCursor', () {
    test('leaves a tapped sentence alone while its paragraph is on screen', () {
      // The regression: tapping the third sentence of a paragraph used to snap
      // back to that paragraph's first sentence as soon as any scroll landed.
      final tapped = sentenceAt(1, 2);
      expect(
        resolveBrowseCursor(
          paragraphs: paragraphs,
          cursor: tapped,
          firstVisible: 1,
          lastVisible: 2,
        ),
        isNull,
      );
    });

    test('keeps the cursor when its paragraph is only partly scrolled past',
        () {
      final tapped = sentenceAt(1, 1);
      expect(
        resolveBrowseCursor(
          paragraphs: paragraphs,
          cursor: tapped,
          firstVisible: 0,
          lastVisible: 1,
        ),
        isNull,
      );
    });

    test('moves the cursor once the user scrolls the paragraph out of view',
        () {
      expect(
        resolveBrowseCursor(
          paragraphs: paragraphs,
          cursor: sentenceAt(0, 0),
          firstVisible: 2,
          lastVisible: 2,
        ),
        sentenceAt(2, 0),
      );
    });

    test('returns null when the cursor already sits on the visible paragraph',
        () {
      expect(
        resolveBrowseCursor(
          paragraphs: paragraphs,
          cursor: sentenceAt(2, 0),
          firstVisible: 2,
          lastVisible: 2,
        ),
        isNull,
      );
    });

    test('tolerates an out-of-range paragraph index', () {
      expect(
        resolveBrowseCursor(
          paragraphs: paragraphs,
          cursor: 0,
          firstVisible: 99,
          lastVisible: 99,
        ),
        isNull,
      );
      expect(
        resolveBrowseCursor(
          paragraphs: const [],
          cursor: 0,
          firstVisible: 0,
          lastVisible: 0,
        ),
        isNull,
      );
    });
  });
}
