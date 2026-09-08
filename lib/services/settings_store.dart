import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_progress.dart';

/// Small key-value state: reading positions, playback speed, font size and the
/// selected voice. Everything here is cheap enough for SharedPreferences.
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
  static const _kSentencePause = 'playback.sentencePauseMs';
  static const _kParagraphPause = 'playback.paragraphPauseMs';
  static const _kClausePause = 'playback.clausePauseMs';
  static const _kBeatPause = 'playback.beatPauseMs';
  static const _kVoiceId = 'tts.voiceId';
  static const _kSpeakerPrefix = 'tts.speaker.';
  static const _kLastBookId = 'library.lastBookId';

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

  double get sentencePauseMs =>
      _prefs.getDouble(_kSentencePause) ?? 700;
  Future<void> setSentencePauseMs(double v) =>
      _prefs.setDouble(_kSentencePause, v);

  double get paragraphPauseMs =>
      _prefs.getDouble(_kParagraphPause) ?? 1100;
  Future<void> setParagraphPauseMs(double v) =>
      _prefs.setDouble(_kParagraphPause, v);

  /// Silence at a scene break — a line of "……" and nothing else. Audiobook
  /// practice puts a section break at 2–2.5 s.
  double get beatPauseMs => _prefs.getDouble(_kBeatPause) ?? 2000;
  Future<void> setBeatPauseMs(double v) => _prefs.setDouble(_kBeatPause, v);

  /// Silence at a comma inside a sentence — the shortest of the breaks.
  double get clausePauseMs => _prefs.getDouble(_kClausePause) ?? 300;
  Future<void> setClausePauseMs(double v) =>
      _prefs.setDouble(_kClausePause, v);

  bool get autoScroll => _prefs.getBool(_kAutoScroll) ?? true;
  Future<void> setAutoScroll(bool v) => _prefs.setBool(_kAutoScroll, v);

  String? get voiceId => _prefs.getString(_kVoiceId);
  Future<void> setVoiceId(String id) => _prefs.setString(_kVoiceId, id);

  /// Speaker ids only mean something within one pack, so they are stored per
  /// voice rather than as a single global number.
  int speakerFor(String voiceId) =>
      _prefs.getInt('$_kSpeakerPrefix$voiceId') ?? 0;
  Future<void> setSpeakerFor(String voiceId, int sid) =>
      _prefs.setInt('$_kSpeakerPrefix$voiceId', sid);

  String? get lastBookId => _prefs.getString(_kLastBookId);
  Future<void> setLastBookId(String id) => _prefs.setString(_kLastBookId, id);
}
