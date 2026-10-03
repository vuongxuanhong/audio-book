/// A span of chapter text. [start] and [end] are character offsets into the
/// chapter's full text, so the reader can highlight exactly the piece that is
/// being spoken without ever re-flowing the text.
class Sentence {
  const Sentence({
    required this.index,
    required this.paragraphIndex,
    required this.start,
    required this.end,
    required this.text,
    required this.textStart,
    this.startsSentence = true,
  });

  final int index;
  final int paragraphIndex;
  final int start;
  final int end;

  /// The span's text with surrounding whitespace trimmed — what the reader
  /// shows. Empty for whitespace-only spans.
  final String text;

  /// Where [text] starts in the chapter: [start] plus the whitespace trimmed
  /// off the front.
  final int textStart;

  int get textEnd => textStart + text.length;

  /// The part of [text] inside the chapter range [rangeStart, rangeEnd), as
  /// offsets into [text]; null when they don't overlap. Lets the reader
  /// highlight exactly the stretch being read, which needn't line up with
  /// sentence boundaries.
  (int, int)? overlap(int rangeStart, int rangeEnd) {
    final from = (rangeStart > textStart ? rangeStart : textStart) - textStart;
    final to = (rangeEnd < textEnd ? rangeEnd : textEnd) - textStart;
    return from < to ? (from, to) : null;
  }

  /// Letters or digits — anything the model can actually pronounce.
  static final RegExp _voiced = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// False when this span continues the previous sentence after a comma, so
  /// the reader can use a shorter pause in front of it.
  final bool startsSentence;

  /// Whether there is anything to pronounce. Punctuation on its own is not:
  /// asked to say "……" the model emits a 30 ms click rather than silence.
  bool get isSpeakable => _voiced.hasMatch(text);

  /// A span of punctuation with no words — an author's beat, most often the
  /// `……` line Chinese web novels use as a scene break. Read as silence.
  bool get isPauseMark => text.isNotEmpty && !isSpeakable;
}

/// A paragraph groups the sentences that belong to one visual block, which is
/// what the reader actually renders as a list item.
class Paragraph {
  const Paragraph({
    required this.index,
    required this.start,
    required this.end,
    required this.sentences,
  });

  final int index;
  final int start;
  final int end;
  final List<Sentence> sentences;

  bool get isBlank => sentences.every((s) => !s.isSpeakable);
}
