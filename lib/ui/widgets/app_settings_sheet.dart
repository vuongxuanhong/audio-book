import 'package:flutter/material.dart';
import '../about_screen.dart';

/// The app's own settings, reachable outside of any open book — today just
/// a link to the About screen. The light/dark toggle sits in the app bars
/// (ThemeToggleButton); reading controls (speed, page following) live in
/// `reader_settings_sheet.dart`, since they only make sense with a book open.
Future<void> showAppSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _AppSettings(),
  );
}

class _AppSettings extends StatelessWidget {
  const _AppSettings();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: const Text('Giới thiệu & giấy phép'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context)
                  ..pop()
                  ..push(MaterialPageRoute<void>(
                    builder: (_) => const AboutScreen(),
                  ));
              },
            ),
          ],
        ),
      ),
    );
  }
}
