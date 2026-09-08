import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';
import '../../state/reader_controller.dart';

/// The bar pinned to the bottom of the reader: play/pause, sentence and
/// chapter skipping, speed, and a thin chapter-progress line.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final enabled =
        controller.status == ReaderStatus.ready && !controller.voiceMissing;

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: controller.chapterFraction,
              minHeight: 3,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Chương trước',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: controller.chapterIndex > 0
                        ? controller.previousChapter
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Câu trước',
                    icon: const Icon(Icons.fast_rewind),
                    onPressed: enabled ? () => controller.skipSentence(-1) : null,
                  ),
                  const SizedBox(width: 4),
                  _PlayButton(controller: controller, enabled: enabled),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Câu tiếp',
                    icon: const Icon(Icons.fast_forward),
                    onPressed: enabled ? () => controller.skipSentence(1) : null,
                  ),
                  IconButton(
                    tooltip: 'Chương sau',
                    icon: const Icon(Icons.skip_next),
                    onPressed:
                        controller.chapterIndex + 1 < controller.book.chapterCount
                            ? controller.nextChapter
                            : null,
                  ),
                  const Spacer(),
                  _SpeedChip(settings: settings),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller, required this.enabled});

  final ReaderController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (controller.isBuffering)
            const SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          FloatingActionButton(
            heroTag: 'reader-play',
            elevation: 0,
            onPressed: enabled ? controller.toggle : null,
            child: Icon(controller.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ],
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Tốc độ đọc',
      initialValue: settings.speed,
      onSelected: settings.setSpeed,
      itemBuilder: (_) => [
        for (final s in AppSettings.speedSteps)
          PopupMenuItem<double>(
            value: s,
            child: Text('${_fmt(s)}×'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 20),
            const SizedBox(width: 6),
            Text('${_fmt(settings.speed)}×',
                style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : v.toString();
}
