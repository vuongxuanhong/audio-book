import 'package:audio_book/models/chapter_audio.dart';
import 'package:audio_book/services/text_parser.dart';
import 'package:audio_book/state/reader_controller.dart';
import 'package:audio_book/ui/reader_screen.dart';
import 'package:flutter_test/flutter_test.dart';

TimelineChunk _chunk(int timeMs, int start, int end) =>
    TimelineChunk(timeMs: timeMs, startOffset: start, endOffset: end);

void main() {
  const text = 'Câu một. Câu hai.\n……\nCâu ba.';
  final sentences = [for (final p in segment(text)) ...p.sentences];

  int startOf(String s) => text.indexOf(s);
  int endOf(String s) => text.indexOf(s) + s.length;

  // One chunk per spoken sentence; "……" has none.
  final chunks = [
    _chunk(0, startOf('Câu một.'), endOf('Câu một.')),
    _chunk(1200, startOf('Câu hai.'), endOf('Câu hai.')),
    _chunk(3000, startOf('Câu ba.'), endOf('Câu ba.')),
  ];

  int sentenceOf(String s) =>
      sentences.indexWhere((x) => x.text == s);

  group('chunkIndexAt', () {
    test('picks the last chunk that has started', () {
      expect(chunkIndexAt(chunks, 0), 0);
      expect(chunkIndexAt(chunks, 1199), 0);
      expect(chunkIndexAt(chunks, 1200), 1);
      expect(chunkIndexAt(chunks, 999999), 2);
    });

    test('falls back to the first chunk before any has started', () {
      expect(chunkIndexAt([_chunk(500, 0, 4)], 0), 0);
    });
  });

  group('sentenceAtOffset', () {
    test('finds the sentence holding an offset', () {
      expect(sentenceAtOffset(sentences, startOf('Câu một.')), sentenceOf('Câu một.'));
      expect(sentenceAtOffset(sentences, startOf('hai')), sentenceOf('Câu hai.'));
      expect(sentenceAtOffset(sentences, startOf('Câu ba.')), sentenceOf('Câu ba.'));
    });
  });

  group('estimatedReadingOffset', () {
    // One chunk reading both "Câu một." and "Câu hai." from 0 to 2000 ms.
    final wide = [
      _chunk(0, startOf('Câu một.'), endOf('Câu hai.')),
      _chunk(2000, startOf('Câu ba.'), endOf('Câu ba.')),
    ];

    test('moves through the chunk with the time gone by', () {
      expect(estimatedReadingOffset(wide, 0, 0, 3000), startOf('Câu một.'));
      final halfway = estimatedReadingOffset(wide, 0, 1000, 3000);
      expect(halfway, greaterThan(startOf('Câu một.')));
      expect(halfway, lessThan(endOf('Câu hai.')));
      // Late in the chunk the narration has reached the second sentence —
      // which may be on the next page.
      expect(
        sentenceAtOffset(sentences, estimatedReadingOffset(wide, 0, 1900, 3000)),
        sentenceOf('Câu hai.'),
      );
    });

    test('never leaves the chunk', () {
      expect(estimatedReadingOffset(wide, 0, 999999, 3000), endOf('Câu hai.') - 1);
      expect(estimatedReadingOffset(wide, 0, -5, 3000), startOf('Câu một.'));
    });

    test('the last chunk runs until the end of the audio', () {
      final last = estimatedReadingOffset(wide, 1, 2500, 3000);
      expect(last, greaterThan(startOf('Câu ba.')));
      expect(last, lessThan(endOf('Câu ba.')));
    });
  });

  group('highlightParts', () {
    String lit(List<(String, bool)> parts) =>
        parts.where((p) => p.$2).map((p) => p.$1).join();
    String all(List<(String, bool)> parts) => parts.map((p) => p.$1).join();

    final one = sentences[sentenceOf('Câu một.')];
    final two = sentences[sentenceOf('Câu hai.')];

    test('a chunk covering several sentences lights all of them', () {
      final range = (startOf('Câu một.'), endOf('Câu hai.'));
      expect(lit(highlightParts(one, range, trailingSpace: true)), 'Câu một. ');
      expect(lit(highlightParts(two, range, trailingSpace: false)), 'Câu hai.');
    });

    test('a chunk ending mid-sentence lights only its part', () {
      final range = (startOf('Câu hai.'), startOf('hai.'));
      final parts = highlightParts(two, range, trailingSpace: true);
      expect(lit(parts), 'Câu ');
      expect(all(parts), 'Câu hai. ', reason: 'the text itself is unchanged');
    });

    test('the space after a sentence stays unlit where the chunk stops', () {
      final range = (startOf('Câu một.'), endOf('Câu một.'));
      final parts = highlightParts(one, range, trailingSpace: true);
      expect(lit(parts), 'Câu một.');
      expect(all(parts), 'Câu một. ');
    });

    test('no highlight, or one elsewhere, leaves the sentence plain', () {
      expect(highlightParts(one, null, trailingSpace: true), [('Câu một. ', false)]);
      final elsewhere = (startOf('Câu ba.'), endOf('Câu ba.'));
      expect(lit(highlightParts(one, elsewhere, trailingSpace: true)), isEmpty);
    });
  });

  group('sentenceStartMs', () {
    test('seeks to the chunk that reads the sentence', () {
      expect(sentenceStartMs(chunks, sentences[sentenceOf('Câu hai.')]), 1200);
    });

    test('a sentence with nothing read aloud starts with what comes next', () {
      final beat = sentences.firstWhere((s) => s.isPauseMark);
      expect(sentenceStartMs(chunks, beat), 3000);
    });

    test('a sentence read inside a longer chunk starts with that chunk', () {
      final whole = [_chunk(0, 0, text.length)];
      expect(sentenceStartMs(whole, sentences[sentenceOf('Câu ba.')]), 0);
    });
  });

  group('ChapterAudio.tryParse', () {
    Map<String, dynamic> json({String? url = 'https://a.example/a/x.m4a'}) => {
          'url': url,
          'url_expires_at': '2030-01-01T00:00:00Z',
          'duration_ms': 4000,
          'size_bytes': 1,
          'mime_type': 'audio/mp4',
          'timeline': {
            'version': 1,
            'duration_ms': 4000,
            'chunks': [
              {'time_ms': 1200, 'start_offset': 9, 'end_offset': 17},
              {'time_ms': 0, 'start_offset': 0, 'end_offset': 8},
            ],
          },
        };

    test('parses and sorts the timeline by time', () {
      final audio = ChapterAudio.tryParse(json())!;
      expect(audio.timeline.map((c) => c.timeMs), [0, 1200]);
      expect(audio.isFresh(), isTrue);
    });

    test('is null without audio or without a signed url', () {
      expect(ChapterAudio.tryParse(null), isNull);
      expect(ChapterAudio.tryParse(json(url: null)), isNull);
    });
  });
}
