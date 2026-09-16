import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import 'epub_importer.dart';
import 'remote_book_service.dart';
import 'text_parser.dart';

/// Books live as plain files under `<documents>/books/<bookId>/`:
/// `book.json` for the metadata and `ch_0001.txt` … for the chapter bodies.
/// Keeping chapters in separate files means a 5 MB novel never has to be held
/// in memory all at once.
///
/// A book fetched from the remote catalog ([Book.isRemote]) uses the same
/// `book.json` shape and the same `loadChapterText` call, but its chapter
/// files hold AES-GCM-encrypted bytes rather than plain text (see
/// [_cacheEncrypted]/[_readCache]) — caching a downloaded chapter as plain
/// `.txt`, the way a local import is stored, would undo everything the
/// backend's auth/entitlement checks are for the moment it lands on disk.
class LibraryRepository {
  LibraryRepository({RemoteBookService? remote, FlutterSecureStorage? secureStorage})
      : _remote = remote,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final RemoteBookService? _remote;
  final FlutterSecureStorage _secureStorage;

  Directory? _root;
  SecretKey? _cacheKey;

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

  Future<Book> importText({
    required String rawText,
    required String fallbackTitle,
  }) async {
    final parsed = parseRawText(rawText, fallbackTitle: fallbackTitle);
    return _saveParsedBook(parsed);
  }

  Future<Book> importFile(File file) async {
    final name = file.uri.pathSegments.last;
    final fallbackTitle = name.replaceAll(RegExp(r'\.\w+$'), '');
    final parsed = name.toLowerCase().endsWith('.epub')
        ? parseEpub(await file.readAsBytes(), fallbackTitle: fallbackTitle)
        : parseRawText(await _readAsText(file), fallbackTitle: fallbackTitle);
    return _saveParsedBook(parsed);
  }

  /// Registers a book from the remote catalog in the local library — it
  /// shows up in Tủ sách immediately, same as a local import, before any
  /// chapter content has actually been downloaded.
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
        ),
    ];

    final book = Book(
      id: id,
      title: meta.title,
      author: meta.author,
      importedAt: DateTime.now(),
      chapters: chapters,
      remoteId: meta.id,
    );
    File('${dir.path}/book.json').writeAsStringSync(book.encode());
    return book;
  }

  Future<Book> _saveParsedBook(ParsedBook parsed) async {
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final dir = Directory('${(await _booksDir()).path}/$id');
    dir.createSync(recursive: true);

    final chapters = <ChapterRef>[];
    for (var i = 0; i < parsed.chapters.length; i++) {
      final chapter = parsed.chapters[i];
      final fileName = 'ch_${i.toString().padLeft(4, '0')}.txt';
      File('${dir.path}/$fileName').writeAsStringSync(chapter.text);
      chapters.add(ChapterRef(
        index: i,
        title: chapter.title,
        fileName: fileName,
        charCount: chapter.text.length,
      ));
    }

    final book = Book(
      id: id,
      title: parsed.title,
      author: parsed.author,
      importedAt: DateTime.now(),
      chapters: chapters,
    );
    File('${dir.path}/book.json').writeAsStringSync(book.encode());
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
    final text = await remote.fetchChapterText(book.remoteId!, ref.remoteChapterId!);
    await _cacheEncrypted(file, text);
    return text;
  }

  /// Best-effort: push the reading position for a remote book up to the
  /// server so it can be picked up on another signed-in device. Silently
  /// does nothing for a local book, when there's no remote service wired up,
  /// or when the push fails (e.g. not signed in, offline) — losing a live
  /// sync update must never interrupt reading.
  Future<void> pushRemoteProgress(Book book, int chapterIndex, int position) async {
    final remote = _remote;
    if (remote == null || !book.isRemote) return;
    final chapterId = book.chapters[chapterIndex].remoteChapterId;
    if (chapterId == null) return;
    try {
      await remote.pushProgress(book.remoteId!, chapterId, position);
    } on Object {
      // Best-effort — the local SettingsStore copy is the source of truth
      // for this device regardless.
    }
  }

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

  /// Most Vietnamese novel dumps are UTF-8, but some are still Windows-1258 or
  /// Latin-1. Fall back rather than throwing on a bad byte.
  Future<String> _readAsText(File file) async {
    final bytes = await file.readAsBytes();
    try {
      return const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      return const Latin1Decoder(allowInvalid: true).convert(bytes);
    }
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
