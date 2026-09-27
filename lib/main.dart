import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/api_client.dart';
import 'services/device_auth.dart';
import 'services/library_repository.dart';
import 'services/licenses.dart';
import 'services/remote_book_service.dart';
import 'services/settings_store.dart';
import 'services/voice_repository.dart';
import 'state/app_settings.dart';
import 'state/library_controller.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  final store = await SettingsStore.open();
  final deviceAuth = DeviceAuth();
  final apiClient = ApiClient(deviceAuth);
  final remoteBooks = RemoteBookService(apiClient);
  final library = LibraryRepository(remote: remoteBooks);
  final voices = VoiceRepository();

  runApp(AudioBookApp(
    store: store,
    library: library,
    voices: voices,
    deviceAuth: deviceAuth,
    remoteBooks: remoteBooks,
  ));
}

class AudioBookApp extends StatelessWidget {
  const AudioBookApp({
    super.key,
    required this.store,
    required this.library,
    required this.voices,
    required this.deviceAuth,
    required this.remoteBooks,
  });

  final SettingsStore store;
  final LibraryRepository library;
  final VoiceRepository voices;
  final DeviceAuth deviceAuth;
  final RemoteBookService remoteBooks;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: store),
        Provider.value(value: library),
        Provider.value(value: voices),
        Provider.value(value: deviceAuth),
        Provider.value(value: remoteBooks),
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
          title: 'Tàng Kinh Các',
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
