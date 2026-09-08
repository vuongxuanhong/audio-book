import 'dart:io';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
void main(List<String> args) {
  File? m, t; Directory? d;
  for (final e in Directory(args[0]).listSync(recursive: true)) {
    final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is File && n.endsWith('.onnx')) m = e;
    if (e is File && n == 'tokens.txt') t = e;
    if (e is Directory && n == 'espeak-ng-data') d = e;
  }
  sherpa.initBindings();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
          model: m!.path, tokens: t!.path, dataDir: d!.path),
      numThreads: 2, debug: false),
    maxNumSenetences: 1));
  for (final text in args.sublist(1)) {
    final a = tts.generate(text: text, sid: 0, speed: 1.0);
    var last = a.samples.length - 1;
    while (last >= 0 && a.samples[last].abs() <= 0.01) {
      last--;
    }
    final tailMs = (a.samples.length - 1 - last) * 1000 / a.sampleRate;
    var first = 0;
    while (first < a.samples.length && a.samples[first].abs() <= 0.01) {
      first++;
    }
    final headMs = first * 1000 / a.sampleRate;
    stdout.writeln('đầu ${headMs.toStringAsFixed(0).padLeft(4)}ms  '
        'đuôi ${tailMs.toStringAsFixed(0).padLeft(4)}ms  «$text»');
  }
  tts.free();
}
