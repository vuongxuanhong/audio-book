import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import '../services/library_repository.dart';
import '../services/settings_store.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(this._repo, this._settings);

  final LibraryRepository _repo;
  final SettingsStore _settings;

  List<Book> _books = const [];
  bool _loading = true;
  String? _error;

  List<Book> get books => _books;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      _books = await _repo.loadBooks();
      _error = null;
    } on Object catch (e) {
      _error = e.toString();
    }
    _loading = false;
    notifyListeners();
  }

  ReadingProgress? progressFor(String bookId) => _settings.progressFor(bookId);

  /// Percentage read, based on the sentence index within the whole book. Good
  /// enough for a progress bar and costs nothing to compute.
  double progressFraction(Book book) {
    final p = _settings.progressFor(book.id);
    if (p == null || book.chapterCount == 0) return 0;
    final chapters = book.chapterCount;
    return ((p.chapterIndex) / chapters).clamp(0.0, 1.0);
  }

  Future<Book> importFile(File file) async {
    final book = await _repo.importFile(file);
    _books = [book, ..._books];
    notifyListeners();
    return book;
  }

  Future<Book> importText(String text, String title) async {
    final book = await _repo.importText(rawText: text, fallbackTitle: title);
    _books = [book, ..._books];
    notifyListeners();
    return book;
  }

  Future<void> delete(Book book) async {
    await _repo.deleteBook(book);
    await _settings.clearProgress(book.id);
    _books = _books.where((b) => b.id != book.id).toList();
    notifyListeners();
  }

  Future<void> rename(Book book, String title) async {
    await _repo.rename(book, title);
    _books = [
      for (final b in _books) b.id == book.id ? b.copyWith(title: title) : b,
    ];
    notifyListeners();
  }

  Future<void> resetProgress(Book book) async {
    await _settings.clearProgress(book.id);
    notifyListeners();
  }
}
