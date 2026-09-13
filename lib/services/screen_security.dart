import 'dart:io';

import 'package:screen_protector/screen_protector.dart';

/// Blocks screenshots and screen recording so book content can't be captured
/// wholesale off the device (Android FLAG_SECURE; iOS secure-view + background
/// blur to hide content in the app switcher). Scoped to the reader screen —
/// call on entry and pair with [disableScreenCaptureProtection] on exit.
Future<void> enableScreenCaptureProtection() async {
  await ScreenProtector.preventScreenshotOn();
  if (Platform.isIOS) {
    await ScreenProtector.protectDataLeakageWithBlur();
  }
}

Future<void> disableScreenCaptureProtection() async {
  await ScreenProtector.preventScreenshotOff();
  if (Platform.isIOS) {
    await ScreenProtector.protectDataLeakageWithBlurOff();
  }
}
