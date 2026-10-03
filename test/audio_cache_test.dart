import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_book/models/chapter_audio.dart';
import 'package:audio_book/services/audio_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves [files] by URL path, honouring `Range: bytes=N-`.
class _FakeAudioServer implements HttpClientAdapter {
  _FakeAudioServer(this.files);

  final Map<String, List<int>> files;
  final requests = <RequestOptions>[];
  int? failWith;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final status = failWith;
    if (status != null) return ResponseBody.fromString('', status);
    final bytes = files[options.uri.path]!;
    final range = options.headers[HttpHeaders.rangeHeader] as String?;
    final from = range == null
        ? 0
        : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    return ResponseBody.fromBytes(
      bytes.sublist(from),
      range == null ? 200 : 206,
    );
  }

  @override
  void close({bool force = false}) {}
}

ChapterAudio _audio(String key, {int size = 0}) => ChapterAudio(
      url: Uri.parse('https://audio.example/a/$key?exp=1&sig=x'),
      urlExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      durationMs: 1000,
      mimeType: 'audio/mp4',
      timeline: const [TimelineChunk(timeMs: 0, startOffset: 0, endOffset: 1)],
      sizeBytes: size,
    );

void main() {
  late Directory dir;
  late _FakeAudioServer server;

  AudioCache cache({int maxBytes = 1 << 20}) => AudioCache(
        directory: () async => dir,
        dio: Dio()..httpClientAdapter = server,
        maxBytes: maxBytes,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('audio_cache_test');
    server = _FakeAudioServer({
      '/a/book/0001-aa.m4a': List.filled(100, 1),
      '/a/book/0002-bb.m4a': List.filled(100, 2),
      '/a/book/0003-cc.m4a': List.filled(100, 3),
    });
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('downloads a chapter once and then serves it from disk', () async {
    final c = cache();
    final audio = _audio('book/0001-aa.m4a', size: 100);
    expect(await c.cachedFile(audio), isNull);

    final file = await c.fetch(audio);
    expect(file!.readAsBytesSync(), List.filled(100, 1));
    expect((await c.cachedFile(audio))!.path, file.path);

    await c.fetch(audio);
    expect(server.requests, hasLength(1), reason: 'already on disk');
  });

  test('a signed URL that changed still finds the same file', () async {
    final c = cache();
    await c.fetch(_audio('book/0001-aa.m4a'));
    final resigned = ChapterAudio(
      url: Uri.parse('https://audio.example/a/book/0001-aa.m4a?exp=2&sig=y'),
      urlExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      durationMs: 1000,
      mimeType: 'audio/mp4',
      timeline: const [TimelineChunk(timeMs: 0, startOffset: 0, endOffset: 1)],
    );
    expect(await c.cachedFile(resigned), isNotNull);
  });

  test('concurrent fetches share one download', () async {
    final c = cache();
    final audio = _audio('book/0001-aa.m4a');
    await Future.wait([c.fetch(audio), c.fetch(audio)]);
    expect(server.requests, hasLength(1));
  });

  test('resumes a partial download with a range request', () async {
    final c = cache();
    final audio = _audio('book/0001-aa.m4a', size: 100);
    File('${dir.path}/${AudioCache.fileNameFor(audio.cacheKey)}.part')
        .writeAsBytesSync(List.filled(40, 1));

    final file = await c.fetch(audio);
    expect(server.requests.single.headers[HttpHeaders.rangeHeader], 'bytes=40-');
    expect(file!.lengthSync(), 100);
  });

  test('a failed or short download leaves nothing cached', () async {
    final c = cache();
    server.failWith = 410; // expired URL
    expect(await c.fetch(_audio('book/0001-aa.m4a')), isNull);

    server.failWith = null;
    final wrongSize = _audio('book/0002-bb.m4a', size: 999);
    expect(await c.fetch(wrongSize), isNull);
    expect(await c.cachedFile(wrongSize), isNull);
  });

  test('evicts the chapters listened to longest ago', () async {
    final c = cache(maxBytes: 250);
    final one = _audio('book/0001-aa.m4a');
    final two = _audio('book/0002-bb.m4a');
    final three = _audio('book/0003-cc.m4a');

    await c.fetch(one);
    await c.fetch(two);
    // Listened to "one" after "two" was downloaded: "two" is now the oldest.
    (await c.cachedFile(two))!
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    (await c.cachedFile(one))!
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));

    await c.fetch(three); // 300 bytes > 250: one has to go.
    expect(await c.cachedFile(two), isNull);
    expect(await c.cachedFile(one), isNotNull);
    expect(await c.cachedFile(three), isNotNull);
  });

  test('never evicts a chapter in the playlist', () async {
    final c = cache(maxBytes: 250);
    final one = _audio('book/0001-aa.m4a');
    final two = _audio('book/0002-bb.m4a');
    await c.fetch(one);
    await c.fetch(two);
    (await c.cachedFile(one))!
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    c.inUse = {one.cacheKey};

    await c.fetch(_audio('book/0003-cc.m4a'));
    expect(await c.cachedFile(one), isNotNull, reason: 'in use');
    expect(await c.cachedFile(two), isNull);
  });

  test('touch marks a chapter as recently used', () async {
    final c = cache();
    final audio = _audio('book/0001-aa.m4a');
    final file = (await c.fetch(audio))!
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    await c.touch(audio);
    expect(
      file.lastModifiedSync().isAfter(DateTime.now().subtract(const Duration(minutes: 1))),
      isTrue,
    );
  });
}
