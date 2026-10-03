import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../services/remote_book_service.dart';
import '../state/library_controller.dart';
import 'reader_screen.dart';
import 'widgets/app_settings_sheet.dart';

/// Home: "Đọc tiếp" (books with a saved position on this device), then the
/// server's "Truyện nổi bật" and "Truyện mới". A section with nothing in it
/// isn't shown at all.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();
    final continueReading = controller.continueReading;
    final featured = controller.featured;
    final newBooks = controller.newBooks;
    final empty =
        continueReading.isEmpty && featured.isEmpty && newBooks.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tủ sách'),
        actions: [
          IconButton(
            tooltip: 'Cài đặt',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showAppSettingsSheet(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
              controller.loadMoreNew();
            }
            return false;
          },
          child: CustomScrollView(
            // Pull-to-refresh has to work on the empty and error states too.
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (empty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: switch (controller) {
                    LibraryController(loading: true) =>
                      const Center(child: CircularProgressIndicator()),
                    LibraryController(remoteError: final e?) => _Message(
                        icon: Icons.cloud_off_outlined,
                        title: 'Không tải được truyện',
                        body: e,
                        action: TextButton.icon(
                          onPressed: controller.refresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Thử lại'),
                        ),
                      ),
                    _ => const _Message(
                        icon: Icons.menu_book_outlined,
                        title: 'Chưa có truyện nào',
                        body: 'Truyện mới sẽ xuất hiện ở đây khi có trên máy chủ.',
                      ),
                  },
                ),
              if (!empty && controller.remoteError != null)
                SliverToBoxAdapter(
                  child: _ErrorStrip(
                    text: 'Không tải được danh sách truyện.',
                    onRetry: controller.refresh,
                  ),
                ),
              if (continueReading.isNotEmpty) ...[
                const _SectionHeader('Đọc tiếp'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.separated(
                    itemCount: continueReading.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _ContinueTile(book: continueReading[i]),
                  ),
                ),
              ],
              if (featured.isNotEmpty) ...[
                const _SectionHeader('Truyện nổi bật'),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 228,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: featured.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, i) =>
                          _FeaturedCard(item: featured[i]),
                    ),
                  ),
                ),
              ],
              if (newBooks.isNotEmpty) ...[
                const _SectionHeader('Truyện mới'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.separated(
                    itemCount: newBooks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _NewBookTile(item: newBooks[i]),
                  ),
                ),
                if (controller.hasMoreNew)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _openBook(BuildContext context, Book book) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ReaderScreen(book: book)),
  );
  // Only the reading position can have changed.
  if (context.mounted) context.read<LibraryController>().refreshLibrary();
}

/// Opens a server book, adding it to this device's library first if needed
/// (which fetches its chapter list).
Future<void> _openRemote(BuildContext context, RemoteBookSummary item) async {
  final controller = context.read<LibraryController>();
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _LoadingDialog(),
  );
  final Book book;
  try {
    book = await controller.bookFor(item);
  } on Object catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('Không mở được truyện: $e')));
    return;
  }
  navigator.pop();
  if (context.mounted) await _openBook(context, book);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: scheme.primaryContainer,
      ),
      alignment: Alignment.center,
      child: Icon(Icons.auto_stories_outlined,
          size: width * 0.45, color: scheme.onPrimaryContainer),
    );
  }
}

class _ContinueTile extends StatelessWidget {
  const _ContinueTile({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();
    final progress = controller.progressFor(book.id);
    final theme = Theme.of(context);
    final chapter = progress == null
        ? null
        : book.chapters[progress.chapterIndex.clamp(0, book.chapterCount - 1)];

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _openBook(context, book),
        onLongPress: () => _showActions(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Cover(width: 44, height: 60),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(book.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: controller.progressFraction(book),
                        minHeight: 5,
                      ),
                    ),
                    if (chapter != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Đang đọc: ${chapter.title}',
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
                controller.restart(book);
                Navigator.pop(sheet);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Xoá khỏi Đọc tiếp'),
              onTap: () {
                controller.removeFromContinueReading(book);
                Navigator.pop(sheet);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({required this.item});

  final RemoteBookSummary item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 128,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openRemote(context, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Cover(width: 128, height: 160),
            const SizedBox(height: 8),
            Text(item.title,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            if (item.author.isNotEmpty)
              Text(item.author,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _NewBookTile extends StatelessWidget {
  const _NewBookTile({required this.item});

  final RemoteBookSummary item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _openRemote(context, item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Cover(width: 44, height: 60),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    if (item.author.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(item.author,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text('${item.chapterCount} chương',
                            style: theme.textTheme.bodySmall),
                        if (item.hasAudio) ...[
                          const SizedBox(width: 10),
                          Icon(Icons.headphones_outlined,
                              size: 14, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text('Có bản đọc',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.primary)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          TextButton(onPressed: onRetry, child: const Text('Thử lại')),
        ],
      ),
    );
  }
}

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 20),
          Text('Đang tải truyện…', style: Theme.of(context).textTheme.bodyMedium),
        ],
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
