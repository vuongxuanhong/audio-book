import 'package:flutter/foundation.dart';

import '../services/settings_store.dart';

class AppSettings extends ChangeNotifier {
  AppSettings(this._store)
      : _speed = _store.speed,
        _fontSize = _store.fontSize,
        _lineHeight = _store.lineHeight,
        _autoScroll = _store.autoScroll,
        _sentencePauseMs = _store.sentencePauseMs,
        _paragraphPauseMs = _store.paragraphPauseMs,
        _clausePauseMs = _store.clausePauseMs,
        _beatPauseMs = _store.beatPauseMs,
        _voiceId = _store.voiceId;

  final SettingsStore _store;

  double _speed;
  double _fontSize;
  double _lineHeight;
  bool _autoScroll;
  double _sentencePauseMs;
  double _paragraphPauseMs;
  double _clausePauseMs;
  double _beatPauseMs;
  String? _voiceId;

  double get speed => _speed;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  bool get autoScroll => _autoScroll;

  /// Silence between two sentences of the same paragraph. The voices trim most
  /// of the tail after a full stop, so without this they run together.
  double get sentencePauseMs => _sentencePauseMs;

  /// Silence at a paragraph break, used instead of [sentencePauseMs] there.
  double get paragraphPauseMs => _paragraphPauseMs;

  /// Silence at a comma inside a sentence.
  double get clausePauseMs => _clausePauseMs;

  /// Silence at a scene break — a line of punctuation and nothing else.
  double get beatPauseMs => _beatPauseMs;
  String? get voiceId => _voiceId;

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

  void setSentencePauseMs(double value) {
    final clamped = value.clamp(0.0, 1000.0).toDouble();
    if (clamped == _sentencePauseMs) return;
    _sentencePauseMs = clamped;
    _store.setSentencePauseMs(clamped);
    notifyListeners();
  }

  void setParagraphPauseMs(double value) {
    final clamped = value.clamp(0.0, 1500.0).toDouble();
    if (clamped == _paragraphPauseMs) return;
    _paragraphPauseMs = clamped;
    _store.setParagraphPauseMs(clamped);
    notifyListeners();
  }

  void setBeatPauseMs(double value) {
    final clamped = value.clamp(0.0, 3000.0).toDouble();
    if (clamped == _beatPauseMs) return;
    _beatPauseMs = clamped;
    _store.setBeatPauseMs(clamped);
    notifyListeners();
  }

  void setClausePauseMs(double value) {
    final clamped = value.clamp(0.0, 800.0).toDouble();
    if (clamped == _clausePauseMs) return;
    _clausePauseMs = clamped;
    _store.setClausePauseMs(clamped);
    notifyListeners();
  }

  void setAutoScroll(bool value) {
    if (value == _autoScroll) return;
    _autoScroll = value;
    _store.setAutoScroll(value);
    notifyListeners();
  }

  int speakerFor(String voiceId) => _store.speakerFor(voiceId);

  void setSpeakerFor(String voiceId, int sid) {
    if (sid == _store.speakerFor(voiceId)) return;
    _store.setSpeakerFor(voiceId, sid);
    notifyListeners();
  }

  void setVoiceId(String? id) {
    if (id == _voiceId) return;
    _voiceId = id;
    if (id != null) _store.setVoiceId(id);
    notifyListeners();
  }
}
