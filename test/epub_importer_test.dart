import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audio_book/services/epub_importer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a minimal but valid in-memory EPUB: a container.xml pointing at an
/// OPF with a 2-item manifest/spine, plus the corresponding XHTML chapters.
/// The spine order deliberately differs from the manifest/zip entry order, so
/// tests catch a parser that reads chapters in file order instead of spine
/// order.
Uint8List _buildEpub({
  String title = 'Truyện thử',
  String author = 'Tác giả X',
  List<MapEntry<String, String>> chapters = const [
    MapEntry('ch2', '<html><body><h1>Chương 2</h1><p>Nội dung chương hai.</p></body></html>'),
    MapEntry('ch1', '<html><body><h1>Chương 1</h1><p>Nội dung chương một.</p></body></html>'),
  ],
  List<String> spineOrder = const ['ch1', 'ch2'],
  String? extraEmptyItemId,
}) {
  final archive = Archive();

  void addFile(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  addFile(
    'META-INF/container.xml',
    '<?xml version="1.0"?>'
        '<container><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>',
  );

  for (final entry in chapters) {
    addFile('OEBPS/${entry.key}.xhtml', entry.value);
  }
  if (extraEmptyItemId != null) {
    addFile('OEBPS/$extraEmptyItemId.xhtml', '<html><body><p>Hi</p></body></html>');
  }

  final manifestItems = [
    ...chapters.map((e) => e.key),
    ?extraEmptyItemId,
  ].map((id) => '<item id="$id" href="$id.xhtml" media-type="application/xhtml+xml"/>').join();
  final spineItems = spineOrder.map((id) => '<itemref idref="$id"/>').join();

  addFile(
    'OEBPS/content.opf',
    '<?xml version="1.0"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>$title</dc:title>'
        '<dc:creator>$author</dc:creator>'
        '</metadata>'
        '<manifest>$manifestItems</manifest>'
        '<spine>$spineItems</spine>'
        '</package>',
  );

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('parseEpub', () {
    test('reads title and author from the OPF metadata', () {
      final book = parseEpub(_buildEpub(), fallbackTitle: 'fallback');
      expect(book.title, 'Truyện thử');
      expect(book.author, 'Tác giả X');
    });

    test('orders chapters by spine, not manifest/zip order', () {
      final book = parseEpub(_buildEpub(), fallbackTitle: 'fallback');
      expect(book.chapters, hasLength(2));
      expect(book.chapters[0].text, contains('chương một'));
      expect(book.chapters[1].text, contains('chương hai'));
    });

    test('extracts plain text with one paragraph per line', () {
      final book = parseEpub(_buildEpub(), fallbackTitle: 'fallback');
      final lines = book.chapters[0].text.split('\n');
      expect(lines, contains('Chương 1'));
      expect(lines, contains('Nội dung chương một.'));
    });

    test('takes the chapter title from the first heading', () {
      final book = parseEpub(_buildEpub(), fallbackTitle: 'fallback');
      expect(book.chapters[0].title, 'Chương 1');
    });

    test('falls back to the given title when the OPF has none', () {
      final book = parseEpub(
        _buildEpub(title: '', author: ''),
        fallbackTitle: 'Tên dự phòng',
      );
      expect(book.title, 'Tên dự phòng');
    });

    test('skips near-empty spine items', () {
      final book = parseEpub(
        _buildEpub(
          chapters: [
            const MapEntry('ch1', '<html><body><h1>Chương 1</h1><p>Nội dung chương một khá dài để không bị coi là rỗng.</p></body></html>'),
            const MapEntry('blank', '<html><body><p>.</p></body></html>'),
          ],
          spineOrder: const ['ch1', 'blank'],
        ),
        fallbackTitle: 'fallback',
      );
      expect(book.chapters, hasLength(1));
      expect(book.chapters[0].text, contains('chương một'));
    });
  });
}
