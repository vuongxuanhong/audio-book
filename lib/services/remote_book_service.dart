import 'package:dio/dio.dart';

import '../models/chapter_audio.dart';
import 'api_client.dart';

class RemoteChapterRef {
  const RemoteChapterRef({
    required this.id,
    required this.index,
    required this.title,
    required this.charCount,
    required this.isFree,
    required this.hasAudio,
  });

  final String id;
  final int index;
  final String title;
  final int charCount;
  final bool isFree;

  /// The book detail lists audio metadata for every narrated chapter, locked
  /// or not; only the signed URL is withheld from callers who can't play it.
  final bool hasAudio;

  factory RemoteChapterRef.fromJson(Map<String, dynamic> json) => RemoteChapterRef(
        id: json['id'] as String,
        index: json['index'] as int,
        title: json['title'] as String,
        charCount: json['char_count'] as int,
        isFree: json['is_free'] as bool,
        hasAudio: json['audio'] != null,
      );
}

class RemoteBookSummary {
  const RemoteBookSummary({
    required this.id,
    required this.title,
    required this.author,
    required this.chapterCount,
    required this.totalChars,
    this.totalDurationMs = 0,
  });

  final String id;
  final String title;
  final String author;
  final int chapterCount;
  final int totalChars;

  /// Total narration across chapters; 0 when nothing has been narrated.
  final int totalDurationMs;

  bool get hasAudio => totalDurationMs > 0;

  factory RemoteBookSummary.fromJson(Map<String, dynamic> json) => RemoteBookSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String,
        chapterCount: json['chapter_count'] as int,
        totalChars: json['total_chars'] as int,
        totalDurationMs: json['total_duration_ms'] as int? ?? 0,
      );
}

class RemoteCatalogPage {
  const RemoteCatalogPage({required this.items, required this.nextCursor});

  final List<RemoteBookSummary> items;
  final String? nextCursor;
}

class RemoteBookMeta {
  const RemoteBookMeta({
    required this.id,
    required this.title,
    required this.author,
    required this.chapters,
  });

  final String id;
  final String title;
  final String author;
  final List<RemoteChapterRef> chapters;

  factory RemoteBookMeta.fromJson(Map<String, dynamic> json) => RemoteBookMeta(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String,
        chapters: (json['chapters'] as List<dynamic>)
            .map((e) => RemoteChapterRef.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// A chapter is locked and the device hasn't linked to a user yet — the
/// caller should prompt for Google/Apple sign-in.
class LoginRequiredException implements Exception {}

/// A chapter is locked and the signed-in user has no entitlement covering
/// this book — the caller should point the reader at how to unlock it.
class EntitlementRequiredException implements Exception {}

class RemoteBookService {
  RemoteBookService(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// One page of published books, most recently added first. A cursor only
  /// continues the listing it came from.
  Future<RemoteCatalogPage> fetchNewBooks({String? cursor}) =>
      _fetchCatalog({'sort': 'new', 'cursor': ?cursor});

  /// The books an admin has featured, in their chosen order — one page.
  Future<List<RemoteBookSummary>> fetchFeaturedBooks() async =>
      (await _fetchCatalog({'featured': true})).items;

  Future<RemoteCatalogPage> _fetchCatalog(Map<String, Object> query) async {
    final response = await _dio.get('/v1/books', queryParameters: query);
    final body = response.data as Map<String, dynamic>;
    return RemoteCatalogPage(
      items: (body['items'] as List<dynamic>)
          .map((e) => RemoteBookSummary.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      nextCursor: body['next_cursor'] as String?,
    );
  }

  Future<RemoteBookMeta> fetchBookMeta(String bookId) async {
    final response = await _dio.get('/v1/books/$bookId');
    return RemoteBookMeta.fromJson(response.data as Map<String, dynamic>);
  }

  /// The chapter's text plus, when it has narration, a freshly signed audio
  /// URL and its highlight timeline — also what to call again once that URL
  /// has expired.
  Future<RemoteChapterContent> fetchChapter(String bookId, String chapterId) async {
    try {
      final response = await _dio.get('/v1/books/$bookId/chapters/$chapterId');
      final body = response.data as Map<String, dynamic>;
      return RemoteChapterContent(
        content: body['content'] as String,
        audio: ChapterAudio.tryParse(body['audio'] as Map<String, dynamic>?),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) throw LoginRequiredException();
      if (status == 403) throw EntitlementRequiredException();
      rethrow;
    }
  }

  /// Saves the signed-in user's position. [updatedAt] is when the reader was
  /// there, which lets the server ignore it if a newer one is already saved —
  /// see ProgressSync, which sends these late and in batches.
  Future<void> pushProgress(
    String bookId,
    String chapterId,
    int position, {
    required DateTime updatedAt,
  }) async {
    await _dio.put(
      '/v1/me/progress/$bookId',
      data: {
        'chapter_id': chapterId,
        'position': position,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      },
    );
  }

  /// Returns null if the signed-in user has no saved progress for this book,
  /// or if the caller isn't signed in. [updatedAt] is the server's own
  /// timestamp for the saved position — callers reconcile it against a
  /// locally-saved position's own timestamp, so this must be the server's
  /// value rather than e.g. the time of this call.
  Future<({String chapterId, int position, DateTime updatedAt})?> fetchProgress(
    String bookId,
  ) async {
    try {
      final response = await _dio.get('/v1/me/progress/$bookId');
      final body = response.data as Map<String, dynamic>;
      return (
        chapterId: body['chapter_id'] as String,
        position: body['position'] as int,
        updatedAt: DateTime.parse(body['updated_at'] as String),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404 || status == 401) return null;
      rethrow;
    }
  }
}
