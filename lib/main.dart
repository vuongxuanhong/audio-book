import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/library_repository.dart';
import 'services/settings_store.dart';
import 'services/voice_repository.dart';
import 'state/app_settings.dart';
import 'state/library_controller.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SettingsStore.open();
  final library = LibraryRepository();
  final voices = VoiceRepository();

  runApp(AudioBookApp(store: store, library: library, voices: voices));
}

class AudioBookApp extends StatelessWidget {
  const AudioBookApp({
    super.key,
    required this.store,
    required this.library,
    required this.voices,
  });

  final SettingsStore store;
  final LibraryRepository library;
  final VoiceRepository voices;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: store),
        Provider.value(value: library),
        Provider.value(value: voices),
        ChangeNotifierProvider(create: (_) => AppSettings(store)),
        ChangeNotifierProvider(
          create: (_) => LibraryController(library, store)..refresh(),
        ),
      ],
      // A Consumer here (rather than watching AppSettings directly in this
      // build method) is required: this widget's own context sits above the
      // MultiProvider, so it can't see the provider it just declared.
      child: Consumer<AppSettings>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Audio Book',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: settings.themeMode,
          home: const LibraryScreen(),
        ),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6B4EFF),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFFBF8F3)
          : const Color(0xFF14131A),
      appBarTheme: const AppBarTheme(centerTitle: false),
    );
  }
}
