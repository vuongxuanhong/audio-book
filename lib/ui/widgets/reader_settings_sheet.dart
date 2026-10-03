import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';
import '../../state/reader_controller.dart';

/// Must be called from inside the reader: the sheet is its own route, so the
/// [ReaderController] is handed over explicitly.
Future<void> showReaderSettingsSheet(BuildContext context) {
  final controller = context.read<ReaderController>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: controller,
      child: const _ReaderSettings(),
    ),
  );
}

class _ReaderSettings extends StatelessWidget {
  const _ReaderSettings();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    // Speed and following the spoken sentence only mean something when
    // there is narration to play.
    final reader = context.watch<ReaderController>();
    final canListen = reader.canListen || reader.isPlaying;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tốc độ đọc', style: Theme.of(context).textTheme.titleMedium),
            if (!canListen && reader.listenUnavailableReason != null) ...[
              const SizedBox(height: 4),
              Text(
                reader.listenUnavailableReason!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            _SpeedSelector(settings: settings, enabled: canListen),
            const Divider(height: 28),
            Text('Hiển thị', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tự động lật trang theo câu đang đọc'),
              value: settings.autoScroll,
              onChanged: canListen ? settings.setAutoScroll : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// One button per speed in [AppSettings.speedSteps].
class _SpeedSelector extends StatelessWidget {
  const _SpeedSelector({required this.settings, required this.enabled});

  final AppSettings settings;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<double>(
        segments: [
          for (final speed in AppSettings.speedSteps)
            ButtonSegment(value: speed, label: Text(_label(speed))),
        ],
        selected: {settings.speed},
        showSelectedIcon: false,
        onSelectionChanged: enabled
            ? (selection) => settings.setSpeed(selection.first)
            : null,
      ),
    );
  }

  /// 1.0 → "1.0×", 0.75 → "0.75×".
  static String _label(double v) =>
      '${v == v.roundToDouble() ? v.toStringAsFixed(1) : v}×';
}
