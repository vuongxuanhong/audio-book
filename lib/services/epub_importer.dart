import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'text_parser.dart';

const int _minChapterChars = 20;

const Set<String> _blockTags = {
  'p',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'blockquote',
  'br',
};

/// Parses an `.epub` file (just a `.zip` archive) into the same
/// [ParsedBook]/[ParsedChapter] shape a `.txt` import produces, so the rest of
/// the app never has to know which format a book came from.
ParsedBook parseEpub(Uint8List bytes, {required String fallbackTitle}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final filesByPath = <String, ArchiveFile>{
    for (final f in archive.files.where((f) => f.isFile)) f.name: f,
  };

  final containerXml = _readText(filesByPath, 'META-INF/container.xml');
  if (containerXml == null) {
    throw const FormatException('Không tìm thấy META-INF/container.xml');
  }
  final container = XmlDocument.parse(containerXml);
  final opfPath = container
      .findAllElements('rootfile')
      .first
      .getAttribute('full-path');
  if (opfPath == null) {
    throw const FormatException('Không tìm thấy đường dẫn tới file OPF');
  }

  final opfXml = _readText(filesByPath, opfPath);
  if (opfXml == null) {
    throw FormatException('Không đọc được file OPF: $opfPath');
  }
  final opf = XmlDocument.parse(opfXml);
  final opfDir = _dirOf(opfPath);

  final title = _firstText(opf, 'title') ?? fallbackTitle;
  final author = _firstText(opf, 'creator') ?? '';

  final manifest = <String, String>{
    for (final item in opf.findAllElements('item'))
      item.getAttribute('id')!: _resolve(opfDir, item.getAttribute('href')!),
  };

  final spineHrefs = opf
      .findAllElements('itemref')
      .map((itemref) => manifest[itemref.getAttribute('idref')])
      .whereType<String>()
      .toList();

  final chapters = <ParsedChapter>[];
  for (final href in spineHrefs) {
    final xhtml = _readText(filesByPath, href);
    if (xhtml == null) continue;
    final document = html_parser.parse(xhtml);
    final text = _extractText(document);
    if (text.length < _minChapterChars) continue;

    chapters.add(ParsedChapter(
      title: _chapterTitle(document, chapters.length + 1),
      text: text,
    ));
  }

  return ParsedBook(title: title, author: author, chapters: chapters);
}

/// Most EPUBs are UTF-8, but fall back rather than throwing on a bad byte.
String? _readText(Map<String, ArchiveFile> files, String path) {
  final file = files[path] ?? files[path.replaceFirst(RegExp(r'^/'), '')];
  if (file == null) return null;
  final bytes = file.content as List<int>;
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } on FormatException {
    return const Latin1Decoder(allowInvalid: true).convert(bytes);
  }
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i == -1 ? '' : path.substring(0, i);
}

/// Resolves an href relative to the OPF file's directory, collapsing any
/// `..` segments — EPUBs commonly nest their content under e.g. `OEBPS/`.
String _resolve(String baseDir, String href) {
  final combined = baseDir.isEmpty ? href : '$baseDir/$href';
  final segments = <String>[];
  for (final part in combined.split('/')) {
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else if (part.isNotEmpty && part != '.') {
      segments.add(part);
    }
  }
  return segments.join('/');
}

/// `findAllElements` matches on qualified name, but `<dc:title>` (and
/// `<dc:creator>`) always carry the `dc:` prefix in real-world EPUBs, so
/// match on the element's local name instead.
String? _firstText(XmlDocument opf, String localName) {
  final matches =
      opf.descendants.whereType<XmlElement>().where((e) => e.name.local == localName);
  if (matches.isEmpty) return null;
  final text = matches.first.innerText.trim();
  return text.isEmpty ? null : text;
}

String _chapterTitle(dom.Document document, int fallbackIndex) {
  for (final tag in ['h1', 'h2', 'title']) {
    final el = document.querySelector(tag);
    final text = el?.text.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return 'Chương $fallbackIndex';
}

/// Walks the body, putting each block-level element on its own line — this
/// matches the one-paragraph-per-line convention `parseRawText`/`segment`
/// already expect from a plain `.txt` file.
String _extractText(dom.Document document) {
  final buffer = StringBuffer();
  final body = document.body ?? document.documentElement;
  if (body != null) _walk(body, buffer);
  return buffer
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

void _walk(dom.Node node, StringBuffer buffer) {
  if (node is dom.Text) {
    buffer.write(node.text);
    return;
  }
  if (node is! dom.Element) return;

  final tag = node.localName;
  if (tag == 'script' || tag == 'style') return;

  for (final child in node.nodes) {
    _walk(child, buffer);
  }
  if (tag != null && _blockTags.contains(tag)) {
    buffer.write('\n');
  }
}
