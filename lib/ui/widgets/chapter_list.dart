import 'package:flutter/material.dart';

import '../../models/book.dart';

Future<int?> showChapterPicker(
  BuildContext context, {
  required List<ChapterRef> chapters,
  required int current,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        // Open the sheet already parked on the chapter being read.
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text('Mục lục', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Text('${chapters.length} chương',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: chapters.length,
                itemBuilder: (context, i) {
                  final selected = i == current;
                  final locked = !chapters[i].isFree;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    leading: Text('${i + 1}',
                        style: Theme.of(context).textTheme.bodySmall),
                    title: Text(chapters[i].title,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: selected
                        ? const Icon(Icons.play_arrow, size: 18)
                        : locked
                            ? Icon(Icons.lock_outline,
                                size: 16,
                                color: Theme.of(context).colorScheme.outline)
                            : null,
                    onTap: () => Navigator.pop(sheet, i),
                  );
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}
