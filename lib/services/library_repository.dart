import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/chapter_audio.dart';
import '../models/reading_progress.dart';
import 'progress_sync.dart';
import 'remote_book_service.dart';

/// Books from the server, kept under `<documents>/books/<bookId>/`:
/// `book.json` for the metadata and one file per chapter that has been read,
/// so a 5 MB novel never has to be held in memory all at once.
///
/// Chapter files hold AES-GCM-encrypted bytes rather than plain text (see
/// [_cacheEncrypted]/[_readCache]) — caching a downloaded chapter as plain
/// text would undo everything the backend's auth/entitlement checks are for
/// the moment it lands on disk. Books imported from .txt/.epub files by
/// earlier versions of the app are still readable from their plain files.
class LibraryRepository {
  LibraryRepository({
    RemoteBookService? remote,
    ProgressSync? sync,
    FlutterSecureStorage? secureStorage,
  })  : _remote = remote,
        _sync = sync,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final RemoteBookService? _remote;
  final ProgressSync? _sync;
  final FlutterSecureStorage _secureStorage;

  Directory? _root;
  SecretKey? _cacheKey;

  /// Last chapter response per remote chapter id, reused while its signed
  /// audio URL is still fresh — seeking around or pausing and resuming must
  /// not cost a rate-limited API call each time.
  final Map<String, RemoteChapterContent> _remoteChapters = {};

  Future<Directory> _booksDir() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/books');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _root = dir;
  }

  Future<List<Book>> loadBooks() async {
    final dir = await _booksDir();
    final books = <Book>[];
    for (final entity in dir.listSync().whereType<Directory>()) {
      final meta = File('${entity.path}/book.json');
      if (!meta.existsSync()) continue;
      try {
        books.add(
          Book.fromJson(jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>),
        );
      } on Object {
        // A half-written import should not take the whole library down.
        continue;
      }
    }
    books.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return books;
  }

  /// Registers a book from the remote catalog in the local library, before
  /// any chapter content has actually been downloaded.
  Future<Book> importFromRemote(RemoteBookMeta meta) async {
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final dir = Directory('${(await _booksDir()).path}/$id');
    dir.createSync(recursive: true);

    final chapters = [
      for (final c in meta.chapters)
        ChapterRef(
          index: c.index,
          title: c.title,
          fileName: 'ch_${c.index.toString().padLeft(4, '0')}.enc',
          charCount: c.charCount,
          remoteChapterId: c.id,
          isFree: c.isFree,
          hasAudio: c.hasAudio,
        ),
    ];

    final book = Book(
      id: id,
      title: meta.title,
      author: meta.author,
      importedAt: DateTime.now(),
      chapters: chapters,
      remoteId: meta.id,
      coverUrl: meta.coverUrl,
    );
    File('${dir.path}/book.json').writeAsStringSync(book.encode());
    return book;
  }

  /// Re-reads what may have changed on the server since the book was added —
  /// which chapters have narration (audio gets attached later) and the
  /// cover — and saves the result. Throws when the book detail can't be
  /// fetched.
  Future<Book> refreshAudioAvailability(Book book) async {
    final remote = _remote;
    if (remote == null || !book.isRemote) return book;
    final meta = await remote.fetchBookMeta(book.remoteId!);
    final hasAudio = {for (final c in meta.chapters) c.id: c.hasAudio};
    return saveBook(book.copyWith(chapters: [
      for (final c in book.chapters)
        c.copyWith(hasAudio: hasAudio[c.remoteChapterId]),
    ]).withCover(meta.coverUrl));
  }

  Future<Book> saveBook(Book book) async {
    final dir = Directory('${(await _booksDir()).path}/${book.id}');
    if (dir.existsSync()) {
      File('${dir.path}/book.json').writeAsStringSync(book.encode());
    }
    return book;
  }

  Future<String> loadChapterText(Book book, int chapterIndex) async {
    final ref = book.chapters[chapterIndex];
    final dir = await _booksDir();
    final file = File('${dir.path}/${book.id}/${ref.fileName}');

    if (ref.remoteChapterId == null) {
      return file.readAsString();
    }

    if (file.existsSync()) {
      return _readCache(file);
    }

    final remote = _remote;
    if (remote == null) {
      throw StateError('No remote service configured for a remote book');
    }
    return (await fetchRemoteChapter(book, chapterIndex)).content;
  }

  /// A remote chapter straight from the API: its text plus, if it has been
  /// narrated, a signed audio URL and the highlight timeline for that text.
  /// Also refreshes the on-disk text cache, so the text on screen and the
  /// timeline's offsets always come from the same response.
  ///
  /// Throws [LoginRequiredException] / [EntitlementRequiredException] for a
  /// locked chapter, like [loadChapterText].
  Future<RemoteChapterContent> fetchRemoteChapter(
    Book book,
    int chapterIndex, {
    bool forceRefresh = false,
  }) async {
    final ref = book.chapters[chapterIndex];
    final chapterId = ref.remoteChapterId;
    final remote = _remote;
    if (chapterId == null || remote == null) {
      throw StateError('No remote service configured for a remote book');
    }

    final cached = _remoteChapters[chapterId];
    if (!forceRefresh && cached != null && cached.audio?.isFresh() == true) {
      return cached;
    }

    final fresh = await remote.fetchChapter(book.remoteId!, chapterId);
    _remoteChapters[chapterId] = fresh;
    final dir = await _booksDir();
    await _cacheEncrypted(File('${dir.path}/${book.id}/${ref.fileName}'), fresh.content);
    return fresh;
  }

  /// Queues the reading position of a remote book for the server (see
  /// [ProgressSync]), so it can be picked up on another signed-in device.
  /// Does nothing for a local book or when there's no sync wired up.
  void queueRemoteProgress(Book book, int chapterIndex, int position, DateTime updatedAt) {
    final sync = _sync;
    final chapterId = book.chapters[chapterIndex].remoteChapterId;
    if (sync == null || !book.isRemote || chapterId == null) return;
    sync.record(
      remoteBookId: book.remoteId!,
      chapterId: chapterId,
      position: position,
      updatedAt: updatedAt,
    );
  }

  /// Sends queued positions now — when the reader closes a book.
  Future<void> flushRemoteProgress() async => _sync?.flush();

  /// Returns the server's saved progress for a remote book, mapped to a
  /// local chapter index, or null if there's none / this isn't a remote book
  /// / the call fails for any reason (not signed in, offline, ...).
  Future<ReadingProgress?> fetchRemoteProgress(Book book) async {
    final remote = _remote;
    if (remote == null || !book.isRemote) return null;
    try {
      final result = await remote.fetchProgress(book.remoteId!);
      if (result == null) return null;
      final chapterIndex = book.chapters
          .indexWhere((c) => c.remoteChapterId == result.chapterId);
      if (chapterIndex == -1) return null;
      return ReadingProgress(
        bookId: book.id,
        chapterIndex: chapterIndex,
        sentenceIndex: result.position,
        updatedAt: result.updatedAt,
      );
    } on Object {
      return null;
    }
  }

  Future<void> deleteBook(Book book) async {
    final dir = Directory('${(await _booksDir()).path}/${book.id}');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  static const _kCacheKeyStorageKey = 'remote.chapterCacheKey';

  Future<SecretKey> _getCacheKey() async {
    final existing = _cacheKey;
    if (existing != null) return existing;

    final algorithm = AesGcm.with256bits();
    final stored = await _secureStorage.read(key: _kCacheKeyStorageKey);
    if (stored != null) {
      final key = SecretKey(base64Decode(stored));
      _cacheKey = key;
      return key;
    }

    final key = await algorithm.newSecretKey();
    final bytes = await key.extractBytes();
    await _secureStorage.write(key: _kCacheKeyStorageKey, value: base64Encode(bytes));
    _cacheKey = key;
    return key;
  }

  Future<void> _cacheEncrypted(File file, String text) async {
    final key = await _getCacheKey();
    final box = await AesGcm.with256bits().encrypt(utf8.encode(text), secretKey: key);
    await file.writeAsBytes(box.concatenation());
  }

  Future<String> _readCache(File file) async {
    final key = await _getCacheKey();
    final bytes = await file.readAsBytes();
    final box = SecretBox.fromConcatenation(
      Uint8List.fromList(bytes),
      nonceLength: 12,
      macLength: 16,
    );
    final plain = await AesGcm.with256bits().decrypt(box, secretKey: key);
    return utf8.decode(plain);
  }
}
