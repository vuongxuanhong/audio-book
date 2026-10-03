import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';
import '../about_screen.dart';
import 'theme_mode_selector.dart';

/// The app's own settings, reachable outside of any open book — today just
/// the theme and a link to the About screen. Reading-specific controls (speed, page following) live in
/// `reader_settings_sheet.dart` instead, since they only make sense with a
/// book open.
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
    final settings = context.watch<AppSettings>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Giao diện', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ThemeModeSelector(
              value: settings.themeMode,
              onChanged: settings.setThemeMode,
            ),
            const SizedBox(height: 16),
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
