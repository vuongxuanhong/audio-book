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
            _SpeedSlider(settings: settings, enabled: canListen),
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

/// Speed only has a fixed, unevenly-spaced set of steps (see
/// [AppSettings.speedSteps]), so this drags an index into that list rather
/// than a continuous value.
class _SpeedSlider extends StatelessWidget {
  const _SpeedSlider({required this.settings, required this.enabled});

  final AppSettings settings;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final steps = AppSettings.speedSteps;
    final index = steps.indexWhere((s) => (s - settings.speed).abs() < 0.001);
    final display = '${_fmt(settings.speed)}×';

    return Row(
      children: [
        const SizedBox(width: 108, child: Text('Tốc độ')),
        Expanded(
          child: Slider(
            value: (index == -1 ? 3 : index).toDouble(),
            min: 0,
            max: (steps.length - 1).toDouble(),
            divisions: steps.length - 1,
            label: display,
            onChanged:
                enabled ? (v) => settings.setSpeed(steps[v.round()]) : null,
          ),
        ),
        SizedBox(width: 40, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : v.toString();
}
