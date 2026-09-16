import 'dart:convert';

/// One chapter of a book. The text itself lives in a separate file inside the
/// book directory; only the metadata is kept in memory / in `book.json`.
class ChapterRef {
  const ChapterRef({
    required this.index,
    required this.title,
    required this.fileName,
    required this.charCount,
    this.remoteChapterId,
    this.isFree = true,
  });

  final int index;
  final String title;
  final String fileName;
  final int charCount;

  /// Server-side chapter id for a remote book's chapter — null for chapters
  /// imported from a local .txt/.epub. The content route addresses chapters
  /// by this id, not by [index].
  final String? remoteChapterId;

  /// Whether this chapter can be read without an unlocked entitlement.
  /// Always true for locally-imported chapters.
  final bool isFree;

  factory ChapterRef.fromJson(Map<String, dynamic> json) => ChapterRef(
        index: json['index'] as int,
        title: json['title'] as String,
        fileName: json['fileName'] as String,
        charCount: json['charCount'] as int? ?? 0,
        remoteChapterId: json['remoteChapterId'] as String?,
        isFree: json['isFree'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'fileName': fileName,
        'charCount': charCount,
        if (remoteChapterId != null) 'remoteChapterId': remoteChapterId,
        'isFree': isFree,
      };
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.importedAt,
    required this.chapters,
    this.remoteId,
  });

  final String id;
  final String title;
  final String author;
  final DateTime importedAt;
  final List<ChapterRef> chapters;

  /// Server-side book id when this book's chapters are fetched from the
  /// remote catalog rather than a local .txt/.epub import. Null for a
  /// locally-imported book — [id] (the on-disk folder name) is used either
  /// way and is independent of this.
  final String? remoteId;

  bool get isRemote => remoteId != null;

  int get chapterCount => chapters.length;

  int get totalChars =>
      chapters.fold<int>(0, (sum, c) => sum + c.charCount);

  Book copyWith({String? title, String? author}) => Book(
        id: id,
        title: title ?? this.title,
        author: author ?? this.author,
        importedAt: importedAt,
        chapters: chapters,
        remoteId: remoteId,
      );

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String? ?? '',
        importedAt: DateTime.parse(json['importedAt'] as String),
        chapters: (json['chapters'] as List<dynamic>)
            .map((e) => ChapterRef.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        remoteId: json['remoteId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'importedAt': importedAt.toIso8601String(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
        if (remoteId != null) 'remoteId': remoteId,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}
