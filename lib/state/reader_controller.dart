import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../models/book.dart';
import '../models/chapter_audio.dart';
import '../models/reading_progress.dart';
import '../models/sentence.dart';
import '../services/audio_cache.dart';
import '../services/library_repository.dart';
import '../services/now_playing_art.dart';
import '../services/paginator.dart';
import '../services/remote_book_service.dart'
    show EntitlementRequiredException, LoginRequiredException;
import '../services/settings_store.dart';
import '../services/text_parser.dart' as parser;
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

/// One chapter in the player's playlist: its text and its narration.
class _QueuedChapter {
  _QueuedChapter(this.chapter, this.audio);

  final _ChapterData chapter;
  final ChapterAudio audio;

  /// Whether the player is streaming this chapter rather than playing it
  /// from the cache — set when its source is made ([ReaderController._source]).
  bool streaming = false;

  /// What is being read at [position] into this chapter's audio: the
  /// timeline chunk, and the sentence the narration has got to within it.
  ///
  /// The timeline only says when each chunk starts, so the place inside a
  /// chunk is estimated from how much of the chunk's time has gone by. That
  /// is what turns the page in time when a chunk runs on from one page to
  /// the next.
  ({int chunk, int sentence}) readingAt(Duration position) {
    final ms = position.inMilliseconds;
    final chunk = chunkIndexAt(audio.timeline, ms);
    final offset =
        estimatedReadingOffset(audio.timeline, chunk, ms, audio.durationMs);
    return (chunk: chunk, sentence: sentenceAtOffset(chapter.sentences, offset));
  }

  /// Where in the audio [sentence] starts being read.
  Duration startOf(int sentence) => Duration(
        milliseconds: sentenceStartMs(
          audio.timeline,
          chapter.sentences[sentence.clamp(0, chapter.sentences.length - 1)],
        ),
      );
}

/// Drives one open book: which chapter is on screen, which sentence is being
/// read aloud, and the playlist of narrated chapters streamed from the
/// backend's audio server.
///
/// Each chapter is one audio file with a timeline that says which span of
/// the chapter text is being read when; the player's position is mapped
/// through it to the highlighted sentence. The playlist keeps the next
/// chapter queued behind the one playing, so listening runs on from chapter
/// to chapter without the player ever going idle — an idle player in the
/// background gets the app suspended on iOS. The lock-screen controls and
/// the Android foreground service come from just_audio_background and only
/// exist while there is something in the playlist, so reading without
/// listening runs nothing in the background.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required Book book,
    required LibraryRepository library,
    required AudioCache audioCache,
    required SettingsStore store,
    required AppSettings settings,
  })  : _book = book,
        _library = library,
        _audioCache = audioCache,
        _store = store,
        _settings = settings {
    _settings.addListener(_onSettingsChanged);
    _subs = [
      _player.currentIndexStream.listen(_onPlayerIndex),
      _player.playerStateStream.listen(_onPlayerState),
      _player
          .createPositionStream(
            minPeriod: const Duration(milliseconds: 100),
            maxPeriod: const Duration(milliseconds: 250),
          )
          .listen(_onPosition),
      _player.playbackEventStream
          .listen(null, onError: (Object e, StackTrace _) => _onPlaybackFailure(e)),
    ];
    _init();
  }

  Book _book;
  final LibraryRepository _library;
  final AudioCache _audioCache;

  /// Once this share of the playing chapter has been heard, the next one
  /// starts downloading.
  static const _prefetchAt = 0.8;

  /// The next chapter joins the playlist once its file is on disk, or at the
  /// latest when this much is left — then streamed, if the download hasn't
  /// finished.
  static const _queueLead = Duration(seconds: 30);
  final SettingsStore _store;
  final AppSettings _settings;

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
  TextStyle _paginatedAmbient = const TextStyle();

  int _cursor = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _disposed = false;

  int _session = 0;
  Timer? _saveTimer;

  /// Last position queued for the server, as (chapter, sentence).
  (int, int)? _lastQueued;

  /// Chapter text range being read aloud, [start, end) — a timeline chunk,
  /// which can cover several sentences, or only part of one.
  (int, int)? _highlight;

  /// Timeline chunk the highlight was last moved to.
  int _highlightChunk = -1;
  late final List<StreamSubscription<Object?>> _subs;

  /// The playlist, index for index with the player's.
  final List<_QueuedChapter> _queue = [];

  /// Session whose [_extendQueue] is in flight, so it never runs twice.
  int? _extendingSession;

  /// The next chapter being fetched ahead of time ([_prefetchNext]): its
  /// index, the chapter response, and whether its audio is on disk yet.
  int? _prefetchIndex;
  Future<_QueuedChapter?>? _prefetch;
  bool _nextCached = false;

  /// Set once nothing more will be appended: the book ran out, or the next
  /// chapter can't be played ([_blockedChapter], [_blockedMessage]).
  bool _queueDone = false;
  int? _blockedChapter;
  String? _blockedMessage;

  /// Last `playing` value the player reported, to tell its own transitions
  /// (lock screen, headset, a phone call) from ours.
  bool _playerPlaying = false;

  /// A failed stream gets one retry with a freshly signed URL — the usual
  /// cause is a URL that expired while paused. Reset once audio plays again.
  bool _retriedFailure = false;
  int? _failedSession;

  int _autoScrollDepth = 0;
  DateTime? _autoScrollSettledAt;

  /// Guards [_finishPlayback], which both the queue and the player's
  /// completion can reach.
  bool _finishing = false;

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

  /// What to highlight while listening: the chapter text range being read.
  (int, int)? get highlight => _highlight;

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

  /// Whether the chapter on screen can be listened to. Narration comes from
  /// the backend, so a book imported from a local file by an earlier version
  /// is read-only, and so is a remote chapter with no audio found for it.
  bool get canListen => listenUnavailableReason == null;

  /// Why [canListen] is false, for the UI; null when it is true.
  String? get listenUnavailableReason {
    if (!_book.isRemote) return 'Truyện này không có bản đọc';
    if (chapter.hasAudio != true) return 'Chương này chưa có bản đọc';
    return null;
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
  ///
  /// [ambient] is the text style the page inherits (`DefaultTextStyle`):
  /// the rendered text picks up its font and letter spacing on top of the
  /// reader's size and line height, so measuring without it under-counts
  /// lines and the bottom of a page gets cut off.
  void layout(
    Size size, {
    TextScaler textScaler = TextScaler.noScaling,
    TextStyle ambient = const TextStyle(),
  }) {
    final fontSize = _settings.fontSize;
    final lineHeight = _settings.lineHeight;
    if (_lastLayoutSize == size &&
        _pagesForChapter == _chapterIndex &&
        _paginatedFontSize == fontSize &&
        _paginatedLineHeight == lineHeight &&
        _paginatedTextScaler == textScaler &&
        _paginatedAmbient == ambient) {
      return;
    }
    _lastLayoutSize = size;
    _pagesForChapter = _chapterIndex;
    _paginatedFontSize = fontSize;
    _paginatedLineHeight = lineHeight;
    _paginatedTextScaler = textScaler;
    _paginatedAmbient = ambient;
    _repaginate(size, textScaler, ambient);
  }

  void _repaginate(Size size, TextScaler textScaler, TextStyle ambient) {
    _pages = paginate(
      paragraphs: _paragraphs,
      pageSize: size,
      style: ambient.merge(TextStyle(
        fontSize: _settings.fontSize,
        height: _settings.lineHeight,
      )),
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
    // Opening a book is enough for it to count as being read ("Đọc tiếp"),
    // and the library reloads as soon as the reader is popped — before
    // dispose() would get to save.
    if (_status == ReaderStatus.ready) _saveProgressNow();
    unawaited(_store.setLastBookId(_book.id));
    unawaited(_refreshAudioAvailability());
  }

  Future<void> _refreshAudioAvailability() async {
    if (!_book.isRemote) return;
    try {
      final refreshed = await _library.refreshAudioAvailability(_book);
      if (_disposed) return;
      _book = refreshed;
      _safeNotify();
    } on Object {
      // Offline or rate-limited: keep what book.json already says.
    }
  }

  /// Records what a chapter fetch found out about [index]'s narration.
  void _noteHasAudio(int index, bool hasAudio) {
    if (_book.chapters[index].hasAudio == hasAudio) return;
    final chapters = [..._book.chapters];
    chapters[index] = chapters[index].copyWith(hasAudio: hasAudio);
    _book = _book.copyWith(chapters: chapters);
    unawaited(_library.saveBook(_book));
    _safeNotify();
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

  Future<_ChapterData> _fetchChapter(int index) async =>
      _chapterData(index, await _library.loadChapterText(_book, index));

  static _ChapterData _chapterData(int index, String text) {
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
    // Same index can still mean new text (the server's copy changed), so
    // always repaginate on the next layout.
    _pagesForChapter = -1;
    // Ranges into the old text mean nothing in the new one.
    _highlight = null;
    _highlightChunk = -1;
  }

  /// Re-attempts loading the chapter that just failed to unlock — call after
  /// a successful sign-in so the reader doesn't have to be closed and reopened.
  Future<void> retryCurrentChapter() =>
      _loadChapter(_chapterIndex, sentenceIndex: _cursor);

  void dismissError() {
    _error = null;
    _safeNotify();
  }

  void _onSettingsChanged() {
    if (_player.speed != _settings.speed) {
      unawaited(_player.setSpeed(_settings.speed));
    }
    // Font size/line height change how much text fits on a page; repaginate
    // with whatever size and text scale the reader last reported.
    final size = _lastLayoutSize;
    if (size != null) {
      layout(size, textScaler: _paginatedTextScaler, ambient: _paginatedAmbient);
    }
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
    if (_playing || _sentences.isEmpty || !canListen) return;

    _playing = true;
    _error = null;
    _retriedFailure = false;
    _safeNotify();

    // Paused in the chapter still on screen: carry on from the cursor, which
    // may have moved since (a swipe to another page while paused). A file
    // on disk doesn't care that the URL has expired since.
    final item = _currentItem;
    if (item != null &&
        item.chapter.index == _chapterIndex &&
        (item.audio.isFresh() || !item.streaming)) {
      if (await _canSwitchToFile(item)) {
        await _startAt(reuse: item);
        return;
      }
      if (item.readingAt(_player.position).sentence != _cursor) {
        await _player.seek(item.startOf(_cursor));
      }
      unawaited(_player.play());
      return;
    }
    await _startAt();
  }

  /// Rebuilds the playlist from the chapter on screen, starting at the
  /// cursor.
  ///
  /// [reuse] is the chapter as already loaded, to switch it from streaming
  /// to its cached file without asking the API for it again.
  Future<void> _startAt({bool forceRefresh = false, _QueuedChapter? reuse}) async {
    final session = ++_session;
    bool live() => session == _session && !_disposed;

    _buffering = true;
    _safeNotify();
    highlightTick.value++;
    await _clearQueue();
    if (!live()) return;

    final _QueuedChapter? item;
    try {
      item = reuse ?? await _loadQueued(_chapterIndex, forceRefresh: forceRefresh);
    } on Object catch (e) {
      if (!live()) return;
      _error = _describe(e);
      await stop();
      return;
    }
    if (!live()) return;
    if (item == null) {
      _error = 'Chương này chưa có bản đọc.';
      await stop();
      return;
    }

    if (item.chapter.text != _chapterText) {
      // The server's text changed since it was cached; the timeline only
      // matches the new one, so that is what goes on screen.
      _show(item.chapter);
      _cursor = _cursor.clamp(0, _sentences.isEmpty ? 0 : _sentences.length - 1);
      _safeNotify();
    }

    _queue.add(item);
    _markInUse();
    _resetPrefetch();
    _queueDone = false;
    _blockedChapter = null;
    _blockedMessage = null;
    try {
      if (_player.speed != _settings.speed) {
        await _player.setSpeed(_settings.speed);
      }
      await _player.setAudioSources(
        [await _source(item)],
        initialPosition: item.startOf(_cursor),
      );
    } on Object catch (e) {
      if (live()) _onPlaybackFailure(e);
      return;
    }
    if (!live()) return;
    if (_playing) unawaited(_player.play());
    _lookAhead();
  }

  /// [index]'s narration, ready to queue — null when it has none. Uses the
  /// chapter already on screen when the server's text still matches it, so
  /// the highlight lines up with the sentences the view has laid out.
  Future<_QueuedChapter?> _loadQueued(int index, {bool forceRefresh = false}) async {
    final remote = await _library.fetchRemoteChapter(
      _book,
      index,
      forceRefresh: forceRefresh,
    );
    final audio = remote.audio;
    _noteHasAudio(index, audio != null);
    if (audio == null) return null;
    final data = index == _chapterIndex && remote.content == _chapterText
        ? _shown
        : _chapterData(index, remote.content);
    return _QueuedChapter(data, audio);
  }

  /// Keeps the chapter after the one playing queued, until the book runs out
  /// or a chapter can't be played.
  Future<void> _extendQueue(int session) async {
    bool live() => session == _session && !_disposed;
    if (!live() || _queueDone || _extendingSession == session) return;
    if (_queue.isEmpty) return;
    final playingIndex = _player.currentIndex ?? 0;
    if (_queue.length - playingIndex > 1) return;

    _extendingSession = session;
    try {
      final nextIndex = _queue.last.chapter.index + 1;
      if (nextIndex >= _book.chapterCount) {
        _queueDone = true;
      } else {
        _QueuedChapter? item;
        String? message;
        try {
          // Known to have no narration: no need to ask the server again.
          item = _book.chapters[nextIndex].hasAudio == false
              ? null
              : await _takePrefetched(nextIndex);
          if (item == null) message = 'Chương này chưa có bản đọc.';
        } on LoginRequiredException {
          // The chapter itself explains this once it is shown.
        } on EntitlementRequiredException {
          // Same.
        } on Object catch (e) {
          message = _describe(e);
        }
        if (!live()) return;

        if (item == null) {
          _queueDone = true;
          _blockedChapter = nextIndex;
          _blockedMessage = message;
        } else {
          final starved =
              _player.processingState == ProcessingState.completed;
          _queue.add(item);
          _markInUse();
          await _player.addAudioSource(await _source(item));
          // The player ran dry and stopped at the end of the last chapter;
          // it does not move on by itself when more is added.
          if (starved && live()) {
            await _player.seek(Duration.zero, index: _queue.length - 1);
          }
        }
      }
    } on Object catch (e) {
      if (live()) _onPlaybackFailure(e);
      return;
    } finally {
      if (_extendingSession == session) _extendingSession = null;
    }

    if (live() &&
        _queueDone &&
        _player.processingState == ProcessingState.completed) {
      await _finishPlayback();
    }
  }

  /// Plays [item] from disk when it's cached. Otherwise streams it, while the
  /// whole file downloads in the background — ahead of the player, so the
  /// rest of the chapter is on disk by the time the narration gets there,
  /// and it plays from disk next time.
  Future<AudioSource> _source(_QueuedChapter item) async {
    final chapter = _book.chapters[item.chapter.index];
    final tag = MediaItem(
      id: '${_book.id}/${item.chapter.index}',
      title: chapter.title,
      album: _book.title,
      duration: Duration(milliseconds: item.audio.durationMs),
      artUri: await nowPlayingArt(),
    );
    final cached = await _audioCache.cachedFile(item.audio);
    item.streaming = cached == null;
    if (cached != null) {
      unawaited(_audioCache.touch(item.audio));
      return AudioSource.file(cached.path, tag: tag);
    }
    unawaited(_audioCache.fetch(item.audio));
    return AudioSource.uri(item.audio.url, tag: tag);
  }

  /// Whether [item] is being streamed although its file has finished
  /// downloading since. Switching then costs a moment's rebuffering, so it is
  /// only done where playback restarts anyway: a jump to another sentence,
  /// or resuming after a pause.
  Future<bool> _canSwitchToFile(_QueuedChapter item) async =>
      item.streaming && await _audioCache.cachedFile(item.audio) != null;

  /// Keeps the chapters in the playlist from being evicted from the cache.
  void _markInUse() {
    _audioCache.inUse = {for (final q in _queue) q.audio.cacheKey};
  }

  /// Near the end of the last chapter in the playlist: starts fetching the
  /// next one, and queues it once it's on disk or time is running out.
  void _lookAhead() {
    if (!_playing || _queueDone || _queue.isEmpty || _disposed) return;
    final playingIndex = _player.currentIndex ?? 0;
    if (_queue.length - playingIndex > 1) return;

    final current = _queue.last;
    final duration = Duration(milliseconds: current.audio.durationMs);
    final position = _player.position;
    final remaining = duration - position;
    // An unknown duration (0) counts as already there.
    if (position >= duration * _prefetchAt) {
      _prefetchNext(current.chapter.index + 1);
    }
    if (remaining <= _queueLead || _nextCached) {
      unawaited(_extendQueue(_session));
    }
  }

  /// Fetches chapter [index] — its text and timeline, then its audio file —
  /// ahead of time, for [_extendQueue] to pick up.
  void _prefetchNext(int index) {
    if (_prefetchIndex == index ||
        index >= _book.chapterCount ||
        _book.chapters[index].hasAudio == false) {
      return;
    }
    final session = _session;
    _prefetchIndex = index;
    _nextCached = false;
    final prefetch = _prefetch = _loadQueued(index);
    unawaited(prefetch.then((item) async {
      if (item == null) return;
      final file = await _audioCache.fetch(item.audio);
      if (file != null && session == _session && _prefetchIndex == index) {
        _nextCached = true;
        _lookAhead();
      }
    }, onError: (Object _) {
      // _extendQueue gets the same error when it takes this prefetch, and
      // handles it there.
    }));
  }

  /// Chapter [index] as fetched ahead of time, or freshly if it wasn't (or
  /// its URL went stale before its audio made it to disk).
  Future<_QueuedChapter?> _takePrefetched(int index) async {
    final prefetch = _prefetchIndex == index ? _prefetch : null;
    _resetPrefetch();
    if (prefetch == null) return _loadQueued(index);
    final item = await prefetch;
    if (item == null) return null; // No narration.
    if (item.audio.isFresh() ||
        await _audioCache.cachedFile(item.audio) != null) {
      return item;
    }
    return _loadQueued(index, forceRefresh: true);
  }

  void _resetPrefetch() {
    _prefetchIndex = null;
    _prefetch = null;
    _nextCached = false;
  }

  _QueuedChapter? get _currentItem {
    final index = _player.currentIndex;
    return index != null && index < _queue.length ? _queue[index] : null;
  }

  void _onPlayerIndex(int? index) {
    if (index == null || index >= _queue.length || _disposed) return;
    _syncCursor();
    _lookAhead();
  }

  void _onPosition(Duration _) {
    if (!_playing) return;
    _syncCursor();
    _lookAhead();
  }

  /// Moves the highlight (and, when listening ran into the next chapter, the
  /// page) to wherever the player is.
  void _syncCursor() {
    final item = _currentItem;
    // Only while listening. The player re-reports its index when it pauses
    // — which is exactly what a hand-swipe during playback does — and
    // following it then dragged the reader straight back from the page just
    // swiped to. play() picks the reading position up again from there.
    if (item == null || _disposed || !_playing) return;
    // While a source is still loading the player reports position zero, not
    // the start position it was given — following that would flash the
    // chapter's first page every time playback starts mid-chapter.
    final state = _player.processingState;
    if (state == ProcessingState.idle || state == ProcessingState.loading) return;
    final (:chunk, :sentence) = item.readingAt(_player.position);
    final newChapter = item.chapter.index != _chapterIndex ||
        !identical(item.chapter.text, _chapterText);
    if (!newChapter && sentence == _cursor && chunk == _highlightChunk) return;
    if (newChapter) {
      _show(item.chapter);
      _status = ReaderStatus.ready;
    }
    final read = item.audio.timeline[chunk];
    _highlight = (read.startOffset, read.endOffset);
    _highlightChunk = chunk;
    _cursor = sentence;
    _retriedFailure = false;
    _safeNotify();
    highlightTick.value++;
    _scheduleSave();
  }

  void _onPlayerState(PlayerState state) {
    if (_disposed) return;
    final waiting = state.processingState == ProcessingState.loading ||
        state.processingState == ProcessingState.buffering;
    if (state.processingState == ProcessingState.completed) {
      if (_queueDone) {
        unawaited(_finishPlayback());
      } else if (_playing) {
        // Ran dry before the next chapter was queued; it starts as soon as
        // it is.
        _buffering = true;
        _safeNotify();
      }
      unawaited(_extendQueue(_session));
    } else if (_playing && _buffering != waiting) {
      _buffering = waiting;
      _safeNotify();
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

  /// A stream that failed to load or play. Retried once with a fresh URL,
  /// since a signed URL that expired (410) or went bad (403) is the likely
  /// cause; after that, listening stops with the error shown.
  void _onPlaybackFailure(Object error) {
    if (_disposed || !_playing || _failedSession == _session) return;
    _failedSession = _session;
    if (!_retriedFailure) {
      _retriedFailure = true;
      final item = _currentItem;
      if (item != null && item.chapter.index != _chapterIndex) {
        _show(item.chapter);
      }
      unawaited(_startAt(forceRefresh: true));
      return;
    }
    _error = 'Lỗi phát âm thanh: $error';
    unawaited(stop());
  }

  String _describe(Object error) => switch (error) {
        LoginRequiredException() => 'Chương này cần đăng nhập.',
        EntitlementRequiredException() => 'Chương này chưa được mở khoá.',
        _ => 'Không tải được bản đọc: $error',
      };

  /// The last queued chapter has played out.
  Future<void> _finishPlayback() async {
    if (_finishing) return;
    _finishing = true;
    try {
      final blocked = _blockedChapter;
      final message = _blockedMessage;
      _queueDone = false;
      _blockedChapter = null;
      _blockedMessage = null;
      await stop();
      if (blocked != null && !_disposed) {
        // Show why listening stopped (sign in, unlock, no narration yet) on
        // the chapter itself.
        await _loadChapter(blocked);
        if (message != null && _status == ReaderStatus.ready) {
          _error = message;
          _safeNotify();
        }
      }
    } finally {
      _finishing = false;
    }
  }

  Future<void> _clearQueue() async {
    _queue.clear();
    _markInUse();
    _resetPrefetch();
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
    _queueDone = false;
    await _player.stop();
    await _clearQueue();
    _buffering = false;
    _safeNotify();
  }

  /// Jump to a sentence — from a tap in the text while listening.
  Future<void> jumpTo(int sentenceIndex) async {
    if (_sentences.isEmpty) return;
    _cursor = sentenceIndex.clamp(0, _sentences.length - 1);
    // Until the player reports from its new position.
    final target = _sentences[_cursor];
    _highlight = (target.textStart, target.textEnd);
    _highlightChunk = -1;
    _safeNotify();
    highlightTick.value++;
    _saveProgressNow();
    if (!_playing) return;

    final item = _currentItem;
    if (item != null && item.chapter.index == _chapterIndex) {
      if (await _canSwitchToFile(item)) {
        // The seek would rebuffer anyway: do it from the file on disk.
        await _startAt(reuse: item);
      } else {
        await _player.seek(item.startOf(_cursor), index: _player.currentIndex);
      }
    } else {
      await _startAt();
    }
  }

  /// Saves the position right away — when leaving the reader, so the library
  /// it returns to already shows it — and sends it to the server.
  void saveProgress() {
    _saveProgressNow();
    unawaited(_library.flushRemoteProgress());
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveProgressNow);
  }

  void _saveProgressNow() {
    _saveTimer?.cancel();
    final now = DateTime.now();
    unawaited(_store.saveProgress(ReadingProgress(
      bookId: _book.id,
      chapterIndex: _chapterIndex,
      sentenceIndex: _cursor,
      updatedAt: now,
    )));
    // Only an actual move is worth sending: dispose() saves again right after
    // leaving the reader has already sent the same position.
    final position = (_chapterIndex, _cursor);
    if (position != _lastQueued) {
      _lastQueued = position;
      _library.queueRemoteProgress(_book, _chapterIndex, _cursor, now);
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
    _saveProgressNow();
    _settings.removeListener(_onSettingsChanged);
    _session++;
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    highlightTick.dispose();
    super.dispose();
  }
}

/// The timeline chunk playing at [ms] into the audio: the last one that has
/// started by then, or the first before any has.
@visibleForTesting
int chunkIndexAt(List<TimelineChunk> chunks, int ms) {
  var lo = 0;
  var hi = chunks.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (chunks[mid].timeMs <= ms) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// The sentence holding chapter offset [offset]. Sentence spans tile the
/// chapter text (see `segment`), so every offset falls in exactly one.
@visibleForTesting
int sentenceAtOffset(List<Sentence> sentences, int offset) {
  if (sentences.isEmpty) return 0;
  // First sentence that ends after the offset.
  var lo = 0;
  var hi = sentences.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sentences[mid].end <= offset) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Roughly where in chunk [index]'s text the narration is at [ms]: the
/// share of the chunk's time gone by, applied to its text. The chunk lasts
/// until the next one starts, or until [durationMs] for the last one.
@visibleForTesting
int estimatedReadingOffset(
  List<TimelineChunk> chunks,
  int index,
  int ms,
  int durationMs,
) {
  final chunk = chunks[index];
  final endMs = index + 1 < chunks.length ? chunks[index + 1].timeMs : durationMs;
  final span = endMs - chunk.timeMs;
  if (span <= 0 || chunk.endOffset <= chunk.startOffset) return chunk.startOffset;
  final fraction = ((ms - chunk.timeMs) / span).clamp(0.0, 1.0);
  // Stay inside the chunk: its very last offset still belongs to it.
  final length = chunk.endOffset - chunk.startOffset;
  return chunk.startOffset + (fraction * (length - 1)).floor();
}

/// Where in the audio [sentence] starts being read: the first chunk that
/// doesn't lie wholly before it. A sentence with nothing read aloud (a "……"
/// line) starts with whatever is read next.
@visibleForTesting
int sentenceStartMs(List<TimelineChunk> chunks, Sentence sentence) {
  for (final chunk in chunks) {
    if (chunk.endOffset > sentence.start) return chunk.timeMs;
  }
  return chunks.last.timeMs;
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
