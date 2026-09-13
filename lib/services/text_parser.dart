import '../models/sentence.dart';

class ParsedChapter {
  ParsedChapter({required this.title, required this.text});
  final String title;
  final String text;
}

class ParsedBook {
  ParsedBook({required this.title, required this.chapters, this.author = ''});
  final String title;
  final String author;
  final List<ParsedChapter> chapters;
}

/// Headings we see in Vietnamese novels and in translations of Chinese web
/// novels: "Chương 12", "Chương 12: Tên chương", "Hồi thứ ba", "Quyển 2",
/// plus the plain-English "Chapter 3" that survives some conversions.
final RegExp _headingRe = RegExp(
  r'^\s{0,6}(?:(?:Quyển|QUYỂN)\s+\S+\s*[-–—:：.]?\s*)?'
  r'(Chương|CHƯƠNG|Chuong|Chapter|CHAPTER|Hồi|HỒI|Phần|PHẦN)'
  r'\s*(?:thứ\s+)?([0-9]{1,4}|[IVXLCDM]{1,8})\b\s*[:：.、\-–—]?\s*(.{0,120})$',
);

/// Translations of Chinese web novels usually wrap the heading in decorative
/// brackets: 【Chương 1：Tiêu đề】. Strip them before matching.
final RegExp _headingOpenRe = RegExp(r'^[【〖「『《〔\[(]+\s*');
final RegExp _headingCloseRe = RegExp(r'\s*[】〗」』》〕\])]+$');

/// A line that is short, on its own, and looks like a title even without the
/// word "Chương" — e.g. "第一章 …" left over from the source, or "1. Mở đầu".
final RegExp _numberedHeadingRe = RegExp(r'^\s{0,6}([0-9]{1,4})\s*[.、:）)]\s*(\S.{0,110})$');

const int _maxSentenceChars = 220;

/// Commas and friends split a sentence into clauses, each rendered as its own
/// clip so the reader can put a measured pause between them. Below this many
/// characters a clause is not worth splitting off — "Hắn nói:" should stay in
/// one piece.
const int _minClauseChars = 12;
const String _clauseBreaks = ',;:—–';
const String _terminators = '.!?…';
const String _closers = '"”’\'»)]、';

/// Split a raw `.txt` file into chapters. Falls back to one single chapter
/// when the file has no recognisable headings.
ParsedBook parseRawText(String raw, {required String fallbackTitle}) {
  final normalized = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('﻿', '');

  final lines = normalized.split('\n');
  final chapters = <ParsedChapter>[];
  final buffer = StringBuffer();
  String? currentTitle;
  String? bookTitle;
  var sawHeading = false;

  void flush() {
    final text = _tidy(buffer.toString());
    buffer.clear();
    if (currentTitle == null && text.isEmpty) return;
    chapters.add(ParsedChapter(
      title: currentTitle ?? 'Mở đầu',
      text: text,
    ));
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final heading = _headingOf(line);
    if (heading != null) {
      // Text seen before the first heading is either the book title or a
      // preface; keep it as its own chapter so nothing is silently dropped.
      if (currentTitle == null) {
        final preface = _tidy(buffer.toString());
        if (preface.isNotEmpty) {
          final prefaceLines = preface.split('\n');
          if (prefaceLines.length <= 3) {
            bookTitle = prefaceLines.first.trim();
            buffer.clear();
          }
        }
      }
      flush();
      sawHeading = true;
      currentTitle = heading;
      continue;
    }
    buffer.writeln(line);
  }
  flush();

  // A file with no headings at all is one unnamed chapter; give it the
  // book's own name rather than a made-up "Mở đầu".
  if (!sawHeading) {
    final text = _tidy(normalized);
    chapters
      ..clear()
      ..add(ParsedChapter(title: fallbackTitle, text: text));
  }

  return ParsedBook(
    title: (bookTitle != null && bookTitle.isNotEmpty)
        ? bookTitle
        : fallbackTitle,
    chapters: chapters,
  );
}

String? _headingOf(String line) {
  final trimmed = line
      .trim()
      .replaceFirst(_headingOpenRe, '')
      .replaceFirst(_headingCloseRe, '')
      .trim();
  if (trimmed.isEmpty || trimmed.length > 140) return null;

  final m = _headingRe.firstMatch(trimmed);
  if (m != null) {
    final rest = (m.group(3) ?? '').trim();
    final head = '${m.group(1)} ${m.group(2)}';
    return rest.isEmpty ? head : '$head: $rest';
  }

  final n = _numberedHeadingRe.firstMatch(trimmed);
  if (n != null && trimmed.length <= 80) {
    return 'Chương ${n.group(1)}: ${n.group(2)!.trim()}';
  }
  return null;
}

String _tidy(String text) {
  // Collapse runs of blank lines but keep paragraph breaks.
  final collapsed = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return collapsed.trim();
}

/// Break chapter text into paragraphs and sentences, keeping exact character
/// offsets so the reader can highlight the spoken span in place.
List<Paragraph> segment(String text) {
  final paragraphs = <Paragraph>[];
  var sentenceIndex = 0;
  var cursor = 0;
  var paragraphIndex = 0;

  while (cursor <= text.length) {
    var lineEnd = text.indexOf('\n', cursor);
    final hasNewline = lineEnd != -1;
    if (!hasNewline) lineEnd = text.length;

    final end = hasNewline ? lineEnd + 1 : lineEnd;
    final spans = <Sentence>[];
    for (final range in _sentenceRanges(text, cursor, end)) {
      spans.add(Sentence(
        index: sentenceIndex++,
        paragraphIndex: paragraphIndex,
        start: range.$1,
        end: range.$2,
        text: text.substring(range.$1, range.$2).trim(),
        startsSentence: range.$3,
      ));
    }
    if (spans.isNotEmpty) {
      paragraphs.add(Paragraph(
        index: paragraphIndex++,
        start: cursor,
        end: end,
        sentences: spans,
      ));
    }

    if (!hasNewline) break;
    cursor = end;
  }
  return paragraphs;
}

/// Sentence and clause boundaries inside `[from, to)`. Returned ranges are
/// contiguous and cover the whole slice, so concatenating them reproduces the
/// text exactly. The third field marks the ranges that begin a new sentence;
/// the rest are clauses continuing the one before.
List<(int, int, bool)> _sentenceRanges(String text, int from, int to) {
  final ranges = <(int, int, bool)>[];
  if (to <= from) return ranges;

  var start = from;
  var i = from;

  while (i < to) {
    final c = text[i];
    if (!_terminators.contains(c)) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < to &&
        (_terminators.contains(text[j]) || _closers.contains(text[j]))) {
      j++;
    }
    // A terminator only ends a sentence when whitespace (or the slice end)
    // follows it — this keeps "1.500" and "T.P" in one piece.
    if (j < to && !_isSpace(text[j])) {
      i = j;
      continue;
    }
    while (j < to && _isSpace(text[j])) {
      j++;
    }
    ranges.addAll(_clauses(text, start, j));
    start = j;
    i = j;
  }
  if (start < to) ranges.addAll(_clauses(text, start, to));
  return ranges;
}

/// Splits one sentence at its commas.
///
/// A comma pause used to be produced by stretching the quiet parts of the
/// generated audio, but measuring the model showed that cannot work: in a
/// 7.77 s sentence with two commas the detector found four quiet runs of
/// 109–141 ms, and the two that were not commas were the same length as the
/// two that were. Splitting on the text instead is exact — and the punctuation
/// stays attached to the clause, so the model still phrases it as a
/// continuation rather than a full stop.
List<(int, int, bool)> _clauses(String text, int from, int to) {
  final pieces = <(int, int, bool)>[];
  var start = from;
  var first = true;

  for (var i = from; i < to; i++) {
    if (!_clauseBreaks.contains(text[i])) continue;
    var cut = i + 1;
    while (cut < to && _isSpace(text[cut]) && text[cut] != '\n') {
      cut++;
    }
    // Leave short fragments alone: they read as stumbles, not clauses.
    if (cut - start < _minClauseChars || to - cut < _minClauseChars) continue;
    pieces.addAll(_capLength(text, start, cut, first));
    start = cut;
    first = false;
  }
  if (start < to) pieces.addAll(_capLength(text, start, to, first));
  return pieces;
}

/// Very long runs without punctuation make the engine slow to first audio, so
/// split them further on commas and other soft breaks.
List<(int, int, bool)> _capLength(
    String text, int start, int end, bool startsSentence) {
  if (end - start <= _maxSentenceChars) return [(start, end, startsSentence)];

  final out = <(int, int, bool)>[];
  var cursor = start;
  while (end - cursor > _maxSentenceChars) {
    var cut = -1;
    for (var k = cursor + _maxSentenceChars; k > cursor + 40; k--) {
      if (',;:—–'.contains(text[k])) {
        cut = k + 1;
        break;
      }
    }
    if (cut == -1) {
      for (var k = cursor + _maxSentenceChars; k > cursor + 40; k--) {
        if (_isSpace(text[k])) {
          cut = k + 1;
          break;
        }
      }
    }
    if (cut == -1) cut = cursor + _maxSentenceChars;
    out.add((cursor, cut, startsSentence && out.isEmpty));
    cursor = cut;
  }
  if (cursor < end) out.add((cursor, end, startsSentence && out.isEmpty));
  return out;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == ' ';
