// Measures every speaker in a multi-speaker sherpa-onnx voice pack and prints
// the Dart table that `lib/models/voice_speakers.dart` ships.
//
//   dart run tool/speaker_scan.dart <unpacked-voice-dir>
//
// Median F0 is a cheap, objective stand-in for "what does this voice sound
// like": below ~165 Hz reads as a male voice, above it as female. It lets the
// picker say something truthful about 65 speakers without anyone listening to
// all of them.
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _probe = 'Phủ An Ninh, Trà Mã Đạo. Trời vừa hửng sáng.';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/speaker_scan.dart <voice-dir>');
    exit(1);
  }
  File? model, tokens;
  Directory? data;
  for (final e in Directory(args.first).listSync(recursive: true)) {
    final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is File && n.endsWith('.onnx')) model = e;
    if (e is File && n == 'tokens.txt') tokens = e;
    if (e is Directory && n == 'espeak-ng-data') data = e;
  }
  if (model == null || tokens == null) {
    stderr.writeln('no model/tokens found under ${args.first}');
    exit(1);
  }

  sherpa.initBindings();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
        model: model.path,
        tokens: tokens.path,
        dataDir: data?.path ?? '',
      ),
      numThreads: 2,
      debug: false,
    ),
    maxNumSenetences: 1,
  ));

  final pitches = <int>[];
  for (var sid = 0; sid < tts.numSpeakers; sid++) {
    final audio = tts.generate(text: _probe, sid: sid, speed: 1.0);
    pitches.add(_medianF0(audio.samples, audio.sampleRate).round());
  }
  tts.free();

  final males = pitches.where((p) => p < 165).length;
  stdout.writeln('// ${pitches.length} speakers: $males nam, '
      '${pitches.length - males} nữ');
  stdout.writeln('const speakerPitchHz = <int>[');
  for (var i = 0; i < pitches.length; i += 10) {
    final row = pitches.skip(i).take(10).join(', ');
    stdout.writeln('  $row,');
  }
  stdout.writeln('];');
}

/// Median fundamental frequency over the voiced frames, by autocorrelation.
double _medianF0(Float32List x, int rate, {int fmin = 60, int fmax = 400}) {
  final win = (rate * 0.04).round();
  final hop = (rate * 0.02).round();
  final lo = rate ~/ fmax;
  final hi = rate ~/ fmin;
  final found = <double>[];

  for (var start = 0; start + win < x.length; start += hop) {
    var mean = 0.0;
    for (var i = 0; i < win; i++) {
      mean += x[start + i];
    }
    mean /= win;

    var energy = 0.0;
    for (var i = 0; i < win; i++) {
      final v = x[start + i] - mean;
      energy += v * v;
    }
    if (energy / win < 0.0025) continue; // silence

    var bestLag = -1;
    var best = 0.0;
    for (var lag = lo; lag < hi && lag < win; lag++) {
      var sum = 0.0;
      for (var i = 0; i + lag < win; i++) {
        sum += (x[start + i] - mean) * (x[start + i + lag] - mean);
      }
      if (sum > best) {
        best = sum;
        bestLag = lag;
      }
    }
    if (bestLag > 0 && best / energy > 0.3) found.add(rate / bestLag);
  }

  if (found.isEmpty) return 0;
  found.sort();
  return found[found.length ~/ 2];
}
