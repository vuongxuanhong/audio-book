import 'package:flutter/rendering.dart';

import '../models/sentence.dart';

/// A page is a run of sentences from the flat, chapter-wide sentence list.
/// [endSentence] is exclusive, mirroring how [Paragraph]/[Sentence] offsets
/// already work.
class PageRange {
  const PageRange({required this.startSentence, required this.endSentence});

  final int startSentence;
  final int endSentence;

  bool contains(int sentenceIndex) =>
      sentenceIndex >= startSentence && sentenceIndex < endSentence;
}

const double _paragraphSpacing = 6;
const double _blankParagraphFactor = 0.6;
const double _epsilon = 0.01;

/// Cushion subtracted from the page height before deciding what fits.
///
/// A measurement taken with [TextPainter] and the real on-screen render are
/// normally identical as long as [paginate]'s caller passes the same
/// `textScaler` the page actually renders with (the bug this margin used to
/// paper over), but a quarter-line margin turned out to still be too thin in
/// practice — a paragraph that measures as fitting can still wrap one line
/// taller in the real render, and with so little headroom that line's tail
/// gets lost to `_PageBody`'s defensive clip instead of moving to the next
/// page. A full line of headroom is enough margin for that drift to always
/// trigger an early page break instead.
double _safetyMargin(TextStyle style) => (style.fontSize ?? 16) * (style.height ?? 1.3);

/// Splits [paragraphs] into screen-sized [PageRange]s for the given
/// [pageSize]/[style] — the same measurements `_ParagraphSlice` renders with,
/// so a page always fits without scrolling.
///
/// [textScaler] must match the one the reader actually renders with (e.g.
/// `MediaQuery.textScalerOf(context)`) — otherwise the two disagree on how
/// tall a line of text is and pages can overflow or leave the page
/// half-empty.
///
/// Pages only ever break between sentences, never inside one: sentence
/// offsets are what TTS highlighting and tap-to-jump are keyed on, so a
/// sentence split across two pages would have no single page to highlight it
/// on.
List<PageRange> paginate({
  required List<Paragraph> paragraphs,
  required Size pageSize,
  required TextStyle style,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final sentences = <Sentence>[
    for (final p in paragraphs) ...p.sentences,
  ];
  if (sentences.isEmpty) {
    return const [PageRange(startSentence: 0, endSentence: 0)];
  }

  final maxWidth = pageSize.width;
  final maxHeight = pageSize.height - _safetyMargin(style);
  final fontSize = style.fontSize ?? 16;

  double measure(String text) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    return painter.size.height;
  }

  String joined(Iterable<Sentence> list) {
    final items = list.where((s) => s.text.isNotEmpty).toList();
    return items.map((s) => s.text).join(' ');
  }

  final pages = <PageRange>[];
  var pageStart = sentences.first.index;
  var heightUsed = 0.0;

  for (final paragraph in paragraphs) {
    if (paragraph.isBlank) {
      final h = fontSize * _blankParagraphFactor;
      if (heightUsed > 0 && heightUsed + h > maxHeight + _epsilon) {
        final breakAt = paragraph.sentences.first.index;
        pages.add(PageRange(startSentence: pageStart, endSentence: breakAt));
        pageStart = breakAt;
        heightUsed = 0;
      }
      heightUsed += h;
      continue;
    }

    final paragraphHeight = measure(joined(paragraph.sentences)) + _paragraphSpacing;

    // Doesn't fit what's left of the current page, but the page already has
    // something on it: start a fresh page before deciding whether the
    // paragraph itself needs splitting.
    if (heightUsed > 0 && heightUsed + paragraphHeight > maxHeight + _epsilon) {
      final breakAt = paragraph.sentences.first.index;
      pages.add(PageRange(startSentence: pageStart, endSentence: breakAt));
      pageStart = breakAt;
      heightUsed = 0;
    }

    if (heightUsed == 0 && paragraphHeight > maxHeight + _epsilon) {
      // The paragraph alone is taller than an empty page: split it at
      // sentence boundaries, possibly across several pages.
      var start = 0;
      final all = paragraph.sentences;
      while (start < all.length) {
        var end = start + 1;
        var lastGoodHeight = measure(joined(all.sublist(start, end))) + _paragraphSpacing;
        while (end < all.length) {
          final tryHeight =
              measure(joined(all.sublist(start, end + 1))) + _paragraphSpacing;
          if (tryHeight > maxHeight + _epsilon) break;
          end++;
          lastGoodHeight = tryHeight;
        }

        if (end == all.length) {
          // Last chunk of the paragraph stays open, so following paragraphs
          // (if any) can still share this page.
          pageStart = all[start].index;
          heightUsed = lastGoodHeight;
        } else {
          final breakAt = all[end].index;
          pages.add(PageRange(startSentence: pageStart, endSentence: breakAt));
          pageStart = breakAt;
        }
        start = end;
      }
      continue;
    }

    heightUsed += paragraphHeight;
  }

  pages.add(PageRange(startSentence: pageStart, endSentence: sentences.last.index + 1));
  return pages;
}
