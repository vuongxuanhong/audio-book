import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../models/voice.dart';
import '../../models/voice_speakers.dart';
import '../../services/tts_engine.dart';
import '../../state/app_settings.dart';

/// Picks one of a pack's speakers. Sixty-five numbered voices are only a real
/// choice if you can hear them, so every row previews on tap.
Future<void> showSpeakerPicker(BuildContext context, InstalledVoice voice) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SpeakerPicker(voice: voice),
  );
}

class _SpeakerPicker extends StatefulWidget {
  const _SpeakerPicker({required this.voice});

  final InstalledVoice voice;

  @override
  State<_SpeakerPicker> createState() => _SpeakerPickerState();
}

class _SpeakerPickerState extends State<_SpeakerPicker> {
  static const _probe = 'Trời vừa hửng sáng, thiếu niên khoác kiếm xuống núi.';

  final TtsEngine _engine = TtsEngine();
  final AudioPlayer _player = AudioPlayer();
  int? _previewing;
  String? _error;

  @override
  void dispose() {
    _player.dispose();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _preview(int sid) async {
    setState(() {
      _previewing = sid;
      _error = null;
    });
    try {
      await _engine.start(widget.voice);
      final clip = await _engine.synthesize(_probe, speakerId: sid);
      if (!mounted) return;
      await _player.setFilePath(clip.path);
      await _player.play();
    } on Object catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted && _previewing == sid) setState(() => _previewing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final selected = settings.speakerFor(widget.voice.id);
    final choices =
        speakerChoices(widget.voice.id, widget.voice.numSpeakers);
    final male = choices.where((c) => c.isMale).toList();
    final female = choices.where((c) => !c.isMale).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Chọn giọng đọc',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '${widget.voice.numSpeakers} giọng trong gói này. '
                  'Chạm để nghe thử và chọn.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (female.isNotEmpty)
                  ..._section(context, 'Giọng nữ', female, selected, settings),
                if (male.isNotEmpty)
                  ..._section(context, 'Giọng nam', male, selected, settings),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    String title,
    List<SpeakerChoice> choices,
    int selected,
    AppSettings settings,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text('$title (${choices.length})',
            style: Theme.of(context).textTheme.labelLarge),
      ),
      for (final c in choices)
        ListTile(
          dense: true,
          selected: c.id == selected,
          leading: _previewing == c.id
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(c.id == selected
                  ? Icons.check_circle
                  : Icons.play_circle_outline),
          title: Text(c.name),
          subtitle: c.detail.isEmpty ? null : Text(c.detail),
          onTap: () {
            settings.setSpeakerFor(widget.voice.id, c.id);
            _preview(c.id);
          },
        ),
    ];
  }
}
