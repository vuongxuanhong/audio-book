import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

Future<Uri?>? _art;

/// The app icon as a file URI, for the lock screen and the media
/// notification — they load artwork from a URI, not from the asset bundle.
Future<Uri?> nowPlayingArt() => _art ??= _writeArt();

Future<Uri?> _writeArt() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/now_playing_art.png');
    if (!file.existsSync()) {
      final data = await rootBundle.load('assets/icon/about_icon.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return file.uri;
  } on Object {
    return null;
  }
}
