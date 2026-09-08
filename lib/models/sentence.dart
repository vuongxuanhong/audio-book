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
    this.startsSentence = true,
  });

  final int index;
  final int paragraphIndex;
  final int start;
  final int end;

  /// Trimmed text handed to the TTS engine. Empty for whitespace-only spans.
  final String text;

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
