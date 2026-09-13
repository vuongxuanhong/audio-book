import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import 'epub_importer.dart';
import 'text_parser.dart';

/// Books live as plain files under `<documents>/books/<bookId>/`:
/// `book.json` for the metadata and `ch_0001.txt` … for the chapter bodies.
/// Keeping chapters in separate files means a 5 MB novel never has to be held
/// in memory all at once.
class LibraryRepository {
  Directory? _root;

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
    final dir = await _booksDir();
    final ref = book.chapters[chapterIndex];
    return File('${dir.path}/${book.id}/${ref.fileName}').readAsString();
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
}
