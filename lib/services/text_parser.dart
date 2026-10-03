import '../models/sentence.dart';

const int _maxSentenceChars = 220;

/// Commas and friends split a sentence into clauses, each its own span, so
/// the highlight and tap-to-seek work at a finer grain than whole sentences.
/// Below this many characters a clause is not worth splitting off — "Hắn
/// nói:" should stay in one piece.
const int _minClauseChars = 12;
const String _clauseBreaks = ',;:—–';
const String _terminators = '.!?…';
const String _closers = '"”’\'»)]、';

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
      final raw = text.substring(range.$1, range.$2);
      spans.add(Sentence(
        index: sentenceIndex++,
        paragraphIndex: paragraphIndex,
        start: range.$1,
        end: range.$2,
        text: raw.trim(),
        textStart: range.$1 + raw.length - raw.trimLeft().length,
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
