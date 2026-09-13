import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audio_book/services/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// A minimal real `.epub` (2 chapters via a spine that differs from manifest
/// order), used to exercise the whole import path end-to-end: extension
/// dispatch in [LibraryRepository.importFile], EPUB parsing, and writing the
/// chapter files + `book.json` to disk.
Uint8List _sampleEpub() {
  final archive = Archive();
  void addFile(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  addFile(
    'META-INF/container.xml',
    '<?xml version="1.0"?>'
        '<container><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf"/>'
        '</rootfiles></container>',
  );
  addFile(
    'OEBPS/ch2.xhtml',
    '<html><body><h1>Chương 2</h1><p>Nội dung chương hai của truyện.</p></body></html>',
  );
  addFile(
    'OEBPS/ch1.xhtml',
    '<html><body><h1>Chương 1</h1><p>Nội dung chương một của truyện.</p></body></html>',
  );
  addFile(
    'OEBPS/content.opf',
    '<?xml version="1.0"?>'
        '<package xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<metadata><dc:title>Truyện EPUB thử</dc:title><dc:creator>Tác giả Y</dc:creator></metadata>'
        '<manifest>'
        '<item id="ch1" href="ch1.xhtml"/>'
        '<item id="ch2" href="ch2.xhtml"/>'
        '</manifest>'
        '<spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>'
        '</package>',
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);
  final Directory root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('epub_import_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('importFile parses a real .epub end-to-end and persists it to disk',
      () async {
    final epubFile = File('${tempDir.path}/sample.epub')
      ..writeAsBytesSync(_sampleEpub());

    final repo = LibraryRepository();
    final book = await repo.importFile(epubFile);

    expect(book.title, 'Truyện EPUB thử');
    expect(book.author, 'Tác giả Y');
    expect(book.chapters, hasLength(2));
    expect(book.chapters[0].title, 'Chương 1');

    final bookDir = Directory('${tempDir.path}/books/${book.id}');
    expect(bookDir.existsSync(), isTrue);
    expect(File('${bookDir.path}/book.json').existsSync(), isTrue);

    final ch1Text = await repo.loadChapterText(book, 0);
    expect(ch1Text, contains('chương một'));
    final ch2Text = await repo.loadChapterText(book, 1);
    expect(ch2Text, contains('chương hai'));

    final reloaded = await repo.loadBooks();
    expect(reloaded.map((b) => b.id), contains(book.id));
  });
}
