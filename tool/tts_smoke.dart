// Headless check of the two risky pieces of the audio pipeline: unpacking a
// sherpa-onnx voice pack with `archive`, and synthesizing Vietnamese with the
// exact model config the app uses.
//
//   dart run tool/tts_smoke.dart <work-dir> [--from <story.txt>]
//
// With --from, the first sentences of a real story file are synthesized
// instead of the built-in ones — the quickest way to check that a new novel
// phonemizes cleanly before importing it.
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:audio_book/services/text_parser.dart';
import 'package:http/http.dart' as http;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _url =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-vi_VN-vais1000-medium-int8.tar.bz2';

Future<void> main(List<String> args) async {
  final work = Directory(args.isEmpty ? './.tts_smoke' : args.first);
  work.createSync(recursive: true);

  final archivePath = '${work.path}/voice.tar.bz2';
  final target = Directory('${work.path}/voice');

  if (!target.existsSync()) {
    final file = File(archivePath);
    if (!file.existsSync() || file.lengthSync() < 1000000) {
      stdout.writeln('Downloading voice pack…');
      final res = await http.Client().send(http.Request('GET', Uri.parse(_url)));
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        got += chunk.length;
        sink.add(chunk);
        stdout.write('\r  ${(got / 1048576).toStringAsFixed(1)} MB');
      }
      await sink.close();
      stdout.writeln();
    }

    stdout.writeln('Extracting…');
    final tarPath = '$archivePath.tar';
    final input = InputFileStream(archivePath);
    final output = OutputFileStream(tarPath);
    BZip2Decoder().decodeStream(input, output);
    await input.close();
    await output.close();

    final tarInput = InputFileStream(tarPath);
    await extractArchiveToDisk(TarDecoder().decodeStream(tarInput), target.path);
    await tarInput.close();
    File(tarPath).deleteSync();
  }

  File? model;
  File? tokens;
  Directory? dataDir;
  for (final e in target.listSync(recursive: true)) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is File && name.endsWith('.onnx')) {
      if (model == null || name.contains('int8')) model = e;
    } else if (e is File && name == 'tokens.txt') {
      tokens = e;
    } else if (e is Directory && name == 'espeak-ng-data') {
      dataDir = e;
    }
  }
  stdout.writeln('model   = ${model?.path}');
  stdout.writeln('tokens  = ${tokens?.path}');
  stdout.writeln('dataDir = ${dataDir?.path} (${dataDir?.path.length} chars)');
  // espeak-ng keeps this path in a 230-byte buffer and silently falls back to
  // /usr/share/espeak-ng-data — then exits — when it does not fit.
  if ((dataDir?.path.length ?? 0) > 210) {
    stderr.writeln('FAIL: espeak data path is too long for espeak-ng');
    exit(1);
  }
  if (model == null || tokens == null) {
    stderr.writeln('FAIL: voice pack layout not recognised');
    exit(1);
  }

  sherpa.initBindings();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
        model: model.path,
        tokens: tokens.path,
        dataDir: dataDir?.path ?? '',
      ),
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    ),
    maxNumSenetences: 1,
  ));
  stdout.writeln('sampleRate = ${tts.sampleRate}, speakers = ${tts.numSpeakers}');

  final sentences = _sentencesToSpeak(args);

  for (var i = 0; i < sentences.length; i++) {
    final sw = Stopwatch()..start();
    final audio = tts.generateWithConfig(
      text: sentences[i],
      config: sherpa.OfflineTtsGenerationConfig(
        sid: 0,
        speed: 1.0,
        silenceScale: 1.0,
      ),
    );
    final samples = audio.samples;
    sw.stop();
    final seconds = samples.length / audio.sampleRate;
    final out = '${work.path}/out_$i.wav';
    sherpa.writeWave(
      filename: out,
      samples: samples,
      sampleRate: audio.sampleRate,
    );
    stdout.writeln(
      '[$i] ${seconds.toStringAsFixed(2)}s audio in ${sw.elapsedMilliseconds}ms '
      '(RTF ${(sw.elapsedMilliseconds / 1000 / seconds).toStringAsFixed(2)}) -> $out',
    );
    if (samples.isEmpty) {
      stderr.writeln('FAIL: empty audio for sentence $i');
      exit(1);
    }
  }
  tts.free();
  stdout.writeln('OK');
}

List<String> _sentencesToSpeak(List<String> args) {
  final i = args.indexOf('--from');
  if (i == -1 || i + 1 >= args.length) {
    return const [
      'Trời vừa hửng sáng, thiếu niên khoác kiếm bước xuống núi.',
      'Hắn nói: "Yêu ma bốn phương, ta đều muốn thu phục!"',
      'Gió thổi qua rừng trúc, tiếng lá xào xạc như tiếng người thì thầm.',
    ];
  }
  final raw = File(args[i + 1]).readAsStringSync();
  final book = parseRawText(raw, fallbackTitle: 'story');
  return segment(book.chapters.first.text)
      .expand((p) => p.sentences)
      .where((s) => s.isSpeakable)
      .take(6)
      .map((s) => s.text)
      .toList();
}
