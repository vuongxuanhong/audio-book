import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../services/settings_store.dart';

class AppSettings extends ChangeNotifier {
  AppSettings(this._store)
      : _speed = nearestSpeed(_store.speed),
        _fontSize = _store.fontSize,
        _lineHeight = _store.lineHeight,
        _autoScroll = _store.autoScroll,
        _themeMode = _store.themeMode;

  final SettingsStore _store;

  double _speed;
  double _fontSize;
  double _lineHeight;
  bool _autoScroll;
  ThemeMode _themeMode;

  double get speed => _speed;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  bool get autoScroll => _autoScroll;
  ThemeMode get themeMode => _themeMode;

  /// The reading speeds on offer.
  static const speedSteps = <double>[0.75, 1.0, 1.25, 1.5];

  /// The offered speed closest to [value] — e.g. a speed saved by an earlier
  /// version, which offered more of them.
  static double nearestSpeed(double value) => speedSteps.reduce(
        (best, s) => (s - value).abs() < (best - value).abs() ? s : best,
      );

  void setSpeed(double value) {
    final speed = nearestSpeed(value);
    if (speed == _speed) return;
    _speed = speed;
    _store.setSpeed(speed);
    notifyListeners();
  }

  void setFontSize(double value) {
    final clamped = value.clamp(12.0, 34.0).toDouble();
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    _store.setFontSize(clamped);
    notifyListeners();
  }

  void setLineHeight(double value) {
    final clamped = value.clamp(1.2, 2.4).toDouble();
    if (clamped == _lineHeight) return;
    _lineHeight = clamped;
    _store.setLineHeight(clamped);
    notifyListeners();
  }

  void setAutoScroll(bool value) {
    if (value == _autoScroll) return;
    _autoScroll = value;
    _store.setAutoScroll(value);
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _store.setThemeMode(mode);
    notifyListeners();
  }
}
