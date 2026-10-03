import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/api_client.dart';
import 'services/app_update_service.dart';
import 'services/audio_cache.dart';
import 'services/device_auth.dart';
import 'services/library_repository.dart';
import 'services/progress_sync.dart';
import 'services/remote_book_service.dart';
import 'services/settings_store.dart';
import 'state/app_settings.dart';
import 'state/library_controller.dart';
import 'ui/library_screen.dart';
import 'ui/update_gate.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Listening keeps going with the screen off or the app in the background.
  // The notification and lock-screen controls only appear once the reader
  // starts speaking, and go away when it stops.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.hongngoc.audionovel.channel.audio',
    androidNotificationChannelName: 'Nghe truyện',
    androidNotificationIcon: 'drawable/ic_stat_listen',
    androidNotificationOngoing: true,
  );
  // Spoken word, not music: iOS pauses (rather than ducks) it for other
  // speech such as navigation prompts, and calls pause it.
  await (await AudioSession.instance)
      .configure(const AudioSessionConfiguration.speech());
  final store = await SettingsStore.open();
  final deviceAuth = DeviceAuth();
  final apiClient = ApiClient(deviceAuth);
  final remoteBooks = RemoteBookService(apiClient);
  final prefs = await SharedPreferences.getInstance();
  final progressSync = ProgressSync(apiClient, remoteBooks, prefs)..start();
  final library = LibraryRepository(remote: remoteBooks, sync: progressSync);
  final audioCache = AudioCache();

  runApp(AudioBookApp(
    store: store,
    library: library,
    deviceAuth: deviceAuth,
    remoteBooks: remoteBooks,
    audioCache: audioCache,
    updateService: AppUpdateService(prefs),
  ));
}

class AudioBookApp extends StatelessWidget {
  const AudioBookApp({
    super.key,
    required this.store,
    required this.library,
    required this.deviceAuth,
    required this.remoteBooks,
    required this.audioCache,
    required this.updateService,
  });

  final SettingsStore store;
  final LibraryRepository library;
  final DeviceAuth deviceAuth;
  final RemoteBookService remoteBooks;
  final AudioCache audioCache;
  final AppUpdateService updateService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: store),
        Provider.value(value: library),
        Provider.value(value: deviceAuth),
        Provider.value(value: remoteBooks),
        Provider.value(value: audioCache),
        ChangeNotifierProvider(create: (_) => AppSettings(store)),
        ChangeNotifierProvider(
          create: (_) => LibraryController(library, store, remoteBooks)..refresh(),
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
          navigatorKey: _navigatorKey,
          builder: (context, child) => UpdateGate(
            service: updateService,
            navigatorKey: _navigatorKey,
            child: child!,
          ),
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
    final light = brightness == Brightness.light;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor:
          light ? const Color(0xFFFBF8F3) : const Color(0xFF14131A),
      // In light mode the default bar colour (surface) is all but the same
      // as the cream page, so the bar didn't read as a bar. The reader's own
      // top bar uses the same colour.
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: light ? scheme.primaryContainer : null,
        foregroundColor: light ? scheme.onPrimaryContainer : null,
      ),
    );
  }
}
