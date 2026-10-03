import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chapter_audio.dart';

/// Chapter audio kept on disk, so a chapter heard before (or fetched ahead
/// of time) plays from a file instead of the network.
///
/// - Files are whole chapters, named after the audio's key on the server
///   ([ChapterAudio.cacheKey]), not its signed URL: the signature changes
///   every few minutes, the key only when the audio itself does.
/// - Downloads go to `<name>.part` and are renamed when complete, so a file
///   without that suffix is always whole. A partial one is resumed with a
///   range request next time.
/// - The total is capped at [maxBytes]; past it the chapters listened to
///   longest ago go first (a file's modified time is its last use — see
///   [touch]), except the ones marked [inUse].
class AudioCache {
  AudioCache({
    Future<Directory> Function()? directory,
    Dio? dio,
    this.maxBytes = 500 * 1024 * 1024,
  })  : _directory = directory ?? _defaultDirectory,
        // Plain client: the audio server authenticates by the URL's
        // signature, not by the API's bearer token.
        _dio = dio ?? Dio();

  final Future<Directory> Function() _directory;
  final Dio _dio;
  final int maxBytes;

  final Map<String, Future<File?>> _downloads = {};
  Set<String> _inUse = const {};
  Directory? _dir;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/audio');

  Future<Directory> _root() async {
    final dir = _dir ??= await _directory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _fileFor(ChapterAudio audio) async =>
      File('${(await _root()).path}/${fileNameFor(audio.cacheKey)}');

  /// The complete file for [audio], or null if it isn't cached (yet).
  Future<File?> cachedFile(ChapterAudio audio) async {
    final file = await _fileFor(audio);
    return file.existsSync() ? file : null;
  }

  /// Marks [audio] as just listened to, for the least-recently-used order.
  Future<void> touch(ChapterAudio audio) async {
    final file = await cachedFile(audio);
    try {
      file?.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // Only affects eviction order.
    }
  }

  /// Keys of the chapters queued for playback; never evicted.
  set inUse(Set<String> keys) => _inUse = keys;

  /// Downloads [audio] unless it's already cached or on its way. Completes
  /// with the file, or null if the download failed (offline, an expired
  /// URL) — the caller streams instead, and a later call tries again.
  Future<File?> fetch(ChapterAudio audio) {
    final key = audio.cacheKey;
    return _downloads[key] ??= _download(audio).whenComplete(() {
      _downloads.remove(key);
    });
  }

  Future<File?> _download(ChapterAudio audio) async {
    final file = await _fileFor(audio);
    if (file.existsSync()) return file;
    final part = File('${file.path}.part');
    try {
      final have = part.existsSync() ? part.lengthSync() : 0;
      final response = await _dio.getUri<ResponseBody>(
        audio.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {if (have > 0) HttpHeaders.rangeHeader: 'bytes=$have-'},
        ),
      );
      // A 200 to a range request means the server sent everything again.
      final resumed = have > 0 && response.statusCode == 206;
      final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      try {
        await sink.addStream(response.data!.stream);
      } finally {
        await sink.close();
      }
      if (audio.sizeBytes > 0 && part.lengthSync() != audio.sizeBytes) {
        // Truncated or not the file we expected: start over next time.
        part.deleteSync();
        return null;
      }
      part.renameSync(file.path);
      await _evict();
      return file;
    } on Object {
      return null;
    }
  }

  /// Deletes the least recently used chapters until the cache fits.
  Future<void> _evict() async {
    final files = (await _root())
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.endsWith('.part'))
        .toList();
    var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    if (total <= maxBytes) return;

    final protected = {for (final key in _inUse) fileNameFor(key)};
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    for (final file in files) {
      if (total <= maxBytes) break;
      if (protected.contains(file.uri.pathSegments.last)) continue;
      final size = file.lengthSync();
      try {
        file.deleteSync();
        total -= size;
      } on FileSystemException {
        // Still open somewhere; it goes next time.
      }
    }
  }

  /// A cache key (the audio URL's path, e.g. `/a/<book>/0001-<hash>.m4a`)
  /// as a flat file name.
  static String fileNameFor(String key) =>
      key.split('/').where((s) => s.isNotEmpty).join('__');
}
