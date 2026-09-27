import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/remote_book_service.dart';
import '../state/library_controller.dart';
import 'reader_screen.dart';

/// Browses the server-hosted catalog (`GET /v1/books`, cursor-paginated) and
/// imports a chosen book into the local library the same way a local
/// .txt/.epub import does — it shows up in Tủ sách immediately, before any
/// chapter content has been downloaded.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final List<RemoteBookSummary> _items = [];
  String? _cursor;
  bool _loadingFirstPage = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final service = context.read<RemoteBookService>();
      final page = await service.fetchCatalog(cursor: _cursor);
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _hasMore = _cursor != null;
        _error = null;
      });
    } on Object catch (e) {
      setState(() => _error = 'Không tải được kho truyện: $e');
    } finally {
      setState(() {
        _loadingFirstPage = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _open(RemoteBookSummary item) async {
    final controller = context.read<LibraryController>();
    final service = context.read<RemoteBookService>();
    final messenger = ScaffoldMessenger.of(context);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _LoadingDialog(),
    );
    try {
      final meta = await service.fetchBookMeta(item.id);
      final book = await controller.importFromRemote(meta);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close dialog
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReaderScreen(book: book)),
      );
    } on Object catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(content: Text('Không mở được truyện: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kho truyện')),
      body: switch (true) {
        _ when _loadingFirstPage => const Center(child: CircularProgressIndicator()),
        _ when _error != null && _items.isEmpty => _ErrorMessage(text: _error!),
        _ when _items.isEmpty => const _ErrorMessage(text: 'Kho truyện hiện chưa có sách nào.'),
        _ => NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 200) {
                _loadMore();
              }
              return false;
            },
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: _items.length + (_hasMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                if (i >= _items.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return _CatalogTile(item: _items[i], onTap: () => _open(_items[i]));
              },
            ),
          ),
      },
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({required this.item, required this.onTap});

  final RemoteBookSummary item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.cloud_download_outlined, color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${item.chapterCount} chương'),
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
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 20),
          Text('Đang tải truyện…', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
