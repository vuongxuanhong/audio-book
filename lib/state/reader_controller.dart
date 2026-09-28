import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../models/book.dart';
import '../models/reading_progress.dart';
import '../models/sentence.dart';
import '../services/library_repository.dart';
import '../services/now_playing_art.dart';
import '../services/paginator.dart';
import '../services/remote_book_service.dart'
    show EntitlementRequiredException, LoginRequiredException;
import '../services/settings_store.dart';
import '../services/text_parser.dart' as parser;
import '../services/tts_engine.dart';
import '../services/voice_repository.dart';
import 'app_settings.dart';

enum ReaderStatus { loading, ready, error }

/// Why a locked remote chapter's content couldn't be loaded — lets the UI
/// show "sign in" vs. "not unlocked" instead of a generic error message.
enum ChapterLockReason { needsLogin, needsEntitlement }

/// A chapter's text, split up — what's on screen, or what the playback queue
/// has already reached past the end of the chapter on screen.
class _ChapterData {
  const _ChapterData(this.index, this.text, this.paragraphs, this.sentences);

  final int index;
  final String text;
  final List<Paragraph> paragraphs;
  final List<Sentence> sentences;
}

/// One line in the player's playlist, by position in the book.
class _QueuedLine {
  const _QueuedLine(this.chapter, this.sentence);

  final _ChapterData chapter;
  final int sentence;
}

/// Drives one open book: which chapter is on screen, which sentence is being
/// spoken, and the synthesize-ahead queue that keeps playback gapless.
///
/// Playback is a playlist rather than one clip at a time: lines are
/// synthesized a few ahead and appended, each with its pause baked in, so the
/// player never goes idle between lines. That is what lets listening carry on
/// with the screen off — an idle player in the background gets the app
/// suspended on iOS. The lock-screen controls and the Android foreground
/// service come from just_audio_background and only exist while there is
/// something in the playlist, so reading without listening runs nothing in
/// the background.
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
    _subs = [
      _player.currentIndexStream.listen(_onPlayerIndex),
      _player.playerStateStream.listen(_onPlayerState),
      _player.playbackEventStream.listen(null, onError: _onPlayerError),
    ];
    _init();
  }

  /// Lines synthesized and queued ahead of the one playing. Synthesis runs
  /// several times faster than speech, so a few lines cover a slow sentence.
  static const _lookahead = 3;

  final Book _book;
  final LibraryRepository _library;
  final VoiceRepository _voices;
  final SettingsStore _store;
  final AppSettings _settings;

  final TtsEngine _engine = TtsEngine();
  final AudioPlayer _player = AudioPlayer();

  ReaderStatus _status = ReaderStatus.loading;
  String? _error;
  ChapterLockReason? _lockReason;

  int _chapterIndex = 0;
  String _chapterText = '';
  List<Paragraph> _paragraphs = const [];
  List<Sentence> _sentences = const [];

  List<PageRange> _pages = const [PageRange(startSentence: 0, endSentence: 0)];
  Size? _lastLayoutSize;
  int _pagesForChapter = -1;
  double? _paginatedFontSize;
  double? _paginatedLineHeight;
  TextScaler _paginatedTextScaler = TextScaler.noScaling;

  int _cursor = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _voiceMissing = false;
  bool _disposed = false;

  int _session = 0;
  Timer? _saveTimer;
  late final List<StreamSubscription<Object?>> _subs;

  /// The playlist, index for index with the player's.
  final List<_QueuedLine> _queue = [];

  /// Where the producer will pick up next — may be chapters ahead of the one
  /// on screen.
  _ChapterData? _prodChapter;
  int _prodCursor = 0;

  /// Set once the producer has queued the book's last line, or hit a chapter
  /// it can't open ([_prodBlockedChapter]).
  bool _prodDone = false;
  int? _prodBlockedChapter;

  /// Wakes the producer when the player moves on or playback is reset.
  Completer<void>? _advance;

  /// Last `playing` value the player reported, to tell its own transitions
  /// (lock screen, headset, a phone call) from ours.
  bool _playerPlaying = false;

  int _autoScrollDepth = 0;
  DateTime? _autoScrollSettledAt;

  /// Paragraph of the line queued last, so a paragraph break can be heard as
  /// well as seen.
  int? _lastSpokenParagraph;

  /// True until the first line of a run is queued — pressing play should
  /// speak straight away.
  bool _runStart = true;

  /// Guards [_finishPlayback], which both the producer and the player's
  /// completion can reach.
  bool _finishing = false;

  /// Set when a "……" line was skipped, so the pause in front of the next
  /// spoken line is a scene break rather than an ordinary paragraph break.
  bool _pendingBeat = false;

  /// Signals the view that the highlight moved so it can scroll to it.
  final ValueNotifier<int> highlightTick = ValueNotifier<int>(0);

  Book get book => _book;
  ReaderStatus get status => _status;
  String? get error => _error;
  ChapterLockReason? get lockReason => _lockReason;
  int get chapterIndex => _chapterIndex;
  ChapterRef get chapter => _book.chapters[_chapterIndex];
  String get chapterText => _chapterText;
  List<Paragraph> get paragraphs => _paragraphs;
  List<Sentence> get sentences => _sentences;
  int get cursor => _cursor;

  List<PageRange> get pages => _pages;
  int get pageCount => _pages.length;

  /// The page whose range contains [_cursor].
  int get currentPageIndex {
    var lo = 0;
    var hi = _pages.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_pages[mid].endSentence <= _cursor) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int get pagesLeftInChapter => _pages.length - currentPageIndex - 1;
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

  /// Called by the reader widget on every build with the space available for
  /// text and the device's current text scaling. Repaginates only when one
  /// of those — or the open chapter — actually changed, so most calls are
  /// free.
  void layout(Size size, {TextScaler textScaler = TextScaler.noScaling}) {
    final fontSize = _settings.fontSize;
    final lineHeight = _settings.lineHeight;
    if (_lastLayoutSize == size &&
        _pagesForChapter == _chapterIndex &&
        _paginatedFontSize == fontSize &&
        _paginatedLineHeight == lineHeight &&
        _paginatedTextScaler == textScaler) {
      return;
    }
    _lastLayoutSize = size;
    _pagesForChapter = _chapterIndex;
    _paginatedFontSize = fontSize;
    _paginatedLineHeight = lineHeight;
    _paginatedTextScaler = textScaler;
    _repaginate(size, textScaler);
  }

  void _repaginate(Size size, TextScaler textScaler) {
    _pages = paginate(
      paragraphs: _paragraphs,
      pageSize: size,
      style: TextStyle(
        fontSize: _settings.fontSize,
        height: _settings.lineHeight,
      ),
      textScaler: textScaler,
    );
    if (_pages.isEmpty) {
      _pages = const [PageRange(startSentence: 0, endSentence: 0)];
    }
    // `layout()` is typically called from a LayoutBuilder while Flutter is in
    // the middle of laying out this very frame — notifying synchronously
    // there would try to rebuild widgets mid-layout. Deferring to the next
    // frame is safe from every call site and the one-frame delay isn't
    // noticeable.
    SchedulerBinding.instance.addPostFrameCallback((_) => _safeNotify());
  }

  Future<void> _init() async {
    var saved = _store.progressFor(_book.id);
    if (_book.isRemote) {
      final remote = await _library.fetchRemoteProgress(_book);
      if (remote != null && (saved == null || remote.updatedAt.isAfter(saved.updatedAt))) {
        saved = remote;
      }
    }
    final startChapter =
        (saved?.chapterIndex ?? 0).clamp(0, _book.chapterCount - 1);
    await _loadChapter(startChapter, sentenceIndex: saved?.sentenceIndex ?? 0);
    unawaited(_store.setLastBookId(_book.id));
    unawaited(_prepareVoice());
  }

  Future<void> _loadChapter(int index, {int sentenceIndex = 0, bool atEnd = false}) async {
    _status = ReaderStatus.loading;
    _safeNotify();
    try {
      _chapterIndex = index.clamp(0, _book.chapterCount - 1);
      _show(await _fetchChapter(_chapterIndex));
      _cursor = atEnd
          ? (_sentences.isEmpty ? 0 : _sentences.length - 1)
          : sentenceIndex.clamp(0, _sentences.isEmpty ? 0 : _sentences.length - 1);
      _status = ReaderStatus.ready;
      _error = null;
      _lockReason = null;
    } on LoginRequiredException {
      _status = ReaderStatus.error;
      _error = 'Chương này cần đăng nhập.';
      _lockReason = ChapterLockReason.needsLogin;
    } on EntitlementRequiredException {
      _status = ReaderStatus.error;
      _error = 'Chương này chưa được mở khoá.';
      _lockReason = ChapterLockReason.needsEntitlement;
    } on Object catch (e) {
      _status = ReaderStatus.error;
      _error = e.toString();
      _lockReason = null;
    }
    _safeNotify();
    highlightTick.value++;
  }

  Future<_ChapterData> _fetchChapter(int index) async {
    final text = await _library.loadChapterText(_book, index);
    final paragraphs = parser.segment(text);
    return _ChapterData(index, text, paragraphs, [
      for (final p in paragraphs) ...p.sentences,
    ]);
  }

  _ChapterData get _shown =>
      _ChapterData(_chapterIndex, _chapterText, _paragraphs, _sentences);

  /// Puts [data] on screen. Pagination follows on the next [layout] call,
  /// since the chapter no longer matches the one last paginated.
  void _show(_ChapterData data) {
    _chapterIndex = data.index;
    _chapterText = data.text;
    _paragraphs = data.paragraphs;
    _sentences = data.sentences;
  }

  /// Re-attempts loading the chapter that just failed to unlock — call after
  /// a successful sign-in so the reader doesn't have to be closed and reopened.
  Future<void> retryCurrentChapter() =>
      _loadChapter(_chapterIndex, sentenceIndex: _cursor);

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
    await stop();
    await _engine.dispose();
    await _prepareVoice();
  }

  void _onSettingsChanged() {
    if (_player.speed != _settings.speed) {
      unawaited(_player.setSpeed(_settings.speed));
    }
    // Font size/line height change how much text fits on a page; repaginate
    // with whatever size and text scale the reader last reported.
    final size = _lastLayoutSize;
    if (size != null) layout(size, textScaler: _paginatedTextScaler);
  }

  Future<void> openChapter(int index, {bool atEnd = false}) async {
    await stop();
    await _loadChapter(index, atEnd: atEnd);
    _saveProgressNow();
  }

  Future<void> nextChapter() async {
    if (_chapterIndex + 1 < _book.chapterCount) {
      await openChapter(_chapterIndex + 1);
    }
  }

  /// [atEnd] lands on the previous chapter's last page instead of its first —
  /// what swiping backward past the first page of a chapter should feel like.
  Future<void> previousChapter({bool atEnd = false}) async {
    if (_chapterIndex > 0) await openChapter(_chapterIndex - 1, atEnd: atEnd);
  }

  Future<void> toggle() => _playing ? pause() : play();

  Future<void> play() async {
    if (_playing || _sentences.isEmpty) return;
    if (_voiceMissing) return;

    _playing = true;
    _safeNotify();

    // Paused on the line still on screen: carry on where the player stopped.
    final index = _player.currentIndex;
    if (index != null && index < _queue.length) {
      final line = _queue[index];
      if (line.chapter.index == _chapterIndex && line.sentence == _cursor) {
        unawaited(_player.play());
        return;
      }
    }

    final session = ++_session;
    _buffering = true;
    _safeNotify();
    highlightTick.value++;
    await _clearQueue();
    if (session != _session) return;
    _prodChapter = _shown;
    _prodCursor = _cursor;
    _prodDone = false;
    _prodBlockedChapter = null;
    _lastSpokenParagraph = null;
    _pendingBeat = false;
    _runStart = true;
    unawaited(_produce(session));
  }

  /// Keeps the playlist [_lookahead] lines ahead of the player until the
  /// book runs out or [session] is superseded.
  Future<void> _produce(int session) async {
    bool live() => session == _session && !_disposed;
    try {
      while (live()) {
        final playingIndex = _player.currentIndex ?? 0;
        if (_queue.length - playingIndex > _lookahead) {
          final wake = _advance = Completer<void>();
          await wake.future;
          continue;
        }

        final next = await _nextLine();
        if (!live()) return;
        if (next == null) {
          _prodDone = true;
          // Nothing left to queue and nothing left to play.
          if (_queue.isEmpty ||
              _player.processingState == ProcessingState.completed) {
            await _finishPlayback();
          }
          return;
        }

        final (line, gapMs) = next;
        final clip = await _engine.synthesize(
          line.chapter.sentences[line.sentence].text,
          speakerId: _speakerId,
        );
        if (!live()) return;
        final path = await _engine.withLeadingSilence(clip.path, gapMs);
        if (!live()) return;

        final source = AudioSource.file(path, tag: await _mediaItem(line));
        if (!live()) return;
        final starved = _player.processingState == ProcessingState.completed;
        _queue.add(line);
        if (_queue.length == 1) {
          if (_player.speed != _settings.speed) {
            await _player.setSpeed(_settings.speed);
          }
          await _player.setAudioSources([source]);
          if (!live()) return;
          if (_playing) unawaited(_player.play());
        } else {
          await _player.addAudioSource(source);
          // The player ran dry and stopped on the last line; it does not
          // move on by itself when more are added.
          if (starved && live()) {
            await _player.seek(Duration.zero, index: _queue.length - 1);
          }
        }
      }
    } on Object catch (e) {
      if (!live()) return;
      _error = 'Lỗi tổng hợp giọng nói: $e';
      await stop();
    }
  }

  /// The next line to queue and the pause in front of it, crossing into the
  /// next chapter when this one runs out. Null at the end of the book, or at
  /// a chapter that can't be opened (see [_prodBlockedChapter]).
  Future<(_QueuedLine, int)?> _nextLine() async {
    var chapter = _prodChapter!;
    while (true) {
      if (_prodCursor >= chapter.sentences.length) {
        final nextIndex = chapter.index + 1;
        if (nextIndex >= _book.chapterCount) return null;
        try {
          chapter = _prodChapter = await _fetchChapter(nextIndex);
        } on Object {
          _prodBlockedChapter = nextIndex;
          return null;
        }
        _prodCursor = 0;
        // A new chapter reads as a scene break.
        _pendingBeat = true;
        continue;
      }

      final sentence = chapter.sentences[_prodCursor];
      if (!sentence.isSpeakable) {
        // "……" on a line of its own is a beat, not a word. The wait happens
        // in front of the next spoken line, so two such lines in a row still
        // add up to one scene break rather than two.
        if (sentence.isPauseMark) _pendingBeat = true;
        _prodCursor++;
        continue;
      }

      final gapMs = _gapMsBefore(sentence);
      _lastSpokenParagraph = sentence.paragraphIndex;
      _pendingBeat = false;
      _runStart = false;
      return (_QueuedLine(chapter, _prodCursor++), gapMs);
    }
  }

  Future<MediaItem> _mediaItem(_QueuedLine line) async {
    final chapter = _book.chapters[line.chapter.index];
    return MediaItem(
      id: '${_book.id}/${line.chapter.index}/${line.sentence}',
      title: chapter.title,
      album: _book.title,
      artUri: await nowPlayingArt(),
    );
  }

  /// Silence to put in front of [sentence]. It is part of the clip, so the
  /// playback rate scales it along with the speech.
  int _gapMsBefore(Sentence sentence) {
    final ms = pauseMsFor(
      isFirst: _runStart,
      afterBeat: _pendingBeat,
      newParagraph: sentence.paragraphIndex != _lastSpokenParagraph,
      startsSentence: sentence.startsSentence,
      beatMs: _settings.beatPauseMs,
      paragraphMs: _settings.paragraphPauseMs,
      sentenceMs: _settings.sentencePauseMs,
      clauseMs: _settings.clausePauseMs,
    );
    return ms.round();
  }

  void _onPlayerIndex(int? index) {
    if (index == null || index >= _queue.length || _disposed) return;
    final line = _queue[index];
    if (line.chapter.index != _chapterIndex) {
      // Listening ran on into the next chapter; bring it on screen.
      _show(line.chapter);
      _status = ReaderStatus.ready;
    }
    _cursor = line.sentence;
    _buffering = false;
    _safeNotify();
    highlightTick.value++;
    _scheduleSave();
    _wakeProducer();
  }

  void _onPlayerState(PlayerState state) {
    if (_disposed) return;
    if (state.processingState == ProcessingState.completed) {
      if (_prodDone) {
        unawaited(_finishPlayback());
      } else if (_playing && !_buffering) {
        // Ran dry: the producer will restart the player when it catches up.
        _buffering = true;
        _safeNotify();
      }
      _wakeProducer();
    }

    // Follow play/pause from outside the app — the lock screen, a headset
    // button, an incoming call.
    if (state.playing == _playerPlaying) return;
    _playerPlaying = state.playing;
    if (state.playing && !_playing) {
      _playing = true;
      _safeNotify();
    } else if (!state.playing && _playing) {
      _playing = false;
      _buffering = false;
      _safeNotify();
      _saveProgressNow();
    }
  }

  void _onPlayerError(Object error, StackTrace _) {
    if (_disposed) return;
    _error = 'Lỗi phát âm thanh: $error';
    unawaited(stop());
  }

  /// The last queued line has played out.
  Future<void> _finishPlayback() async {
    if (_finishing) return;
    _finishing = true;
    try {
      final blocked = _prodBlockedChapter;
      _prodDone = false;
      _prodBlockedChapter = null;
      await stop();
      if (blocked != null && !_disposed) {
        // Show why listening stopped (sign in, unlock) on the chapter itself.
        await _loadChapter(blocked);
      }
    } finally {
      _finishing = false;
    }
  }

  void _wakeProducer() {
    final wake = _advance;
    _advance = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _clearQueue() async {
    _queue.clear();
    await _player.clearAudioSources();
  }

  Future<void> pause() async {
    _playing = false;
    await _player.pause();
    _buffering = false;
    _safeNotify();
    _saveProgressNow();
  }

  /// Ends listening altogether: drops the queue and, with it, the lock-screen
  /// controls and the background service.
  Future<void> stop() async {
    _playing = false;
    _session++;
    _wakeProducer();
    await _player.stop();
    await _clearQueue();
    _buffering = false;
    _safeNotify();
  }

  /// Jump to a sentence — from a tap in the text or from the skip buttons.
  Future<void> jumpTo(int sentenceIndex, {bool keepPlaying = true}) async {
    if (_sentences.isEmpty) return;
    final wasPlaying = _playing;
    if (wasPlaying) {
      _playing = false;
      _session++;
      _wakeProducer();
      await _player.pause();
      // Start the chosen line from its beginning, even if it's the one that
      // was playing.
      await _clearQueue();
    }

    _cursor = sentenceIndex.clamp(0, _sentences.length - 1);
    _safeNotify();
    highlightTick.value++;
    _saveProgressNow();

    // play() sees the cursor no longer matches the queue and rebuilds it.
    if (wasPlaying && keepPlaying) await play();
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
    if (_book.isRemote) {
      unawaited(_library.pushRemoteProgress(_book, _chapterIndex, _cursor));
    }
  }

  /// Called by the reader when the user swipes to a page by hand. While
  /// paused this becomes the new reading position; while playing it's just a
  /// peek and must not move the playback cursor.
  void notePageBrowsed(int pageIndex) {
    if (_playing || _disposed || isAutoScrolling) return;
    final target = resolvePageBrowseCursor(
      pages: _pages,
      cursor: _cursor,
      pageIndex: pageIndex,
    );
    if (target == null) return;

    _cursor = target;
    _safeNotify();
    _scheduleSave();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wakeProducer();
    _saveProgressNow();
    _settings.removeListener(_onSettingsChanged);
    _session++;
    for (final sub in _subs) {
      sub.cancel();
    }
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

/// Where a hand-swipe to another page should leave the playback cursor, or
/// null to leave it where it is.
///
/// Kept pure so the rule is testable: an explicit choice — the sentence the
/// user tapped — survives as long as it's still on the page being shown, so
/// tapping the last sentence of a page never snaps back to that page's first.
@visibleForTesting
int? resolvePageBrowseCursor({
  required List<PageRange> pages,
  required int cursor,
  required int pageIndex,
}) {
  if (pageIndex < 0 || pageIndex >= pages.length) return null;

  final page = pages[pageIndex];
  if (page.contains(cursor)) return null;
  if (page.startSentence == cursor) return null;
  return page.startSentence;
}
