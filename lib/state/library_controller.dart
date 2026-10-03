import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/library_repository.dart';
import '../services/remote_book_service.dart';
import '../services/settings_store.dart';

/// The home screen's three sections: books being read (from this device's
/// library), and the server's featured and newest books.
class LibraryController extends ChangeNotifier {
  LibraryController(this._repo, this._settings, this._remote);

  final LibraryRepository _repo;
  final SettingsStore _settings;
  final RemoteBookService _remote;

  List<Book> _books = const [];
  bool _loadingLibrary = true;

  List<RemoteBookSummary> _featured = const [];
  final List<RemoteBookSummary> _newBooks = [];
  String? _newCursor;
  bool _loadingRemote = true;
  bool _loadingMoreNew = false;
  String? _remoteError;

  bool get loading => _loadingLibrary || _loadingRemote;
  String? get remoteError => _remoteError;
  List<RemoteBookSummary> get featured => _featured;
  List<RemoteBookSummary> get newBooks => _newBooks;
  bool get hasMoreNew => _newCursor != null;
  bool get loadingMoreNew => _loadingMoreNew;

  /// Server books with a saved reading position, most recently read first.
  /// Earlier versions could add the same server book more than once; only
  /// the copy read last shows. Books imported from local files by earlier
  /// versions are left out — everything now comes from the server.
  List<Book> get continueReading {
    final latest = <String, (Book, ReadingProgress)>{};
    for (final book in _books) {
      final remoteId = book.remoteId;
      final progress = _settings.progressFor(book.id);
      if (remoteId == null || progress == null) continue;
      final current = latest[remoteId];
      if (current == null || progress.updatedAt.isAfter(current.$2.updatedAt)) {
        latest[remoteId] = (book, progress);
      }
    }
    final entries = latest.values.toList()
      ..sort((a, b) => b.$2.updatedAt.compareTo(a.$2.updatedAt));
    return [for (final (book, _) in entries) book];
  }

  /// Everything: this device's library and both server lists.
  Future<void> refresh() async {
    await Future.wait([refreshLibrary(), _refreshRemote()]);
    await _syncCovers();
  }

  /// Server book ids whose details were fetched by [_syncCovers] this run.
  final Set<String> _coverChecked = {};

  /// Brings the covers of the books in "Đọc tiếp" up to date. Those come
  /// from book.json, written when a book was added and otherwise only
  /// refreshed by opening it — so a cover set on the server later never
  /// showed up there. Books in the server lists just loaded take their
  /// cover from there; others still without one get their details fetched,
  /// once per run (the endpoint is rate-limited).
  Future<void> _syncCovers() async {
    final listed = {
      for (final b in [..._featured, ..._newBooks]) b.id: b.coverUrl,
    };
    var changed = false;
    for (final book in continueReading) {
      final remoteId = book.remoteId!;
      Book? updated;
      if (listed.containsKey(remoteId)) {
        final url = listed[remoteId];
        if (url == book.coverUrl) continue;
        updated = await _repo.saveBook(book.withCover(url));
      } else {
        if (book.coverUrl != null || !_coverChecked.add(remoteId)) continue;
        try {
          updated = await _repo.refreshAudioAvailability(book);
        } on Object {
          continue; // Offline or rate-limited: try again next run.
        }
        if (updated.coverUrl == null) continue;
      }
      final done = updated;
      _books = [for (final b in _books) b.id == done.id ? done : b];
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Just this device's library — after closing the reader, when only the
  /// reading position can have changed.
  Future<void> refreshLibrary() async {
    try {
      _books = await _repo.loadBooks();
    } on Object {
      // A broken library folder only hides "Đọc tiếp"; the server lists
      // still work.
      _books = const [];
    }
    _loadingLibrary = false;
    notifyListeners();
  }

  Future<void> _refreshRemote() async {
    _loadingRemote = true;
    notifyListeners();
    try {
      final (featured, firstPage) = await (
        _remote.fetchFeaturedBooks(),
        _remote.fetchNewBooks(),
      ).wait;
      _featured = featured;
      _newBooks
        ..clear()
        ..addAll(firstPage.items);
      _newCursor = firstPage.nextCursor;
      _remoteError = null;
    } on Object catch (e) {
      _remoteError = 'Không tải được danh sách truyện: $e';
    }
    _loadingRemote = false;
    notifyListeners();
  }

  /// Next page of "Truyện mới", when the list is scrolled near its end.
  Future<void> loadMoreNew() async {
    final cursor = _newCursor;
    if (cursor == null || _loadingMoreNew || _loadingRemote) return;
    _loadingMoreNew = true;
    notifyListeners();
    try {
      final page = await _remote.fetchNewBooks(cursor: cursor);
      _newBooks.addAll(page.items);
      _newCursor = page.nextCursor;
    } on Object {
      // Leave the cursor as is; scrolling to the end again retries.
    }
    _loadingMoreNew = false;
    notifyListeners();
  }

  /// The library's copy of a server book — the one read last, if it was
  /// added more than once — adding it first if it isn't there yet.
  Future<Book> bookFor(RemoteBookSummary summary) async {
    final copies = _books.where((b) => b.remoteId == summary.id).toList();
    if (copies.isNotEmpty) {
      return continueReading.firstWhere(
        (b) => b.remoteId == summary.id,
        orElse: () => copies.first,
      );
    }
    final meta = await _remote.fetchBookMeta(summary.id);
    final book = await _repo.importFromRemote(meta);
    _books = [book, ..._books];
    notifyListeners();
    return book;
  }

  ReadingProgress? progressFor(String bookId) => _settings.progressFor(bookId);

  /// Percentage read, by chapter. Good enough for a progress bar and costs
  /// nothing to compute.
  double progressFraction(Book book) {
    final p = _settings.progressFor(book.id);
    if (p == null || book.chapterCount == 0) return 0;
    return (p.chapterIndex / book.chapterCount).clamp(0.0, 1.0);
  }

  /// Drops every copy of [book] from this device, with its reading position.
  /// The server keeps its own copy of the position for a signed-in reader.
  Future<void> removeFromContinueReading(Book book) async {
    final copies = _books.where((b) => b.remoteId == book.remoteId).toList();
    for (final copy in copies) {
      await _repo.deleteBook(copy);
      await _settings.clearProgress(copy.id);
    }
    _books = _books.where((b) => b.remoteId != book.remoteId).toList();
    notifyListeners();
  }

  /// Back to the first chapter, keeping the book in "Đọc tiếp".
  Future<void> restart(Book book) async {
    await _settings.saveProgress(ReadingProgress(
      bookId: book.id,
      chapterIndex: 0,
      sentenceIndex: 0,
      updatedAt: DateTime.now(),
    ));
    notifyListeners();
  }
}
