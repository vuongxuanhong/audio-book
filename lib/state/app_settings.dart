import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../services/settings_store.dart';

class AppSettings extends ChangeNotifier {
  AppSettings(this._store)
      : _speed = _store.speed,
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

  static const speedSteps = <double>[0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

  void setSpeed(double value) {
    final clamped = value.clamp(0.5, 2.0).toDouble();
    if (clamped == _speed) return;
    _speed = clamped;
    _store.setSpeed(clamped);
    notifyListeners();
  }

  /// Cycles to the next preset — what the little "1.25×" chip in the player
  /// bar does.
  void nextSpeed() {
    final i = speedSteps.indexWhere((s) => s > _speed + 0.001);
    setSpeed(i == -1 ? speedSteps.first : speedSteps[i]);
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
