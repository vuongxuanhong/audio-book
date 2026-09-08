import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import '../models/sentence.dart';
import '../services/library_repository.dart';
import '../services/settings_store.dart';
import '../services/text_parser.dart' as parser;
import '../services/tts_engine.dart';
import '../services/voice_repository.dart';
import 'app_settings.dart';

enum ReaderStatus { loading, ready, error }

/// Drives one open book: which chapter is on screen, which sentence is being
/// spoken, and the synthesize-ahead queue that keeps playback gapless.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required Book book,
    required LibraryRepository library,
    required VoiceRepository voices,
    required SettingsStore store,
    required AppSettings settings,
  })  : _book = book,
        _library = library,
        _voices = voices,
        _store = store,
        _settings = settings {
    _settings.addListener(_onSettingsChanged);
    _init();
  }

  final Book _book;
  final LibraryRepository _library;
  final VoiceRepository _voices;
  final SettingsStore _store;
  final AppSettings _settings;

  final TtsEngine _engine = TtsEngine();
  final AudioPlayer _player = AudioPlayer();

  ReaderStatus _status = ReaderStatus.loading;
  String? _error;

  int _chapterIndex = 0;
  String _chapterText = '';
  List<Paragraph> _paragraphs = const [];
  List<Sentence> _sentences = const [];

  int _cursor = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _voiceMissing = false;
  bool _disposed = false;

  int _session = 0;
  Timer? _saveTimer;
  Completer<void>? _clipEnd;

  int _autoScrollDepth = 0;
  DateTime? _autoScrollSettledAt;

  /// Paragraph of the sentence spoken last, so a paragraph break can be heard
  /// as well as seen.
  int? _lastSpokenParagraph;

  /// Set when a "……" line was skipped, so the pause in front of the next
  /// spoken line is a scene break rather than an ordinary paragraph break.
  bool _pendingBeat = false;

  /// Signals the view that the highlight moved so it can scroll to it.
  final ValueNotifier<int> highlightTick = ValueNotifier<int>(0);

  Book get book => _book;
  ReaderStatus get status => _status;
  String? get error => _error;
  int get chapterIndex => _chapterIndex;
  ChapterRef get chapter => _book.chapters[_chapterIndex];
  String get chapterText => _chapterText;
  List<Paragraph> get paragraphs => _paragraphs;
  List<Sentence> get sentences => _sentences;
  int get cursor => _cursor;
  bool get isPlaying => _playing;
  bool get isBuffering => _buffering;
  bool get voiceMissing => _voiceMissing;
  String? get voiceName => _engine.voice?.name;

  int get _speakerId {
    final voice = _engine.voice;
    if (voice == null || !voice.isMultiSpeaker) return 0;
    return _settings.speakerFor(voice.id).clamp(0, voice.numSpeakers - 1);
  }

  /// True while the reader is scrolling itself towards the spoken sentence.
  /// Scroll positions reported during that window describe our own animation,
  /// not the user browsing.
  bool get isAutoScrolling =>
      _autoScrollDepth > 0 ||
      (_autoScrollSettledAt != null &&
          DateTime.now().isBefore(_autoScrollSettledAt!));

  void beginAutoScroll() => _autoScrollDepth++;

  void endAutoScroll() {
    if (_autoScrollDepth > 0) _autoScrollDepth--;
    // The list keeps emitting positions for a few frames after the animation
    // ends; ignore those too.
    _autoScrollSettledAt =
        DateTime.now().add(const Duration(milliseconds: 250));
  }

  Sentence? get currentSentence =>
      _cursor >= 0 && _cursor < _sentences.length ? _sentences[_cursor] : null;

  int get currentParagraph => currentSentence?.paragraphIndex ?? 0;

  double get chapterFraction =>
      _sentences.isEmpty ? 0 : (_cursor / _sentences.length).clamp(0.0, 1.0);

  Future<void> _init() async {
    final saved = _store.progressFor(_book.id);
    final startChapter =
        (saved?.chapterIndex ?? 0).clamp(0, _book.chapterCount - 1);
    await _loadChapter(startChapter, sentenceIndex: saved?.sentenceIndex ?? 0);
    unawaited(_store.setLastBookId(_book.id));
    unawaited(_prepareVoice());
  }

  Future<void> _loadChapter(int index, {int sentenceIndex = 0}) async {
    _status = ReaderStatus.loading;
    _safeNotify();
    try {
      _chapterIndex = index.clamp(0, _book.chapterCount - 1);
      _chapterText = await _library.loadChapterText(_book, _chapterIndex);
      _paragraphs = parser.segment(_chapterText);
      _sentences = [
        for (final p in _paragraphs) ...p.sentences,
      ];
      _cursor = sentenceIndex.clamp(0, _sentences.isEmpty ? 0 : _sentences.length - 1);
      _lastSpokenParagraph = null;
      _pendingBeat = false;
      _status = ReaderStatus.ready;
      _error = null;
    } on Object catch (e) {
      _status = ReaderStatus.error;
      _error = e.toString();
    }
    _safeNotify();
    highlightTick.value++;
  }

  Future<void> _prepareVoice() async {
    try {
      final installed = await _voices.installedVoices();
      if (installed.isEmpty) {
        _voiceMissing = true;
        _safeNotify();
        return;
      }
      final wanted = _settings.voiceId;
      final voice = installed.firstWhere(
        (v) => v.id == wanted,
        orElse: () => installed.first,
      );
      _settings.setVoiceId(voice.id);
      _voiceMissing = false;
      _safeNotify();
      await _engine.start(voice);
      _safeNotify();
    } on Object catch (e) {
      _error = 'Không khởi động được giọng đọc: $e';
      _safeNotify();
    }
  }

  /// Re-reads the installed voices — call after the user downloads one.
  Future<void> reloadVoice() async {
    await _engine.dispose();
    await _prepareVoice();
  }

  void _onSettingsChanged() {
    if (_player.speed != _settings.speed) {
      unawaited(_player.setSpeed(_settings.speed));
    }
  }

  Future<void> openChapter(int index) async {
    await stop();
    await _loadChapter(index);
    _saveProgressNow();
  }

  Future<void> nextChapter() async {
    if (_chapterIndex + 1 < _book.chapterCount) {
      await openChapter(_chapterIndex + 1);
    }
  }

  Future<void> previousChapter() async {
    if (_chapterIndex > 0) await openChapter(_chapterIndex - 1);
  }

  Future<void> toggle() => _playing ? pause() : play();

  Future<void> play() async {
    if (_playing || _sentences.isEmpty) return;
    if (_voiceMissing) return;

    _playing = true;
    _safeNotify();

    final session = ++_session;
    try {
      while (_playing && session == _session && !_disposed) {
        if (_cursor >= _sentences.length) {
          if (_chapterIndex + 1 >= _book.chapterCount) {
            // End of the book: park the highlight on the last sentence rather
            // than letting it fall back to the top of the chapter.
            _cursor = _sentences.length - 1;
            break;
          }
          await _loadChapter(_chapterIndex + 1);
          if (session != _session) return;
          continue;
        }

        final sentence = _sentences[_cursor];
        if (!sentence.isSpeakable) {
          // "……" on a line of its own is a beat, not a word. The wait happens
          // in front of the next spoken line, so two such lines in a row still
          // add up to one scene break rather than two.
          if (sentence.isPauseMark) _pendingBeat = true;
          _cursor++;
          continue;
        }

        _buffering = true;
        _safeNotify();
        highlightTick.value++;

        final SynthesizedClip clip;
        try {
          clip = await _engine.synthesize(
            sentence.text,
            speakerId: _speakerId,
          );
        } on Object catch (e) {
          if (session != _session) return;
          _error = 'Lỗi tổng hợp giọng nói: $e';
          _playing = false;
          _safeNotify();
          return;
        }
        if (session != _session || !_playing || _disposed) return;

        _buffering = false;
        _safeNotify();
        unawaited(_prefetch(_cursor));

        // Speed is a player property that survives a source change, so set it
        // before loading: applying it afterwards lets the first moments of the
        // clip play at the previous rate.
        if (_player.speed != _settings.speed) {
          await _player.setSpeed(_settings.speed);
        }

        // The break has to happen BEFORE the next source is loaded. just_audio
        // leaves `playing` true once a clip ends, and loading a source while
        // playing sends a play request straight away — so a delay placed after
        // setFilePath is simply swallowed by audio that has already started.
        final gap = _gapBefore(sentence);
        if (gap > Duration.zero) {
          await Future<void>.delayed(gap);
          if (session != _session || !_playing || _disposed) return;
        }
        _lastSpokenParagraph = sentence.paragraphIndex;
        _pendingBeat = false;

        await _player.setFilePath(clip.path);
        if (session != _session || !_playing) return;
        await _player.play();
        await _awaitClipEnd(clip.duration);

        if (session != _session || !_playing || _disposed) return;
        _cursor++;
        _scheduleSave();
      }
    } finally {
      if (session == _session && !_disposed) {
        _playing = false;
        _buffering = false;
        _safeNotify();
      }
    }
  }

  /// Silence to insert before [sentence]. Divided by the playback rate so the
  /// pacing keeps its proportions when listening fast.
  Duration _gapBefore(Sentence sentence) {
    final ms = pauseMsFor(
      isFirst: _lastSpokenParagraph == null,
      afterBeat: _pendingBeat,
      newParagraph: sentence.paragraphIndex != _lastSpokenParagraph,
      startsSentence: sentence.startsSentence,
      beatMs: _settings.beatPauseMs,
      paragraphMs: _settings.paragraphPauseMs,
      sentenceMs: _settings.sentencePauseMs,
      clauseMs: _settings.clausePauseMs,
    );
    return Duration(milliseconds: (ms / _settings.speed).round());
  }

  /// Waits until the current clip has actually finished.
  ///
  /// `AudioPlayer.play()` cannot be used for this. just_audio returns from
  /// `play()` immediately when `playing` is already true, and it leaves
  /// `playing` true after a clip reaches its end — so from the second sentence
  /// onwards `await play()` completed instantly and the loop cut the sentence
  /// off mid-word. The end of a clip is only visible through
  /// `ProcessingState.completed`.
  Future<void> _awaitClipEnd(Duration clipDuration) async {
    if (_player.processingState == ProcessingState.completed) return;

    final done = Completer<void>();
    _clipEnd = done;
    final sub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && !done.isCompleted) {
        done.complete();
      }
    });
    try {
      // A clip that never reports completion (a decode error, a player left in
      // a bad state) must not wedge playback forever. The bound assumes the
      // slowest playback rate the UI offers.
      await done.future.timeout(
        Duration(milliseconds: clipDuration.inMilliseconds * 2 + 10000),
        onTimeout: () {},
      );
    } finally {
      await sub.cancel();
      if (identical(_clipEnd, done)) _clipEnd = null;
    }
  }

  /// Releases a pending [_awaitClipEnd] so the playback loop can unwind.
  void _breakClipWait() {
    final pending = _clipEnd;
    _clipEnd = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> pause() async {
    _playing = false;
    _session++;
    await _player.pause();
    _breakClipWait();
    _buffering = false;
    _safeNotify();
    _saveProgressNow();
  }

  Future<void> stop() async {
    _playing = false;
    _session++;
    await _player.stop();
    _breakClipWait();
    _buffering = false;
    _safeNotify();
  }

  /// Jump to a sentence — from a tap in the text or from the skip buttons.
  Future<void> jumpTo(int sentenceIndex, {bool keepPlaying = true}) async {
    if (_sentences.isEmpty) return;
    final wasPlaying = _playing;
    _playing = false;
    _session++;
    await _player.stop();
    _breakClipWait();

    _cursor = sentenceIndex.clamp(0, _sentences.length - 1);
    // A deliberate jump should start speaking straight away, with no
    // paragraph break in front of it.
    _lastSpokenParagraph = null;
    _pendingBeat = false;
    _safeNotify();
    highlightTick.value++;
    _saveProgressNow();

    if (wasPlaying && keepPlaying) await play();
  }

  Future<void> skipSentence(int delta) async {
    var target = _cursor + delta;
    while (target > 0 &&
        target < _sentences.length &&
        !_sentences[target].isSpeakable) {
      target += delta.sign;
    }
    await jumpTo(target);
  }

  /// Warms the next couple of sentences so the gap between clips stays short.
  Future<void> _prefetch(int from) async {
    var count = 0;
    for (var i = from + 1; i < _sentences.length && count < 2; i++) {
      final s = _sentences[i];
      if (!s.isSpeakable) continue;
      count++;
      try {
        // Same pacing as playback, or the warmed clip lands under a different
        // cache key and the work is thrown away.
        await _engine.synthesize(
          s.text,
          speakerId: _speakerId,
        );
      } on Object {
        return;
      }
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveProgressNow);
  }

  void _saveProgressNow() {
    _saveTimer?.cancel();
    unawaited(_store.saveProgress(ReadingProgress(
      bookId: _book.id,
      chapterIndex: _chapterIndex,
      sentenceIndex: _cursor,
      updatedAt: DateTime.now(),
    )));
  }

  /// Called by the reader when the user scrolls by hand, so closing the book —
  /// or pressing play — picks up from what they were looking at rather than
  /// from where audio happened to stop.
  void noteVisibleRange(int firstVisible, int lastVisible) {
    if (_playing || _disposed || isAutoScrolling) return;

    final target = resolveBrowseCursor(
      paragraphs: _paragraphs,
      cursor: _cursor,
      firstVisible: firstVisible,
      lastVisible: lastVisible,
    );
    if (target == null) return;

    _cursor = target;
    // The highlight and the playback cursor must never disagree: without this
    // the reader kept highlighting the tapped sentence while play() started
    // somewhere else.
    _safeNotify();
    _scheduleSave();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _breakClipWait();
    _saveProgressNow();
    _settings.removeListener(_onSettingsChanged);
    _session++;
    _player.dispose();
    _engine.dispose();
    highlightTick.dispose();
    super.dispose();
  }
}

/// How long to stay silent in front of the next spoken line.
///
/// The tiers, longest first: a scene break, a paragraph break, a full stop, a
/// comma. Nothing at all before the first line of a run — pressing play should
/// speak straight away.
@visibleForTesting
double pauseMsFor({
  required bool isFirst,
  required bool afterBeat,
  required bool newParagraph,
  required bool startsSentence,
  required double beatMs,
  required double paragraphMs,
  required double sentenceMs,
  required double clauseMs,
}) {
  if (isFirst) return 0;
  if (afterBeat) return beatMs;
  if (newParagraph) return paragraphMs;
  return startsSentence ? sentenceMs : clauseMs;
}

/// Where a hand-scroll should leave the playback cursor, or null to leave it
/// where it is.
///
/// Kept pure so the rule is testable: an explicit choice — the sentence the
/// user tapped — survives as long as its paragraph is still on screen, so
/// tapping the third sentence of a paragraph never snaps back to its first.
@visibleForTesting
int? resolveBrowseCursor({
  required List<Paragraph> paragraphs,
  required int cursor,
  required int firstVisible,
  required int lastVisible,
}) {
  if (paragraphs.isEmpty) return null;
  if (firstVisible < 0 || firstVisible >= paragraphs.length) return null;

  final current = paragraphs
      .expand((p) => p.sentences)
      .firstWhereOrNull((s) => s.index == cursor);
  if (current != null &&
      current.paragraphIndex >= firstVisible &&
      current.paragraphIndex <= lastVisible) {
    return null;
  }

  final first = paragraphs[firstVisible].sentences.firstOrNull;
  if (first == null || first.index == cursor) return null;
  return first.index;
}
