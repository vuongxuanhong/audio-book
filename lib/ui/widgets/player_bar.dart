import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/reader_controller.dart';
import 'reader_settings_sheet.dart';

/// The bar pinned to the bottom of the reader: play/pause, chapter progress,
/// and everything else (speed, font, pacing) tucked behind one settings
/// button. Chapter/sentence navigation lives in the swipe gestures and the
/// chapter picker, not as buttons here — listening only needs to start,
/// stop, see how far along it is, and open settings.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    final theme = Theme.of(context);
    final enabled =
        controller.status == ReaderStatus.ready && !controller.voiceMissing;

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
          child: Row(
            children: [
              _PlayButton(controller: controller, enabled: enabled),
              const SizedBox(width: 8),
              Expanded(
                // Listen mode: how far along the chapter's audio is. Read
                // mode: nothing is playing to show progress for, so this
                // spot names the chapter instead.
                child: controller.isPlaying
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: controller.chapterFraction,
                          minHeight: 6,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                        ),
                      )
                    : Text(
                        'Chương ${controller.chapterIndex + 1}/'
                        '${controller.book.chapterCount} - '
                        '${(controller.chapterFraction * 100).round()}%',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
              ),
              IconButton(
                tooltip: 'Cài đặt',
                icon: const Icon(Icons.tune),
                onPressed: () => showReaderSettingsSheet(context),
              ),
            ],
          ),
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
