// Prints how a real .txt would be imported: chapter titles, sizes and the
// first few sentences of chapter 1.
//
//   dart run tool/parse_check.dart Chuong1-5.txt
import 'dart:io';

import 'package:audio_book/services/text_parser.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/parse_check.dart <file.txt>');
    exit(1);
  }
  final file = File(args.first);
  final raw = file.readAsStringSync();
  final name = file.uri.pathSegments.last.replaceAll(RegExp(r'\.\w+$'), '');
  final book = parseRawText(raw, fallbackTitle: name);

  stdout.writeln('title    : ${book.title}');
  stdout.writeln('chapters : ${book.chapters.length}');
  for (final c in book.chapters) {
    final paragraphs = segment(c.text);
    final sentences =
        paragraphs.expand((p) => p.sentences).where((s) => s.isSpeakable).length;
    stdout.writeln('  - ${c.title}  '
        '(${c.text.length} chữ, ${paragraphs.length} đoạn, $sentences câu)');
  }

  // Which pause the reader will use at each transition. "Nghỉ sau câu" only
  // fires between two sentences of the same paragraph, which in a novel laid
  // out one line per paragraph can be rare.
  var withinParagraph = 0;
  var acrossParagraph = 0;
  for (final c in book.chapters) {
    int? previous;
    for (final s in segment(c.text).expand((p) => p.sentences)) {
      if (!s.isSpeakable) continue;
      if (previous != null) {
        if (s.paragraphIndex == previous) {
          withinParagraph++;
        } else {
          acrossParagraph++;
        }
      }
      previous = s.paragraphIndex;
    }
  }
  final total = withinParagraph + acrossParagraph;
  stdout.writeln('\npause usage across the book:');
  stdout.writeln('  nghỉ sau câu   : $withinParagraph '
      '(${(withinParagraph * 100 / total).toStringAsFixed(0)}%)');
  stdout.writeln('  nghỉ giữa đoạn : $acrossParagraph '
      '(${(acrossParagraph * 100 / total).toStringAsFixed(0)}%)');

  stdout.writeln('\nfirst sentences of chapter 1:');
  final first = segment(book.chapters.first.text)
      .expand((p) => p.sentences)
      .where((s) => s.isSpeakable)
      .take(6);
  for (final s in first) {
    stdout.writeln('  [${s.start}-${s.end}] ${s.text}');
  }
}
