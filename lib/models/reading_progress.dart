class ReadingProgress {
  const ReadingProgress({
    required this.bookId,
    required this.chapterIndex,
    required this.sentenceIndex,
    required this.updatedAt,
  });

  final String bookId;
  final int chapterIndex;
  final int sentenceIndex;
  final DateTime updatedAt;

  factory ReadingProgress.fromJson(Map<String, dynamic> json) =>
      ReadingProgress(
        bookId: json['bookId'] as String,
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        sentenceIndex: json['sentenceIndex'] as int? ?? 0,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'sentenceIndex': sentenceIndex,
        'updatedAt': updatedAt.toIso8601String(),
      };
}
