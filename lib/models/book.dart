import 'dart:convert';

/// One chapter of a book. The text itself lives in a separate file inside the
/// book directory; only the metadata is kept in memory / in `book.json`.
class ChapterRef {
  const ChapterRef({
    required this.index,
    required this.title,
    required this.fileName,
    required this.charCount,
  });

  final int index;
  final String title;
  final String fileName;
  final int charCount;

  factory ChapterRef.fromJson(Map<String, dynamic> json) => ChapterRef(
        index: json['index'] as int,
        title: json['title'] as String,
        fileName: json['fileName'] as String,
        charCount: json['charCount'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'fileName': fileName,
        'charCount': charCount,
      };
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.importedAt,
    required this.chapters,
  });

  final String id;
  final String title;
  final String author;
  final DateTime importedAt;
  final List<ChapterRef> chapters;

  int get chapterCount => chapters.length;

  int get totalChars =>
      chapters.fold<int>(0, (sum, c) => sum + c.charCount);

  Book copyWith({String? title, String? author}) => Book(
        id: id,
        title: title ?? this.title,
        author: author ?? this.author,
        importedAt: importedAt,
        chapters: chapters,
      );

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String? ?? '',
        importedAt: DateTime.parse(json['importedAt'] as String),
        chapters: (json['chapters'] as List<dynamic>)
            .map((e) => ChapterRef.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'importedAt': importedAt.toIso8601String(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}
