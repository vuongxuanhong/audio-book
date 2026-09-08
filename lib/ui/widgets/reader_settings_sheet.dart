import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';

Future<void> showReaderSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ReaderSettings(),
  );
}

class _ReaderSettings extends StatelessWidget {
  const _ReaderSettings();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hiển thị', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _Slider(
              label: 'Cỡ chữ',
              value: settings.fontSize,
              min: 12,
              max: 34,
              divisions: 22,
              display: settings.fontSize.toStringAsFixed(0),
              onChanged: settings.setFontSize,
            ),
            _Slider(
              label: 'Giãn dòng',
              value: settings.lineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 12,
              display: settings.lineHeight.toStringAsFixed(1),
              onChanged: settings.setLineHeight,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tự cuộn theo câu đang đọc'),
              value: settings.autoScroll,
              onChanged: settings.setAutoScroll,
            ),
            const Divider(height: 28),
            Text('Nhịp đọc', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _Slider(
              label: 'Nghỉ hết câu',
              value: settings.sentencePauseMs,
              min: 0,
              max: 1000,
              divisions: 10,
              display: '${(settings.sentencePauseMs / 1000).toStringAsFixed(1)}s',
              onChanged: settings.setSentencePauseMs,
            ),
            _Slider(
              label: 'Nghỉ giữa đoạn',
              value: settings.paragraphPauseMs,
              min: 0,
              max: 1500,
              divisions: 15,
              display: '${(settings.paragraphPauseMs / 1000).toStringAsFixed(1)}s',
              onChanged: settings.setParagraphPauseMs,
            ),
            _Slider(
              label: 'Nghỉ ở dấu phẩy',
              value: settings.clausePauseMs,
              min: 0,
              max: 800,
              divisions: 8,
              display: '${(settings.clausePauseMs / 1000).toStringAsFixed(1)}s',
              onChanged: settings.setClausePauseMs,
            ),
            _Slider(
              label: 'Ngắt cảnh',
              value: settings.beatPauseMs,
              min: 0,
              max: 3000,
              divisions: 15,
              display: '${(settings.beatPauseMs / 1000).toStringAsFixed(1)}s',
              onChanged: settings.setBeatPauseMs,
            ),
            Text(
              'Bốn mức, ngắn dần: ngắt cảnh (dòng chỉ có “……”), hết đoạn, '
              'hết câu, dấu phẩy. Mặc định lấy theo tài liệu về nhịp đọc '
              '(xem README).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 108, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 40, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }
}
