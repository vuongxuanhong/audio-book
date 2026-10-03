import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:real_page_flip/real_page_flip.dart';

import '../models/book.dart';
import '../models/sentence.dart';
import '../services/device_auth.dart';
import '../services/library_repository.dart';
import '../services/paginator.dart';
import '../services/screen_security.dart';
import '../services/settings_store.dart';
import '../state/app_settings.dart';
import '../state/reader_controller.dart';
import 'widgets/chapter_list.dart';
import 'widgets/player_bar.dart';
import 'widgets/sign_in_buttons.dart';

class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key, required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ReaderController>(
      create: (_) => ReaderController(
        book: book,
        library: context.read<LibraryRepository>(),
        store: context.read<SettingsStore>(),
        settings: context.read<AppSettings>(),
      ),
      child: Builder(
        builder: (context) => PopScope(
          // Runs as the route pops, before the library screen it returns to
          // reloads — dispose() would save too late for that.
          onPopInvokedWithResult: (_, _) =>
              context.read<ReaderController>().saveProgress(),
          child: const _ReaderView(),
        ),
      ),
    );
  }
}

class _ReaderView extends StatefulWidget {
  const _ReaderView();

  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView>
    with WidgetsBindingObserver {
  PageFlipController? _pageFlipController;
  int? _pageControllerChapter;
  int _lastShownPage = -1;

  /// The flip index handed to [PageFlipWidget] as `initialIndex`, fixed for
  /// as long as that widget lives. The widget treats any *change* of
  /// `initialIndex` as a request to jump there — so deriving it from the
  /// reading position, which moves on its own while listening, made it jump
  /// a page on top of the animated turn [_onHighlightMoved] had just started
  /// (two pages forward, then one back). Following the narration goes
  /// through nextPage/previousPage/goToPage only; this is just where a fresh
  /// widget opens. Cleared whenever the page view is not on screen, so it is
  /// recomputed when it comes back.
  int? _flipInitialIndex;

  // Read mode: control chrome starts hidden and only appears when the user
  // taps the page (never on a swipe). Listen mode (audio playing) always
  // shows it instead — see `chromeVisible` in build().
  bool _chromeVisible = false;

  ReaderController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(enableScreenCaptureProtection());
  }

  /// Listening carries on in the background, where no frames are drawn and a
  /// page flip can't run. Catch the page up in one cut on return, while it is
  /// still flagged as our own move — a flip left to finish late would look
  /// like a hand-swipe and pause playback.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_onHighlightMoved());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<ReaderController>();
    if (identical(controller, _controller)) return;
    _controller?.highlightTick.removeListener(_onHighlightMoved);
    _controller = controller..highlightTick.addListener(_onHighlightMoved);
  }

  /// Creates the flip controller once (its `initialIndex` on the widget below
  /// places it on the restored reading position for the very first chapter),
  /// and jumps it to the right page whenever the open chapter changes
  /// underneath it.
  ///
  /// The book carries two extra "phantom" pages, one before the first real
  /// page and one after the last (see [_onPageChanged]), so every real page
  /// lives at `controller.currentPageIndex + 1` in flip-index terms.
  void _ensurePageFlipController(ReaderController controller) {
    _pageFlipController ??= PageFlipController();
    if (_pageControllerChapter == null) {
      _pageControllerChapter = controller.chapterIndex;
      _lastShownPage = controller.currentPageIndex;
      return;
    }
    if (_pageControllerChapter == controller.chapterIndex) return;

    _pageControllerChapter = controller.chapterIndex;
    _lastShownPage = controller.currentPageIndex;
    final target = controller.currentPageIndex + 1;
    controller.beginAutoScroll();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _pageFlipController?.goToPage(target);
      controller.endAutoScroll();
    });
  }

  /// Landing on the phantom page before/after the chapter's real pages moves
  /// to the previous/next chapter (landing on its last/first page); landing
  /// back on it with no such chapter to go to just snaps back onto the last
  /// real page, so a chapter's first/last page still feels like an edge.
  void _onPageChanged(int index, ReaderController controller) {
    final pageCount = controller.pageCount;
    if (index == 0) {
      if (controller.chapterIndex > 0) {
        controller.previousChapter(atEnd: true);
      } else {
        _snapPageFlipTo(1, controller);
      }
      return;
    }
    if (index == pageCount + 1) {
      if (controller.chapterIndex + 1 < controller.book.chapterCount) {
        controller.nextChapter();
      } else {
        _snapPageFlipTo(pageCount, controller);
      }
      return;
    }

    _lastShownPage = index - 1;
    if (controller.isAutoScrolling) return;

    // A hand-swipe during playback means the user is taking over — drop back
    // to read mode instead of leaving the audio to silently keep narrating a
    // page that's no longer on screen.
    if (controller.isPlaying) {
      unawaited(controller.pause());
      setState(() => _chromeVisible = true);
    }
    controller.notePageBrowsed(index - 1);
  }

  void _snapPageFlipTo(int flipIndex, ReaderController controller) {
    controller.beginAutoScroll();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _pageFlipController?.goToPage(flipIndex);
      controller.endAutoScroll();
    });
  }

  /// Keeps the spoken sentence on screen by turning to its page. Only fires
  /// when the target page changes so a long page is not re-turned on every
  /// sentence. A one-page move gets the real animated flip; a bigger jump
  /// (browsing away and playback catching back up) just cuts there.
  Future<void> _onHighlightMoved() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    if (!context.read<AppSettings>().autoScroll) return;
    // Off screen: leave the page alone; didChangeAppLifecycleState catches up.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final pageFlip = _pageFlipController;
    if (pageFlip == null || !pageFlip.isAttached) return;

    final target = controller.currentPageIndex;
    if (target == _lastShownPage) return;
    final from = _lastShownPage;
    _lastShownPage = target;

    controller.beginAutoScroll();
    try {
      if (target == from + 1) {
        pageFlip.nextPage();
        // nextPage()/previousPage() animate without returning a Future, so
        // hold the "this is our own move" flag through the flip's duration
        // rather than let onPageChanged mistake it for a user browse.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } else if (target == from - 1) {
        pageFlip.previousPage();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } else {
        await pageFlip.goToPage(target + 1);
      }
    } finally {
      controller.endAutoScroll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.highlightTick.removeListener(_onHighlightMoved);
    unawaited(disableScreenCaptureProtection());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    final settings = context.watch<AppSettings>();

    // Listen mode (audio playing) always keeps the chrome up; read mode
    // (paused) hides it by default and only shows it on tap. There's also no
    // chrome-free experience before content is ready — the back button and
    // chapter list need to stay reachable while loading or after an error.
    // No page view while loading or showing an error: the next one opens on
    // the reading position as it is then.
    if (controller.status != ReaderStatus.ready) _flipInitialIndex = null;

    final chromeVisible = controller.status != ReaderStatus.ready ||
        controller.isPlaying ||
        _chromeVisible;

    // A plain Column, not a floating overlay: the header/bottom bar always
    // reserve their own space (even while faded out — see `_ChromeFade`), so
    // the page content sits below/above them instead of ever being covered
    // by them.
    return Scaffold(
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A locked chapter already gets its own full-screen prompt
                // (with the right actions — sign in, or an explanation) below;
                // this banner is for playback errors on a readable chapter.
                if (controller.error != null &&
                    controller.status == ReaderStatus.ready)
                  MaterialBanner(
                    content: Text(controller.error!),
                    actions: [
                      TextButton(
                        onPressed: controller.dismissError,
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                _ChromeFade(
                  visible: chromeVisible,
                  slideDown: false,
                  child: _TopBar(
                    controller: controller,
                    onOpenChapters: () => _openChapters(context, controller),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // In listen mode the chrome is always up (nothing to toggle);
              // tapping a sentence to jump is the only content tap that
              // matters there, and it's handled by that sentence's own
              // recognizer, which wins over this ambient one.
              onTap: controller.isPlaying
                  ? null
                  : () => setState(() => _chromeVisible = !_chromeVisible),
              child: switch (controller.status) {
                ReaderStatus.loading =>
                  const Center(child: CircularProgressIndicator()),
                ReaderStatus.error => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: switch (controller.lockReason) {
                        ChapterLockReason.needsLogin =>
                          _LoginPrompt(controller: controller),
                        ChapterLockReason.needsEntitlement =>
                          const _EntitlementPrompt(),
                        null => Text(controller.error ?? 'Không mở được chương'),
                      },
                    ),
                  ),
                ReaderStatus.ready => Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        controller.layout(
                          constraints.biggest,
                          textScaler: MediaQuery.textScalerOf(context),
                          // What the page's Text.rich inherits.
                          ambient: DefaultTextStyle.of(context).style,
                        );
                        _ensurePageFlipController(controller);

                        // The package snapshots each page into a texture to
                        // animate the flip. Our own page content paints no
                        // background of its own (it just sits on the
                        // Scaffold's), so a captured snapshot has none either
                        // — the moving page flashed a mismatched default
                        // colour against our custom scaffold background for
                        // a frame mid-flip. Filling it in here, and telling
                        // the package the same colour for the page's back
                        // face, keeps every layer the same colour throughout.
                        final pageBackground =
                            Theme.of(context).scaffoldBackgroundColor;

                        return PageFlipWidget(
                          controller: _pageFlipController,
                          // +2 for the leading/trailing phantom pages that
                          // turn a swipe past the edge into a chapter change.
                          itemCount: controller.pageCount + 2,
                          initialIndex: _flipInitialIndex ??=
                              controller.currentPageIndex + 1,
                          config: PageFlipConfig(
                            // We drive the chrome-toggle tap ourselves and
                            // don't want the package's own edge-tap zones
                            // competing with it.
                            edgeTapWidthRatio: 0,
                            // nextPage()/previousPage() are how we follow
                            // the read-aloud cursor — they should animate,
                            // not cut.
                            skipTapAnimation: false,
                            enableHaptics: false,
                            enableSound: false,
                            backgroundColor: pageBackground,
                          ),
                          onPageChanged: (i) => _onPageChanged(i, controller),
                          itemBuilder: (context, index) => ColoredBox(
                            color: pageBackground,
                            child: _pageContentFor(controller, settings, index),
                          ),
                        );
                      },
                    ),
                  ),
              },
            ),
          ),
          Stack(
            alignment: Alignment.center,
            children: [
              // Read mode still needs a "where am I" even with the chrome
              // tapped away — this sits behind the player bar and only shows
              // once that bar has faded out.
              if (controller.status == ReaderStatus.ready &&
                  !controller.isPlaying)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 8),
                  child: Text(
                    '${controller.chapter.title} · '
                    '${(controller.chapterFraction * 100).round()}%',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              _ChromeFade(
                visible: chromeVisible,
                slideDown: true,
                child: const PlayerBar(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pageContentFor(
      ReaderController controller, AppSettings settings, int index) {
    if (index == 0) {
      return _ChapterEdgeHint(
        icon: Icons.arrow_back_ios_new,
        label: controller.chapterIndex > 0 ? 'Chương trước' : 'Đầu truyện',
      );
    }
    if (index == controller.pageCount + 1) {
      return _ChapterEdgeHint(
        icon: Icons.arrow_forward_ios,
        label: controller.chapterIndex + 1 < controller.book.chapterCount
            ? 'Chương sau'
            : 'Hết truyện',
      );
    }
    return _PageBody(
      paragraphs: controller.paragraphs,
      page: controller.pages[index - 1],
      // The highlight marks what is being read aloud; in read mode nothing
      // is playing, so nothing should show as selected — not even the
      // sentence a swipe just landed on.
      highlight: controller.isPlaying ? controller.highlight : null,
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      // Tapping a sentence to jump to it is a listen-mode action — in read
      // mode a tap only ever means "toggle the chrome" (the ambient
      // GestureDetector above).
      onTapSentence:
          controller.isPlaying ? (s) => controller.jumpTo(s.index) : null,
    );
  }

  Future<void> _openChapters(
      BuildContext context, ReaderController controller) async {
    final index = await showChapterPicker(
      context,
      chapters: controller.book.chapters,
      current: controller.chapterIndex,
    );
    if (index != null) await controller.openChapter(index);
  }
}

/// Fades and slides a piece of chrome out of the way when hidden, and stops
/// it from intercepting taps meant for the page underneath.
class _ChromeFade extends StatelessWidget {
  const _ChromeFade({
    required this.visible,
    required this.slideDown,
    required this.child,
  });

  final bool visible;
  final bool slideDown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : Offset(0, slideDown ? 1 : -1),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: child,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.onOpenChapters});

  final ReaderController controller;
  final VoidCallback onOpenChapters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Fully opaque: this floats over the page, and any translucency lets the
    // text underneath show through the bar instead of reading as content
    // that sits below it.
    // Same colour as the app's AppBar, so it reads as a bar on the page.
    final barTheme = theme.appBarTheme;
    return Material(
      color: barTheme.backgroundColor ?? theme.colorScheme.surface,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Row(
          children: [
            const BackButton(),
            Expanded(
              child: Text(
                controller.book.title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: barTheme.foregroundColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Mục lục',
              icon: const Icon(Icons.list_alt),
              onPressed: onOpenChapters,
            ),
          ],
        ),
      ),
    );
  }
}

/// What sits on the phantom page just past a chapter's first/last real page —
/// a brief placeholder while [ReaderController] loads the neighbouring
/// chapter (or, at the very start/end of the book, a dead end).
class _ChapterEdgeHint extends StatelessWidget {
  const _ChapterEdgeHint({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: color),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

/// Renders one page: every paragraph (or partial paragraph) whose sentences
/// fall inside [page].
class _PageBody extends StatelessWidget {
  const _PageBody({
    required this.paragraphs,
    required this.page,
    required this.highlight,
    required this.fontSize,
    required this.lineHeight,
    required this.onTapSentence,
  });

  final List<Paragraph> paragraphs;
  final PageRange page;

  /// Chapter text range to highlight, [start, end); null for none.
  final (int, int)? highlight;
  final double fontSize;
  final double lineHeight;
  final void Function(Sentence)? onTapSentence;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final paragraph in paragraphs) {
      final visible = paragraph.sentences
          .where((s) => page.contains(s.index))
          .toList(growable: false);
      if (visible.isEmpty) continue;
      children.add(_ParagraphSlice(
        key: ValueKey(visible.first.index),
        sentences: visible,
        highlight: highlight,
        fontSize: fontSize,
        lineHeight: lineHeight,
        onTapSentence: onTapSentence,
      ));
    }

    // The paginator leaves headroom for measurement drift (font hinting),
    // but it's an estimate, not a
    // guarantee — clip defensively so the rare miss quietly loses its last
    // sliver of text instead of visibly overflowing the page.
    // `NeverScrollableScrollPhysics` keeps this from becoming a way to
    // scroll — it's here purely for the clip.
    return ClipRect(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// Renders one paragraph's sentences — or the slice of them that lands on the
/// current page, when a long paragraph spans more than one.
class _ParagraphSlice extends StatefulWidget {
  const _ParagraphSlice({
    super.key,
    required this.sentences,
    required this.highlight,
    required this.fontSize,
    required this.lineHeight,
    required this.onTapSentence,
  });

  final List<Sentence> sentences;
  final (int, int)? highlight;
  final double fontSize;
  final double lineHeight;
  final void Function(Sentence)? onTapSentence;

  @override
  State<_ParagraphSlice> createState() => _ParagraphSliceState();
}

class _ParagraphSliceState extends State<_ParagraphSlice> {
  // Recognizers own native gesture state, so they are built once per slice
  // rather than on every highlight change. Null in read mode: with nothing
  // attached, a tap on the text falls through to the ambient chrome toggle
  // instead of jumping.
  List<TapGestureRecognizer>? _recognizers;

  @override
  void initState() {
    super.initState();
    _buildRecognizers();
  }

  @override
  void didUpdateWidget(covariant _ParagraphSlice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onTapSentence == null && widget.onTapSentence == null) {
      return;
    }
    if ((oldWidget.onTapSentence == null) != (widget.onTapSentence == null) ||
        oldWidget.sentences.length != widget.sentences.length ||
        (oldWidget.sentences.isNotEmpty &&
            widget.sentences.isNotEmpty &&
            oldWidget.sentences.first.index != widget.sentences.first.index)) {
      _disposeRecognizers();
      _buildRecognizers();
    }
  }

  void _buildRecognizers() {
    final onTapSentence = widget.onTapSentence;
    _recognizers = onTapSentence == null
        ? null
        : [
            for (final s in widget.sentences)
              TapGestureRecognizer()..onTap = () => onTapSentence(s),
          ];
  }

  void _disposeRecognizers() {
    for (final r in _recognizers ?? const <TapGestureRecognizer>[]) {
      r.dispose();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sentences = widget.sentences;

    if (sentences.every((s) => !s.isSpeakable)) {
      return SizedBox(height: widget.fontSize * 0.6);
    }

    final base = TextStyle(
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      color: theme.colorScheme.onSurface,
    );
    // Colour only, never weight: a bolder run is wider and would reflow the
    // lines it sits on. That matters more now the highlight is a whole
    // chunk — several sentences, possibly running on to the next page —
    // and the pages were measured without it.
    final highlight = base.copyWith(
      color: theme.colorScheme.onPrimaryContainer,
      backgroundColor: theme.colorScheme.primaryContainer,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            for (var i = 0; i < sentences.length; i++)
              for (final (text, lit) in highlightParts(
                sentences[i],
                widget.highlight,
                trailingSpace: i < sentences.length - 1,
              ))
                TextSpan(
                  text: text,
                  style: lit ? highlight : base,
                  recognizer: _recognizers?[i],
                ),
          ],
        ),
        textAlign: TextAlign.justify,
      ),
    );
  }
}

/// Shown in place of a locked chapter's content when the device hasn't
/// linked to a user yet — sign-in unlocks whichever entitlements that
/// account has, then the chapter is reloaded automatically.
class _LoginPrompt extends StatefulWidget {
  const _LoginPrompt({required this.controller});

  final ReaderController controller;

  @override
  State<_LoginPrompt> createState() => _LoginPromptState();
}

class _LoginPromptState extends State<_LoginPrompt> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn(Future<void> Function() signIn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await signIn();
      await widget.controller.retryCurrentChapter();
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Đăng nhập thất bại: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Đăng nhập thất bại')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<DeviceAuth>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline, size: 48),
        const SizedBox(height: 12),
        const Text('Chương này cần đăng nhập để đọc.'),
        const SizedBox(height: 20),
        if (_busy)
          const CircularProgressIndicator()
        else ...[
          if (showAppleSignIn) ...[
            AppleSignInButton(onPressed: () => _signIn(auth.signInWithApple)),
            const SizedBox(height: 12),
          ],
          GoogleSignInButton(onPressed: () => _signIn(auth.signInWithGoogle)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }
}

/// Shown when the signed-in user has no entitlement covering this book. The
/// MVP has no in-app purchase flow yet (see the backend plan) — admin grants
/// entitlements by hand — so this just explains the state.
class _EntitlementPrompt extends StatelessWidget {
  const _EntitlementPrompt();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_clock_outlined, size: 48),
        SizedBox(height: 12),
        Text(
          'Truyện này chưa được mở khoá cho tài khoản của bạn.\n'
          'Liên hệ để được mở khoá.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// [sentence] as shown on the page, split into the pieces inside and outside
/// [highlight] (a chapter range): the range being read needn't start or end
/// on a sentence boundary. [trailingSpace] adds the space between it and the
/// next sentence, lit only when the highlight carries on past it, so a lit
/// stretch reads as one band.
@visibleForTesting
List<(String, bool)> highlightParts(
  Sentence sentence,
  (int, int)? highlight, {
  required bool trailingSpace,
}) {
  final text = sentence.text;
  if (text.isEmpty) return const [];
  final space = trailingSpace ? ' ' : '';
  final lit = highlight == null ? null : sentence.overlap(highlight.$1, highlight.$2);
  if (lit == null) return [('$text$space', false)];

  final (from, to) = lit;
  final litSpace = to == text.length && highlight!.$2 > sentence.textEnd;
  return [
    if (from > 0) (text.substring(0, from), false),
    (text.substring(from, to) + (litSpace ? space : ''), true),
    if (to < text.length) (text.substring(to) + space, false)
    else if (!litSpace && space.isNotEmpty) (space, false),
  ];
}
