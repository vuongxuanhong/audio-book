import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../models/voice.dart';

class SynthesizedClip {
  const SynthesizedClip({required this.path, required this.duration});
  final String path;
  final Duration duration;
}

/// Runs sherpa-onnx in a dedicated isolate.
///
/// VITS inference is a blocking CPU job — a few hundred milliseconds per
/// sentence on a phone — so it must never run on the UI isolate. The engine
/// keeps one long-lived `OfflineTts` alive in the worker (loading the model
/// takes far longer than a single sentence) and hands back WAV files that
/// `just_audio` can play directly.
class TtsEngine {
  Isolate? _isolate;
  SendPort? _tx;
  ReceivePort? _rx;
  Completer<void>? _ready;
  int _nextId = 0;
  final _pending = <int, Completer<SynthesizedClip>>{};

  InstalledVoice? _voice;
  InstalledVoice? get voice => _voice;
  bool get isReady => _ready?.isCompleted ?? false;

  Directory? _cacheDir;

  Future<Directory> _clipCache() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/tts_clips');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _cacheDir = dir;
  }

  /// Boots the worker for [voice]. Safe to call repeatedly; switching voices
  /// tears the old worker down first.
  Future<void> start(InstalledVoice voice) async {
    if (_voice?.id == voice.id && _ready != null) return _ready!.future;
    await dispose();

    _voice = voice;
    final ready = _ready = Completer<void>();
    final rx = _rx = ReceivePort();

    _isolate = await Isolate.spawn(_ttsWorker, rx.sendPort);

    rx.listen((dynamic message) {
      if (message is SendPort) {
        _tx = message;
        message.send({
          'cmd': 'init',
          'model': voice.modelPath,
          'tokens': voice.tokensPath,
          'dataDir': voice.dataDir,
          'numThreads': _threadCount,
        });
        return;
      }
      final map = message as Map<Object?, Object?>;
      switch (map['type']) {
        case 'ready':
          if (!ready.isCompleted) ready.complete();
        case 'error':
          final error = Exception(map['message'] as String? ?? 'Lỗi TTS');
          final id = map['id'] as int?;
          if (id != null) {
            _pending.remove(id)?.completeError(error);
          } else if (!ready.isCompleted) {
            ready.completeError(error);
          }
        case 'clip':
          final id = map['id'] as int;
          _pending.remove(id)?.complete(SynthesizedClip(
                path: map['path'] as String,
                duration: Duration(milliseconds: map['durationMs'] as int),
              ));
      }
    });

    return ready.future;
  }

  /// Synthesizes [text], reusing an existing clip when the same sentence has
  /// already been rendered by the same voice with the same pacing.
  ///
  Future<SynthesizedClip> synthesize(
    String text, {
    int speakerId = 0,
  }) async {
    final voice = _voice;
    if (voice == null) throw StateError('Chưa chọn giọng đọc');
    await _ready?.future;

    final dir = await _clipCache();
    final key = '$speakerId|$text';
    final path = '${dir.path}/${voice.id}_${_hash(key)}.wav';
    final cached = File(path);
    if (cached.existsSync() && cached.lengthSync() > 44) {
      return SynthesizedClip(
        path: path,
        duration: _wavDuration(cached),
      );
    }

    final id = _nextId++;
    final completer = Completer<SynthesizedClip>();
    _pending[id] = completer;
    _tx!.send({
      'cmd': 'generate',
      'id': id,
      'text': text,
      'sid': speakerId,
      'path': path,
    });
    return completer.future;
  }

  /// A copy of the WAV at [clipPath] with [silenceMs] of silence in front.
  ///
  /// The pause before a line has to be part of the audio itself: in the
  /// background the player must never sit idle between lines, or iOS
  /// suspends the app and the next line never starts. The copy sits next to
  /// the clip so it is cached and cleared with it.
  Future<String> withLeadingSilence(String clipPath, int silenceMs) async {
    if (silenceMs <= 0) return clipPath;
    final path = clipPath.replaceFirst(RegExp(r'\.wav$'), '_s$silenceMs.wav');
    final out = File(path);
    if (out.existsSync() && out.lengthSync() > 44) return path;

    final raw = await File(clipPath).readAsBytes();
    if (raw.length < 44) return clipPath;
    final header = ByteData.sublistView(raw, 0, 44);
    final channels = header.getUint16(22, Endian.little);
    final sampleRate = header.getUint32(24, Endian.little);
    final bits = header.getUint16(34, Endian.little);
    final blockAlign = channels * bits ~/ 8;
    if (blockAlign == 0 || sampleRate == 0) return clipPath;

    final silenceBytes = (sampleRate * silenceMs ~/ 1000) * blockAlign;
    final dataBytes = raw.length - 44 + silenceBytes;
    final bytes = Uint8List(44 + dataBytes)
      ..setRange(0, 44, raw)
      ..setRange(44 + silenceBytes, 44 + dataBytes, raw, 44);
    ByteData.sublistView(bytes)
      ..setUint32(4, 36 + dataBytes, Endian.little)
      ..setUint32(40, dataBytes, Endian.little);

    // Write under a temporary name so a half-written file is never mistaken
    // for a finished one by the existence check above.
    final tmp = File('$path.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
    return path;
  }

  Future<void> dispose() async {
    _tx?.send({'cmd': 'shutdown'});
    _rx?.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _tx = null;
    _rx = null;
    _ready = null;
    _voice = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('Engine đã dừng'));
    }
    _pending.clear();
  }

  Future<void> clearClipCache() async {
    final dir = await _clipCache();
    for (final f in dir.listSync().whereType<File>()) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // A clip currently held open by the player; it will go on the next run.
      }
    }
  }

  Future<int> clipCacheBytes() async {
    final dir = await _clipCache();
    return dir
        .listSync()
        .whereType<File>()
        .fold<int>(0, (sum, f) => sum + f.lengthSync());
  }

  static int get _threadCount {
    final cores = Platform.numberOfProcessors;
    return cores >= 8 ? 4 : (cores >= 4 ? 2 : 1);
  }

  static String _hash(String input) {
    // FNV-1a over UTF-16 code units — plenty for a cache key, no extra deps.
    var hash = 0xcbf29ce484222325;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(36);
  }

  static Duration _wavDuration(File file) {
    final raw = file.readAsBytesSync();
    if (raw.length < 44) return Duration.zero;
    final view = raw.buffer.asByteData();
    final sampleRate = view.getUint32(24, Endian.little);
    final byteRate = view.getUint32(28, Endian.little);
    if (sampleRate == 0 || byteRate == 0) return Duration.zero;
    final dataBytes = raw.length - 44;
    return Duration(milliseconds: (dataBytes * 1000 / byteRate).round());
  }
}

/// Worker isolate entry point. Owns the native TTS handle for its lifetime.
void _ttsWorker(SendPort host) {
  final rx = ReceivePort();
  host.send(rx.sendPort);

  sherpa.OfflineTts? tts;

  rx.listen((dynamic message) {
    final map = message as Map<Object?, Object?>;
    switch (map['cmd']) {
      case 'init':
        try {
          sherpa.initBindings();
          final config = sherpa.OfflineTtsConfig(
            model: sherpa.OfflineTtsModelConfig(
              vits: sherpa.OfflineTtsVitsModelConfig(
                model: map['model'] as String,
                tokens: map['tokens'] as String,
                dataDir: map['dataDir'] as String,
              ),
              numThreads: map['numThreads'] as int,
              debug: false,
              provider: 'cpu',
            ),
            maxNumSenetences: 1,
          );
          tts = sherpa.OfflineTts(config);
          host.send({'type': 'ready'});
        } on Object catch (e) {
          host.send({'type': 'error', 'message': e.toString()});
        }

      case 'generate':
        final id = map['id'] as int;
        final engine = tts;
        if (engine == null) {
          host.send({'type': 'error', 'id': id, 'message': 'Engine chưa sẵn sàng'});
          return;
        }
        try {
          // Always render at speed 1.0 and let the player change the rate: the
          // clip cache then stays valid when the user drags the speed slider.
          //
          // silenceScale is pinned to 1.0 so sherpa does not squash the model's
          // own pauses (its default of 0.2 cuts them to a fifth). Pauses at
          // commas come from splitting the text into clauses, not from touching
          // the audio.
          final audio = engine.generateWithConfig(
            text: map['text'] as String,
            config: sherpa.OfflineTtsGenerationConfig(
              sid: map['sid'] as int,
              speed: 1.0,
              silenceScale: 1.0,
            ),
          );
          final samples = audio.samples;
          final path = map['path'] as String;
          sherpa.writeWave(
            filename: path,
            samples: samples,
            sampleRate: audio.sampleRate,
          );
          final ms = audio.sampleRate == 0
              ? 0
              : (samples.length * 1000 / audio.sampleRate).round();
          host.send({'type': 'clip', 'id': id, 'path': path, 'durationMs': ms});
        } on Object catch (e) {
          host.send({'type': 'error', 'id': id, 'message': e.toString()});
        }

      case 'shutdown':
        tts?.free();
        tts = null;
        rx.close();
    }
  });
}
