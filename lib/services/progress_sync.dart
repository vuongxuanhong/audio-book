import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'remote_book_service.dart';

/// Queues a signed-in reader's positions and pushes them to the server in
/// batches, instead of on every sentence.
///
/// Positions are always saved locally first (SettingsStore); this only
/// decides when the server hears about them. The queue keeps the latest
/// position per book and lives in SharedPreferences, so nothing is lost when
/// the app is killed or offline. It is sent:
/// - every [interval] while the app runs,
/// - right away when the reader closes a book ([flush]),
/// - when the app goes to the background,
/// - on the next launch, for whatever was still queued.
///
/// Each entry carries the time the reader was there, so the server can drop
/// a late entry that another device has since overtaken.
class ProgressSync {
  ProgressSync(this._client, this._remote, this._prefs);

  static const interval = Duration(minutes: 5);
  static const _kPending = 'sync.pendingProgress';

  final ApiClient _client;
  final RemoteBookService _remote;
  final SharedPreferences _prefs;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  Future<void>? _flushing;

  /// Starts the periodic and background-triggered pushes, and sends anything
  /// left over from the last run.
  void start() {
    _timer ??= Timer.periodic(interval, (_) => flush());
    _lifecycle ??= AppLifecycleListener(
      onPause: flush,
      onDetach: flush,
    );
    unawaited(flush());
  }

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
  }

  /// Queues [remoteBookId]'s position, replacing any queued one. Ignored
  /// unless someone is signed in: progress on the server is per user.
  void record({
    required String remoteBookId,
    required String chapterId,
    required int position,
    required DateTime updatedAt,
  }) {
    if (!_client.isLoggedIn) return;
    final pending = _load();
    pending[remoteBookId] = _Entry(chapterId, position, updatedAt);
    _save(pending);
  }

  /// Sends the queue now. Concurrent calls share one run.
  Future<void> flush() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    if (_load().isEmpty) return;
    try {
      // Refreshes the token first, which is also what tells whether the
      // device is still signed in after a cold start.
      if (!await _client.checkLoggedIn()) return;
    } on Object {
      return; // Offline: try again on the next trigger.
    }

    for (final MapEntry(key: bookId, value: entry) in _load().entries) {
      try {
        await _remote.pushProgress(
          bookId,
          entry.chapterId,
          entry.position,
          updatedAt: entry.updatedAt,
        );
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        // Gone (book or chapter deleted), or nobody signed in any more:
        // retrying can't help. Anything else — offline, a server error —
        // stops this run and keeps the queue for the next one.
        if (status != 404 && status != 401 && status != 422) return;
      }
      _remove(bookId, entry);
    }
  }

  /// Drops [bookId]'s entry, unless a newer position was queued while it
  /// was being sent.
  void _remove(String bookId, _Entry sent) {
    final pending = _load();
    if (pending[bookId]?.updatedAt == sent.updatedAt) {
      pending.remove(bookId);
      _save(pending);
    }
  }

  Map<String, _Entry> _load() {
    final raw = _prefs.getString(_kPending);
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in json.entries)
          key: _Entry.fromJson(value as Map<String, dynamic>),
      };
    } on Object {
      return {};
    }
  }

  void _save(Map<String, _Entry> pending) {
    unawaited(_prefs.setString(
      _kPending,
      jsonEncode({for (final e in pending.entries) e.key: e.value.toJson()}),
    ));
  }
}

class _Entry {
  const _Entry(this.chapterId, this.position, this.updatedAt);

  final String chapterId;
  final int position;
  final DateTime updatedAt;

  factory _Entry.fromJson(Map<String, dynamic> json) => _Entry(
        json['chapterId'] as String,
        json['position'] as int,
        DateTime.parse(json['updatedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'chapterId': chapterId,
        'position': position,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}
