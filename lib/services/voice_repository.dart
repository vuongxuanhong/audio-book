import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/voice.dart';

class DownloadProgress {
  const DownloadProgress(this.phase, this.received, this.total);
  final String phase;
  final int received;
  final int total;

  double? get fraction => total > 0 ? received / total : null;
}

/// Downloads sherpa-onnx voice packs and unpacks them into app support, then
/// locates the three paths the engine needs (`*.onnx`, `tokens.txt`,
/// `espeak-ng-data/`) by scanning — the layout differs slightly per model.
class VoiceRepository {
  Directory? _root;

  /// espeak-ng stores its data directory in a fixed 230-byte buffer and, when
  /// the path does not fit, quietly falls back to `/usr/share/espeak-ng-data`
  /// and then aborts the process. The iOS container prefix is ~170 characters
  /// on a simulator, so the layout below is kept as flat and short as it can
  /// be: `<Library>/v/<slot>/espeak-ng-data`.
  static const int _maxDataDirChars = 210;

  /// The release host occasionally accepts the connection and then goes quiet.
  static const _headerTimeout = Duration(seconds: 30);
  static const _stallTimeout = Duration(seconds: 45);

  Future<Directory> _voicesDir() async {
    if (_root != null) return _root!;
    // `Library` is two path segments shorter than `Library/Application
    // Support`, which matters for the espeak path budget above.
    final base = (Platform.isIOS || Platform.isMacOS)
        ? await getLibraryDirectory()
        : await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/v');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await _removeLegacyLayout(base);
    return _root = dir;
  }

  /// Earlier builds unpacked into `<Application Support>/voices/<long id>/…`,
  /// which is too deep for espeak. Drop it so the voice is re-downloaded into
  /// the short layout.
  Future<void> _removeLegacyLayout(Directory base) async {
    for (final path in [
      '${base.path}/voices',
      '${(await getApplicationSupportDirectory()).path}/voices',
    ]) {
      final legacy = Directory(path);
      if (legacy.existsSync()) legacy.deleteSync(recursive: true);
    }
  }

  Directory _dirFor(Directory root, VoiceCatalogEntry entry) =>
      Directory('${root.path}/${entry.slot}');

  Future<List<InstalledVoice>> installedVoices() async {
    final dir = await _voicesDir();
    final voices = <InstalledVoice>[];
    for (final entry in kVoiceCatalog) {
      final target = _dirFor(dir, entry);
      if (!target.existsSync()) continue;
      final voice = _resolve(entry, target);
      if (voice != null) voices.add(voice);
    }
    return voices;
  }

  Future<InstalledVoice?> installed(String voiceId) async {
    final all = await installedVoices();
    for (final v in all) {
      if (v.id == voiceId) return v;
    }
    return null;
  }

  Future<InstalledVoice> download(
    VoiceCatalogEntry entry, {
    required void Function(DownloadProgress) onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _voicesDir();
    final target = _dirFor(dir, entry);
    if (target.existsSync()) target.deleteSync(recursive: true);

    final archivePath = '${dir.path}/${entry.slot}.tar.bz2';
    final archiveFile = File(archivePath);
    if (archiveFile.existsSync()) archiveFile.deleteSync();

    onProgress(DownloadProgress('Đang tải', 0, entry.downloadBytes));

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(entry.url));
      final response = await client.send(request).timeout(
            _headerTimeout,
            onTimeout: () => throw const VoiceDownloadStalled(),
          );
      if (response.statusCode != 200) {
        throw Exception('Tải thất bại (HTTP ${response.statusCode})');
      }
      final total = response.contentLength ?? entry.downloadBytes;
      final sink = archiveFile.openWrite();
      var received = 0;
      // A download that simply stops producing bytes must surface as an error
      // the user can retry, not as a progress bar frozen at 0%.
      final stream = response.stream.timeout(
        _stallTimeout,
        onTimeout: (sink) => sink.addError(const VoiceDownloadStalled()),
      );
      await for (final chunk in stream) {
        if (cancelToken?.isCancelled ?? false) {
          await sink.close();
          archiveFile.deleteSync();
          throw const VoiceDownloadCancelled();
        }
        received += chunk.length;
        sink.add(chunk);
        onProgress(DownloadProgress('Đang tải', received, total));
      }
      await sink.flush();
      await sink.close();
    } on Object {
      if (archiveFile.existsSync()) archiveFile.deleteSync();
      rethrow;
    } finally {
      client.close();
    }

    onProgress(DownloadProgress('Đang giải nén', 0, 0));
    // bzip2 of a 20–60 MB pack pins a core for several seconds; keep it off
    // the UI isolate.
    await compute(_extractArchive, _ExtractArgs(archivePath, target.path));
    archiveFile.deleteSync();

    final voice = _resolve(entry, target);
    if (voice == null) {
      target.deleteSync(recursive: true);
      throw Exception('Gói giọng đọc thiếu tệp model hoặc tokens.txt');
    }
    return voice;
  }

  Future<void> remove(VoiceCatalogEntry entry) async {
    final target = _dirFor(await _voicesDir(), entry);
    if (target.existsSync()) target.deleteSync(recursive: true);
  }

  Future<int> sizeOnDisk(VoiceCatalogEntry entry) async {
    final dir = _dirFor(await _voicesDir(), entry);
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      total += f.lengthSync();
    }
    return total;
  }

  InstalledVoice? _resolve(VoiceCatalogEntry entry, Directory dir) {
    File? model;
    File? tokens;
    Directory? dataDir;

    for (final e in dir.listSync(recursive: true)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is File && name.endsWith('.onnx')) {
        // Prefer the quantised weights when a pack ships both.
        if (model == null || name.contains('int8')) model = e;
      } else if (e is File && name == 'tokens.txt') {
        tokens = e;
      } else if (e is Directory && name == 'espeak-ng-data') {
        dataDir = e;
      }
    }

    if (model == null || tokens == null) return null;
    if (dataDir != null && dataDir.path.length > _maxDataDirChars) {
      throw VoicePathTooLong(dataDir.path);
    }
    return InstalledVoice(
      id: entry.id,
      name: entry.name,
      modelPath: model.path,
      tokensPath: tokens.path,
      dataDir: dataDir?.path ?? '',
      numSpeakers: _speakerCount(model),
    );
  }

  /// Piper packs describe themselves in `<model>.onnx.json`; reading it beats
  /// loading the model just to call `numSpeakers`.
  int _speakerCount(File model) {
    final meta = File('${model.path}.json');
    if (!meta.existsSync()) return 1;
    try {
      final json = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      final n = json['num_speakers'];
      return n is int && n > 0 ? n : 1;
    } on Object {
      return 1;
    }
  }
}

/// espeak-ng cannot be told about a path this long; surface it as a real
/// error instead of letting the native layer abort the process.
class VoicePathTooLong implements Exception {
  const VoicePathTooLong(this.path);
  final String path;
  @override
  String toString() =>
      'Đường dẫn giọng đọc quá dài (${path.length} ký tự) nên espeak-ng không '
      'nạp được dữ liệu. Hãy cài lại ứng dụng ở thư mục ngắn hơn.';
}

/// The server stopped sending. Distinct from a refusal so the UI can suggest
/// simply trying again.
class VoiceDownloadStalled implements Exception {
  const VoiceDownloadStalled();
  @override
  String toString() =>
      'Mạng không phản hồi khi đang tải. Kiểm tra kết nối rồi thử lại.';
}

class VoiceDownloadCancelled implements Exception {
  const VoiceDownloadCancelled();
  @override
  String toString() => 'Đã huỷ tải giọng đọc';
}

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _ExtractArgs {
  const _ExtractArgs(this.archivePath, this.targetPath);
  final String archivePath;
  final String targetPath;
}

Future<void> _extractArchive(_ExtractArgs args) async {
  final tarPath = '${args.archivePath}.tar';
  final input = InputFileStream(args.archivePath);
  final output = OutputFileStream(tarPath);
  try {
    BZip2Decoder().decodeStream(input, output);
  } finally {
    await input.close();
    await output.close();
  }

  final tarInput = InputFileStream(tarPath);
  try {
    final archive = TarDecoder().decodeStream(tarInput);
    await extractArchiveToDisk(archive, args.targetPath);
  } finally {
    await tarInput.close();
    File(tarPath).deleteSync();
  }

  _flattenSingleRoot(Directory(args.targetPath));
}

/// The packs unpack into a single top-level folder named after the model.
/// Hoisting its contents saves ~40 characters of path, which the espeak data
/// path budget needs.
void _flattenSingleRoot(Directory target) {
  final entries = target.listSync();
  if (entries.length != 1) return;
  final root = entries.first;
  if (root is! Directory) return;

  for (final child in root.listSync()) {
    final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
    child.renameSync('${target.path}/$name');
  }
  root.deleteSync(recursive: true);
}
