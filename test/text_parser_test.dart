import 'package:audio_book/services/text_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRawText', () {
    test('splits Vietnamese chapter headings', () {
      final book = parseRawText(
        'Sưu Sơn Hàng Ma\n\n'
        'Chương 1: Thiếu niên xuống núi\n'
        'Trời vừa hửng sáng.\n\n'
        'Chương 2: Gặp yêu\n'
        'Gió thổi qua rừng trúc.\n',
        fallbackTitle: 'khong-dung',
      );

      expect(book.title, 'Sưu Sơn Hàng Ma');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].title, 'Chương 1: Thiếu niên xuống núi');
      expect(book.chapters[0].text, 'Trời vừa hửng sáng.');
      expect(book.chapters[1].title, 'Chương 2: Gặp yêu');
    });

    test('reads headings wrapped in decorative brackets', () {
      // The shape produced by translations of Chinese web novels: full-width
      // brackets around the line and a full-width colon.
      final book = parseRawText(
        '\n\n【Chương 1：Trong Long Bối Lĩnh, tiểu dược lang】\n\n'
        'Phủ An Ninh, Trà Mã Đạo.\n\n'
        '【Chương 2: Ấn chữ Sơn, con đường Kỳ Môn】\n\n'
        'Gió thổi qua khe núi.\n',
        fallbackTitle: 'Chuong1-5',
      );

      expect(book.chapters.length, 2);
      expect(book.chapters[0].title,
          'Chương 1: Trong Long Bối Lĩnh, tiểu dược lang');
      expect(book.chapters[0].text, 'Phủ An Ninh, Trà Mã Đạo.');
      expect(book.chapters[1].title, 'Chương 2: Ấn chữ Sơn, con đường Kỳ Môn');
    });

    test('keeps a heading without a subtitle', () {
      final book = parseRawText('Chương 7\nMột dòng.', fallbackTitle: 'x');
      expect(book.chapters.single.title, 'Chương 7');
    });

    test('falls back to one chapter when nothing looks like a heading', () {
      final book = parseRawText('Chỉ là văn xuôi.\nKhông có chương.',
          fallbackTitle: 'Truyện của tôi');
      expect(book.chapters.length, 1);
      expect(book.chapters.single.title, 'Truyện của tôi');
    });
  });

  group('segment', () {
    test('produces contiguous sentence spans that rebuild the text', () {
      const text = 'Hắn nói: "Đi thôi!" Rồi quay đi.\n\nTrời mưa. Rất to…';
      final paragraphs = segment(text);
      final rebuilt = StringBuffer();
      for (final p in paragraphs) {
        for (final s in p.sentences) {
          rebuilt.write(text.substring(s.start, s.end));
        }
      }
      expect(rebuilt.toString(), text);
    });

    test('does not split inside numbers or abbreviations without a space', () {
      final paragraphs = segment('Giá là 1.500 đồng. Rẻ thật.');
      final speakable =
          paragraphs.single.sentences.where((s) => s.isSpeakable).toList();
      expect(speakable.length, 2);
      expect(speakable.first.text, 'Giá là 1.500 đồng.');
    });

    test('breaks runaway sentences so audio starts quickly', () {
      final long = List.filled(60, 'một hai ba bốn').join(', ');
      final paragraphs = segment(long);
      final spans = paragraphs.single.sentences;
      expect(spans.length, greaterThan(1));
      for (final s in spans) {
        expect(s.end - s.start, lessThanOrEqualTo(260));
      }
    });

    test('splits a sentence at its commas, keeping the comma attached', () {
      // The comma has to stay in the clause: piper phrases a clause ending in
      // a comma as a continuation, not as a full stop.
      final spans = segment(
        'Một đứa trẻ trạc tuổi thiếu niên mặc áo vải ngắn, '
        'đeo trên lưng một chiếc giỏ tre lớn gần bằng người mình, '
        'khó nhọc dùng gậy dò đường vạch đám cỏ rậm.',
      ).single.sentences.where((s) => s.isSpeakable).toList();

      expect(spans.length, 3);
      expect(spans[0].text, endsWith('áo vải ngắn,'));
      expect(spans[1].text, endsWith('bằng người mình,'));
      expect(spans[0].startsSentence, isTrue);
      expect(spans[1].startsSentence, isFalse);
      expect(spans[2].startsSentence, isFalse);
    });

    test('leaves short fragments joined to their neighbour', () {
      // "Hắn nói:" is not a clause worth pausing after.
      final spans = segment('Hắn nói: đi thôi.')
          .single
          .sentences
          .where((s) => s.isSpeakable)
          .toList();
      expect(spans.length, 1);
    });

    test('marks each new sentence, clause splits aside', () {
      final spans = segment('Trời sáng. Gió thổi qua khe núi, lạnh buốt cả người.')
          .single
          .sentences
          .where((s) => s.isSpeakable)
          .toList();
      expect(spans.map((s) => s.text).toList(), [
        'Trời sáng.',
        'Gió thổi qua khe núi,',
        'lạnh buốt cả người.',
      ]);
      expect(spans.map((s) => s.startsSentence).toList(),
          [true, true, false]);
    });

    test('treats a punctuation-only line as a beat, not as words', () {
      // Asked to pronounce "……" the model emits a 30 ms click, so these spans
      // must never reach it.
      final spans = segment('Hy vọng.\n……\nMặt trời ngả về tây.')
          .expand((p) => p.sentences)
          .toList();

      final marks = spans.where((s) => s.isPauseMark).toList();
      expect(marks.length, 1);
      expect(marks.single.text, '……');
      expect(marks.single.isSpeakable, isFalse);
      expect(spans.where((s) => s.isSpeakable).map((s) => s.text).toList(),
          ['Hy vọng.', 'Mặt trời ngả về tây.']);
    });

    test('keeps punctuation that is attached to real words', () {
      final spans = segment('Một cây, hai cây, ba cây…')
          .single
          .sentences
          .where((s) => s.isSpeakable)
          .toList();
      expect(spans.last.text, endsWith('…'));
    });

    test('counts digits as speakable', () {
      final spans = segment('Năm 1975.').single.sentences;
      expect(spans.where((s) => s.isSpeakable).length, 1);
    });

    test('blank spans are neither speakable nor a beat', () {
      final blanks = segment('Một.\n\nHai.')
          .expand((p) => p.sentences)
          .where((s) => !s.isSpeakable)
          .toList();
      expect(blanks, isNotEmpty);
      expect(blanks.every((s) => !s.isPauseMark), isTrue);
    });

    test('assigns paragraph indexes that match the rendered list', () {
      final paragraphs = segment('Một.\nHai.\nBa.');
      expect(paragraphs.length, 3);
      for (var i = 0; i < paragraphs.length; i++) {
        expect(paragraphs[i].index, i);
        expect(paragraphs[i].sentences.every((s) => s.paragraphIndex == i), isTrue);
      }
    });
  });
}
