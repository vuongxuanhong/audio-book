import 'package:audio_book/models/chapter_audio.dart';
import 'package:audio_book/services/text_parser.dart';
import 'package:audio_book/state/reader_controller.dart';
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

  group('chunkSentenceIndices', () {
    test('maps each chunk to the sentence its text starts in', () {
      expect(chunkSentenceIndices(chunks, sentences), [
        sentenceOf('Câu một.'),
        sentenceOf('Câu hai.'),
        sentenceOf('Câu ba.'),
      ]);
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
