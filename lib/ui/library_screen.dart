import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../state/library_controller.dart';
import 'reader_screen.dart';
import 'voice_screen.dart';
import 'widgets/app_settings_sheet.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tủ sách'),
        actions: [
          IconButton(
            tooltip: 'Giọng đọc',
            icon: const Icon(Icons.record_voice_over_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const VoiceScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Cài đặt',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showAppSettingsSheet(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _import(context),
        icon: const Icon(Icons.add),
        label: const Text('Thêm truyện'),
      ),
      body: switch (controller) {
        LibraryController(loading: true) =>
          const Center(child: CircularProgressIndicator()),
        LibraryController(error: final e?) => _Message(
            icon: Icons.error_outline,
            title: 'Không đọc được tủ sách',
            body: e,
          ),
        LibraryController(books: final books) when books.isEmpty => _Message(
            icon: Icons.menu_book_outlined,
            title: 'Chưa có truyện nào',
            body:
                'Bấm “Thêm truyện” để nhập một tệp .txt tiếng Việt. Ứng dụng sẽ tự tách chương.',
            action: TextButton.icon(
              onPressed: () => _importSample(context),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Dùng truyện mẫu'),
            ),
          ),
        _ => RefreshIndicator(
            onRefresh: controller.refresh,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: controller.books.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _BookTile(book: controller.books[i]),
            ),
          ),
      },
    );
  }

  Future<void> _import(BuildContext context) async {
    final controller = context.read<LibraryController>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Chọn tệp truyện (.txt, .epub)',
      type: FileType.custom,
      allowedExtensions: ['txt', 'text', 'md', 'epub'],
    );
    final path = picked?.path;
    if (path == null) return;
    if (!context.mounted) return;

    try {
      final book = await _runWithProgress(
        context,
        () => controller.importFile(File(path)),
      );
      messenger.showSnackBar(SnackBar(
        content: Text('Đã nhập “${book.title}” · ${book.chapterCount} chương'),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Nhập thất bại: $e')));
    }
  }
}

Future<void> _importSample(BuildContext context) async {
  final controller = context.read<LibraryController>();
  final messenger = ScaffoldMessenger.of(context);
  final text = await rootBundle.loadString('assets/sample/truyen_mau.txt');
  if (!context.mounted) return;
  final book = await _runWithProgress(
    context,
    () => controller.importText(text, 'Truyện mẫu'),
  );
  messenger.showSnackBar(
    SnackBar(content: Text('Đã nhập “${book.title}”')),
  );
}

/// Parsing a whole book (splitting into chapters/sentences, or unzipping an
/// EPUB) can take a couple of seconds for a long book — without feedback that
/// reads as the app having frozen. Blocks input with a small progress dialog
/// for the duration of [action].
Future<T> _runWithProgress<T>(
  BuildContext context,
  Future<T> Function() action,
) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _ImportProgressDialog(),
  );
  try {
    return await action();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

class _ImportProgressDialog extends StatelessWidget {
  const _ImportProgressDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Text('Đang nhập truyện…', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();
    final progress = controller.progressFor(book.id);
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => ReaderScreen(book: book)),
          );
          if (context.mounted) context.read<LibraryController>().refresh();
        },
        onLongPress: () => _showActions(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: theme.colorScheme.primaryContainer,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.auto_stories_outlined,
                    color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(book.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(
                      '${book.chapterCount} chương · ${_kChars(book.totalChars)} chữ',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: controller.progressFraction(book),
                          minHeight: 5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Đang đọc: ${book.chapters[progress.chapterIndex.clamp(0, book.chapterCount - 1)].title}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _kChars(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  void _showActions(BuildContext context) {
    final controller = context.read<LibraryController>();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Đọc lại từ đầu'),
              onTap: () {
                controller.resetProgress(book);
                Navigator.pop(sheet);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Xoá truyện'),
              onTap: () {
                controller.delete(book);
                Navigator.pop(sheet);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
