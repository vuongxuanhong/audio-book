import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_progress.dart';

/// Small key-value state: reading positions, playback speed, font size and
/// the theme. Everything here is cheap enough for SharedPreferences.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  static const _kProgressPrefix = 'progress.';
  static const _kSpeed = 'playback.speed';
  static const _kFontSize = 'reader.fontSize';
  static const _kLineHeight = 'reader.lineHeight';
  static const _kAutoScroll = 'reader.autoScroll';
  static const _kLastBookId = 'library.lastBookId';
  static const _kThemeMode = 'app.themeMode';

  ReadingProgress? progressFor(String bookId) {
    final raw = _prefs.getString('$_kProgressPrefix$bookId');
    if (raw == null) return null;
    try {
      return ReadingProgress.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> saveProgress(ReadingProgress progress) =>
      _prefs.setString(
        '$_kProgressPrefix${progress.bookId}',
        jsonEncode(progress.toJson()),
      );

  Future<void> clearProgress(String bookId) =>
      _prefs.remove('$_kProgressPrefix$bookId');

  double get speed => _prefs.getDouble(_kSpeed) ?? 1.0;
  Future<void> setSpeed(double v) => _prefs.setDouble(_kSpeed, v);

  double get fontSize => _prefs.getDouble(_kFontSize) ?? 18.0;
  Future<void> setFontSize(double v) => _prefs.setDouble(_kFontSize, v);

  double get lineHeight => _prefs.getDouble(_kLineHeight) ?? 1.7;
  Future<void> setLineHeight(double v) => _prefs.setDouble(_kLineHeight, v);

  bool get autoScroll => _prefs.getBool(_kAutoScroll) ?? true;
  Future<void> setAutoScroll(bool v) => _prefs.setBool(_kAutoScroll, v);

  String? get lastBookId => _prefs.getString(_kLastBookId);
  Future<void> setLastBookId(String id) => _prefs.setString(_kLastBookId, id);

  /// Stored by name rather than index — safe even if `ThemeMode`'s member
  /// order ever changes. Falls back to `system` for anything unrecognised.
  ThemeMode get themeMode => ThemeMode.values.firstWhere(
        (m) => m.name == _prefs.getString(_kThemeMode),
        orElse: () => ThemeMode.system,
      );
  Future<void> setThemeMode(ThemeMode mode) =>
      _prefs.setString(_kThemeMode, mode.name);
}
