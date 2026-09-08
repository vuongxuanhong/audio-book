import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/voice.dart';
import '../models/voice_speakers.dart';
import '../services/voice_repository.dart';
import '../state/app_settings.dart';
import 'widgets/speaker_picker_sheet.dart';

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  List<InstalledVoice> _installed = const [];
  bool _loading = true;
  String? _busyId;
  DownloadProgress? _progress;
  CancelToken? _cancel;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    List<InstalledVoice> voices = const [];
    String? error;
    try {
      voices = await context.read<VoiceRepository>().installedVoices();
    } on Object catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _installed = voices;
      _error = error;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return Scaffold(
      appBar: AppBar(title: const Text('Giọng đọc offline')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  'Các gói giọng chạy hoàn toàn trên máy (sherpa-onnx). '
                  'Tải một lần, sau đó không cần mạng.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 16),
                for (final entry in kVoiceCatalog)
                  _VoiceTile(
                    entry: entry,
                    installed: _installedFor(entry.id),
                    selected: settings.voiceId == entry.id,
                    busy: _busyId == entry.id,
                    progress: _busyId == entry.id ? _progress : null,
                    onDownload: () => _download(entry),
                    onCancel: () => _cancel?.cancel(),
                    onSelect: () => settings.setVoiceId(entry.id),
                    onRemove: () => _remove(entry),
                    onPickSpeaker: () {
                      final installed = _installedFor(entry.id);
                      if (installed != null) {
                        showSpeakerPicker(context, installed);
                      }
                    },
                  ),
              ],
            ),
    );
  }

  InstalledVoice? _installedFor(String id) {
    for (final v in _installed) {
      if (v.id == id) return v;
    }
    return null;
  }

  Future<void> _download(VoiceCatalogEntry entry) async {
    final repo = context.read<VoiceRepository>();
    final settings = context.read<AppSettings>();
    final cancel = CancelToken();
    setState(() {
      _busyId = entry.id;
      _cancel = cancel;
      _error = null;
      _progress = const DownloadProgress('Đang chuẩn bị', 0, 0);
    });
    try {
      await repo.download(
        entry,
        cancelToken: cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      settings.setVoiceId(entry.id);
      await _refresh();
    } on VoiceDownloadCancelled {
      // The user pressed cancel; nothing to report.
    } on Object catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busyId = null;
          _progress = null;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _remove(VoiceCatalogEntry entry) async {
    await context.read<VoiceRepository>().remove(entry);
    await _refresh();
  }
}

class _SpeakerRow extends StatelessWidget {
  const _SpeakerRow({required this.voice, required this.onTap});

  final InstalledVoice voice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final sid = settings.speakerFor(voice.id);
    final choice = speakerChoices(voice.id, voice.numSpeakers)
        .firstWhere((c) => c.id == sid, orElse: () => SpeakerChoice(id: sid, pitchHz: 0));

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.record_voice_over_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                choice.detail.isEmpty
                    ? 'Đang dùng ${choice.name}'
                    : 'Đang dùng ${choice.name} · ${choice.detail}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const Text('Đổi'),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}

class _VoiceTile extends StatelessWidget {
  const _VoiceTile({
    required this.entry,
    required this.installed,
    required this.selected,
    required this.busy,
    required this.progress,
    required this.onDownload,
    required this.onCancel,
    required this.onSelect,
    required this.onRemove,
    required this.onPickSpeaker,
  });

  final VoiceCatalogEntry entry;
  final InstalledVoice? installed;
  final bool selected;
  final bool busy;
  final DownloadProgress? progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onSelect;
  final VoidCallback onRemove;
  final VoidCallback onPickSpeaker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isInstalled = installed != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(entry.name, style: theme.textTheme.titleMedium),
                ),
                if (entry.recommended)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Khuyên dùng'),
                    labelStyle: theme.textTheme.labelSmall,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(entry.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('Dung lượng tải: ${entry.sizeLabel}',
                style: theme.textTheme.bodySmall),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress?.fraction),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    progress == null
                        ? 'Đang chuẩn bị…'
                        : '${progress!.phase}'
                            '${progress!.total > 0 ? ' ${(progress!.fraction! * 100).toStringAsFixed(0)}%' : '…'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton(onPressed: onCancel, child: const Text('Huỷ')),
                ],
              ),
            ] else ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (!isInstalled)
                    FilledButton.icon(
                      onPressed: onDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('Tải về'),
                    )
                  else ...[
                    if (selected)
                      const Chip(
                        avatar: Icon(Icons.check, size: 18),
                        label: Text('Đang dùng'),
                      )
                    else
                      OutlinedButton(
                        onPressed: onSelect,
                        child: const Text('Dùng giọng này'),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Xoá khỏi máy',
                      onPressed: onRemove,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ],
              ),
              if (installed != null && installed!.isMultiSpeaker) ...[
                const SizedBox(height: 4),
                _SpeakerRow(voice: installed!, onTap: onPickSpeaker),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
