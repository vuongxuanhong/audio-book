import 'package:audio_book/models/sentence.dart';
import 'package:audio_book/services/paginator.dart';
import 'package:audio_book/services/text_parser.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(fontSize: 16, height: 1.4);

  int totalSentences(List<Paragraph> paragraphs) =>
      paragraphs.fold(0, (n, p) => n + p.sentences.length);

  group('paginate', () {
    test('an empty chapter still yields one (empty) page', () {
      final pages = paginate(
        paragraphs: const [],
        pageSize: const Size(400, 800),
        style: style,
      );
      expect(pages, hasLength(1));
      expect(pages.single.startSentence, 0);
      expect(pages.single.endSentence, 0);
    });

    test('a short chapter fits entirely on one page', () {
      final paragraphs = segment('Một câu ngắn. Một câu khác.\nĐoạn hai.');
      final pages = paginate(
        paragraphs: paragraphs,
        pageSize: const Size(400, 800),
        style: style,
      );
      expect(pages, hasLength(1));
      expect(pages.single.startSentence, 0);
      expect(pages.single.endSentence, totalSentences(paragraphs));
    });

    test('a blank paragraph (scene break) does not stop pagination', () {
      final paragraphs = segment('Đoạn một.\n……\nĐoạn hai.');
      final pages = paginate(
        paragraphs: paragraphs,
        pageSize: const Size(400, 800),
        style: style,
      );
      expect(pages, hasLength(1));
      expect(pages.single.endSentence, totalSentences(paragraphs));
    });

    test('a long paragraph is split across pages at sentence boundaries', () {
      final sentences = List.generate(
        60,
        (i) => 'Đây là câu số $i trong một đoạn văn khá dài dùng để kiểm tra việc chia trang.',
      ).join(' ');
      final paragraphs = segment(sentences);
      expect(paragraphs, hasLength(1)); // one giant paragraph, no blank lines

      // A short page height forces the single paragraph to split.
      final pages = paginate(
        paragraphs: paragraphs,
        pageSize: const Size(300, 150),
        style: style,
      );
      expect(pages.length, greaterThan(1));

      // Every sentence boundary a page breaks on is a real sentence start —
      // i.e. no page range starts or ends in the middle of a sentence.
      final sentenceStarts =
          paragraphs.single.sentences.map((s) => s.index).toSet();
      for (final page in pages) {
        expect(sentenceStarts.contains(page.startSentence), isTrue);
      }
    });

    test('page ranges are contiguous and cover every sentence exactly once',
        () {
      final text = List.generate(
        12,
        (i) => 'Đoạn văn số $i có vài câu. Câu thứ hai của đoạn. Câu thứ ba kết thúc đoạn.',
      ).join('\n');
      final paragraphs = segment(text);

      final pages = paginate(
        paragraphs: paragraphs,
        pageSize: const Size(280, 100),
        style: style,
      );

      expect(pages.first.startSentence, 0);
      var expectedNextStart = 0;
      for (final page in pages) {
        expect(page.startSentence, expectedNextStart);
        expect(page.endSentence, greaterThan(page.startSentence));
        expectedNextStart = page.endSentence;
      }
      expect(expectedNextStart, totalSentences(paragraphs));
    });
  });
}
