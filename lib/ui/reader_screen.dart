import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/book.dart';
import '../models/sentence.dart';
import '../services/library_repository.dart';
import '../services/settings_store.dart';
import '../services/voice_repository.dart';
import '../state/app_settings.dart';
import '../state/reader_controller.dart';
import 'voice_screen.dart';
import 'widgets/chapter_list.dart';
import 'widgets/player_bar.dart';
import 'widgets/reader_settings_sheet.dart';

class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key, required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ReaderController>(
      create: (_) => ReaderController(
        book: book,
        library: context.read<LibraryRepository>(),
        voices: context.read<VoiceRepository>(),
        store: context.read<SettingsStore>(),
        settings: context.read<AppSettings>(),
      ),
      child: const _ReaderView(),
    );
  }
}

class _ReaderView extends StatefulWidget {
  const _ReaderView();

  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  ReaderController? _controller;
  int _lastScrolledParagraph = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<ReaderController>();
    if (identical(controller, _controller)) return;
    _controller?.highlightTick.removeListener(_onHighlightMoved);
    _controller = controller..highlightTick.addListener(_onHighlightMoved);
    _positions.itemPositions.addListener(_onScrolled);
  }

  void _onScrolled() {
    final controller = _controller;
    if (controller == null || controller.isPlaying) return;
    if (controller.isAutoScrolling) return;

    final visible = _positions.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .toList();
    if (visible.isEmpty) return;
    visible.sort((a, b) => a.index.compareTo(b.index));

    // The user moved the page themselves, so whatever we centred last is no
    // longer where they are looking.
    _lastScrolledParagraph = -1;
    controller.noteVisibleRange(visible.first.index, visible.last.index);
  }

  /// Keeps the spoken sentence on screen. Only fires when the paragraph
  /// changes so a long paragraph is not re-centred on every sentence.
  Future<void> _onHighlightMoved() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    if (!context.read<AppSettings>().autoScroll) return;
    if (!_itemScroll.isAttached) return;

    final target = controller.currentParagraph;
    if (target == _lastScrolledParagraph) return;
    _lastScrolledParagraph = target;

    // Tell the controller this scroll is ours, so the positions it emits are
    // not read back as the user browsing away from the chosen sentence.
    controller.beginAutoScroll();
    try {
      await _itemScroll.scrollTo(
        index: target,
        alignment: 0.32,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } finally {
      controller.endAutoScroll();
    }
  }

  @override
  void dispose() {
    _controller?.highlightTick.removeListener(_onHighlightMoved);
    _positions.itemPositions.removeListener(_onScrolled);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    final settings = context.watch<AppSettings>();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(controller.book.title,
                style: Theme.of(context).textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (controller.status == ReaderStatus.ready)
              Text(
                controller.chapter.title,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Mục lục',
            icon: const Icon(Icons.list_alt),
            onPressed: () => _openChapters(context, controller),
          ),
          IconButton(
            tooltip: 'Hiển thị',
            icon: const Icon(Icons.text_fields),
            onPressed: () => showReaderSettingsSheet(context),
          ),
        ],
      ),
      body: Column(
        children: [
          if (controller.voiceMissing) _VoiceBanner(controller: controller),
          if (controller.error != null)
            MaterialBanner(
              content: Text(controller.error!),
              actions: [
                TextButton(
                  onPressed: controller.reloadVoice,
                  child: const Text('Thử lại'),
                ),
              ],
            ),
          Expanded(
            child: switch (controller.status) {
              ReaderStatus.loading =>
                const Center(child: CircularProgressIndicator()),
              ReaderStatus.error => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(controller.error ?? 'Không mở được chương'),
                  ),
                ),
              ReaderStatus.ready => ScrollablePositionedList.builder(
                  itemScrollController: _itemScroll,
                  itemPositionsListener: _positions,
                  initialScrollIndex: controller.currentParagraph,
                  initialAlignment: 0.1,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  itemCount: controller.paragraphs.length,
                  itemBuilder: (context, index) => _ParagraphView(
                    paragraph: controller.paragraphs[index],
                    cursor: controller.cursor,
                    fontSize: settings.fontSize,
                    lineHeight: settings.lineHeight,
                    onTapSentence: (s) => controller.jumpTo(s.index),
                  ),
                ),
            },
          ),
          const PlayerBar(),
        ],
      ),
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

class _ParagraphView extends StatefulWidget {
  const _ParagraphView({
    required this.paragraph,
    required this.cursor,
    required this.fontSize,
    required this.lineHeight,
    required this.onTapSentence,
  });

  final Paragraph paragraph;
  final int cursor;
  final double fontSize;
  final double lineHeight;
  final void Function(Sentence) onTapSentence;

  @override
  State<_ParagraphView> createState() => _ParagraphViewState();
}

class _ParagraphViewState extends State<_ParagraphView> {
  // Recognizers own native gesture state, so they are built once per paragraph
  // rather than on every highlight change.
  late List<TapGestureRecognizer> _recognizers;

  @override
  void initState() {
    super.initState();
    _buildRecognizers();
  }

  @override
  void didUpdateWidget(covariant _ParagraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paragraph.index != widget.paragraph.index ||
        oldWidget.paragraph.sentences.length !=
            widget.paragraph.sentences.length) {
      _disposeRecognizers();
      _buildRecognizers();
    }
  }

  void _buildRecognizers() {
    _recognizers = [
      for (final s in widget.paragraph.sentences)
        TapGestureRecognizer()..onTap = () => widget.onTapSentence(s),
    ];
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
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
    final paragraph = widget.paragraph;

    if (paragraph.isBlank) return SizedBox(height: widget.fontSize * 0.6);

    final base = TextStyle(
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      color: theme.colorScheme.onSurface,
    );
    final highlight = base.copyWith(
      color: theme.colorScheme.onPrimaryContainer,
      fontWeight: FontWeight.w600,
      backgroundColor: theme.colorScheme.primaryContainer,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            for (var i = 0; i < paragraph.sentences.length; i++)
              TextSpan(
                text: _display(paragraph.sentences[i], i),
                style: paragraph.sentences[i].index == widget.cursor
                    ? highlight
                    : base,
                recognizer: _recognizers[i],
              ),
          ],
        ),
        textAlign: TextAlign.justify,
      ),
    );
  }

  String _display(Sentence s, int i) {
    if (s.text.isEmpty) return '';
    return i == widget.paragraph.sentences.length - 1 ? s.text : '${s.text} ';
  }
}

class _VoiceBanner extends StatelessWidget {
  const _VoiceBanner({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      leading: const Icon(Icons.download_outlined),
      content: const Text(
        'Chưa có giọng đọc offline. Tải một gói giọng để nghe truyện.',
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const VoiceScreen()),
            );
            await controller.reloadVoice();
          },
          child: const Text('Tải giọng đọc'),
        ),
      ],
    );
  }
}
