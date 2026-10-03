import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_settings.dart';

/// Switches between light and dark, showing the mode a tap switches to.
/// Picking one sets it explicitly; until the first pick the app follows the
/// system's setting.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppSettings>();
    return Theme.of(context).brightness == Brightness.light
        ? IconButton(
            tooltip: 'Giao diện tối',
            icon: const Icon(Icons.dark_mode_outlined),
            onPressed: () => settings.setThemeMode(ThemeMode.dark),
          )
        : IconButton(
            tooltip: 'Giao diện sáng',
            icon: const Icon(Icons.light_mode_outlined),
            onPressed: () => settings.setThemeMode(ThemeMode.light),
          );
  }
}
