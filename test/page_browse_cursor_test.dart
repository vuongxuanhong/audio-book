import 'package:audio_book/services/paginator.dart';
import 'package:audio_book/state/reader_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Three pages of two sentences each: [0,2) [2,4) [4,6).
  const pages = [
    PageRange(startSentence: 0, endSentence: 2),
    PageRange(startSentence: 2, endSentence: 4),
    PageRange(startSentence: 4, endSentence: 6),
  ];

  group('resolvePageBrowseCursor', () {
    test('leaves a tapped sentence alone while its page is still shown', () {
      // The cursor sits on the second sentence of page 1; swiping back to
      // that same page must not snap it to the page's first sentence.
      expect(
        resolvePageBrowseCursor(pages: pages, cursor: 3, pageIndex: 1),
        isNull,
      );
    });

    test('moves the cursor to the first sentence of a newly-browsed page',
        () {
      expect(
        resolvePageBrowseCursor(pages: pages, cursor: 1, pageIndex: 2),
        4,
      );
    });

    test('returns null when the cursor already sits on the browsed page\'s '
        'first sentence', () {
      expect(
        resolvePageBrowseCursor(pages: pages, cursor: 2, pageIndex: 1),
        isNull,
      );
    });

    test('tolerates an out-of-range page index', () {
      expect(
        resolvePageBrowseCursor(pages: pages, cursor: 0, pageIndex: 99),
        isNull,
      );
      expect(
        resolvePageBrowseCursor(pages: const [], cursor: 0, pageIndex: 0),
        isNull,
      );
    });
  });
}
