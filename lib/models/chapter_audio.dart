/// One entry of the backend's highlight timeline: from [timeMs] in the
/// chapter's audio until the next chunk's [timeMs], the narrator is reading
/// `content[startOffset, endOffset)` — UTF-16 offsets, the same units as a
/// Dart [String] index.
class TimelineChunk {
  const TimelineChunk({
    required this.timeMs,
    required this.startOffset,
    required this.endOffset,
  });

  final int timeMs;
  final int startOffset;
  final int endOffset;

  factory TimelineChunk.fromJson(Map<String, dynamic> json) => TimelineChunk(
        timeMs: json['time_ms'] as int,
        startOffset: json['start_offset'] as int,
        endOffset: json['end_offset'] as int,
      );
}

/// A remote chapter's narration, streamed from the audio server.
///
/// [url] is signed and short-lived (see `app/core/audio.py` in the backend):
/// past [urlExpiresAt] the audio server answers 410, and the chapter has to
/// be fetched again for a fresh one. The [timeline] only matches the exact
/// chapter content it came with.
class ChapterAudio {
  const ChapterAudio({
    required this.url,
    required this.urlExpiresAt,
    required this.durationMs,
    required this.mimeType,
    required this.timeline,
    this.sizeBytes = 0,
  });

  final Uri url;
  final DateTime urlExpiresAt;
  final int durationMs;
  final String mimeType;

  /// Size of the audio file; 0 when the server didn't say.
  final int sizeBytes;

  /// Identifies the audio file itself, independent of the signature in
  /// [url]'s query, which changes every few minutes. The backend's keys are
  /// content-hashed, so regenerated audio gets a new one.
  String get cacheKey => url.path;

  /// Sorted by [TimelineChunk.timeMs], never empty.
  final List<TimelineChunk> timeline;

  /// Whether the URL is still good for at least [margin] — long enough to
  /// start playing and for the player's first few range requests.
  bool isFresh({Duration margin = const Duration(minutes: 5)}) =>
      DateTime.now().add(margin).isBefore(urlExpiresAt);

  /// Null when the chapter has no usable audio: none attached, or a locked
  /// chapter whose URL the server didn't sign.
  static ChapterAudio? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final url = json['url'] as String?;
    final expires = json['url_expires_at'] as String?;
    final timeline = json['timeline'] as Map<String, dynamic>?;
    if (url == null || expires == null || timeline == null) return null;
    final chunks = (timeline['chunks'] as List<dynamic>)
        .map((e) => TimelineChunk.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    if (chunks.isEmpty) return null;
    return ChapterAudio(
      url: Uri.parse(url),
      urlExpiresAt: DateTime.parse(expires),
      durationMs: json['duration_ms'] as int? ?? 0,
      mimeType: json['mime_type'] as String? ?? 'audio/mp4',
      timeline: chunks,
      sizeBytes: json['size_bytes'] as int? ?? 0,
    );
  }
}

/// What the chapter endpoint returns: the text and, when there is any, the
/// narration whose timeline indexes into exactly this text.
class RemoteChapterContent {
  const RemoteChapterContent({required this.content, this.audio});

  final String content;
  final ChapterAudio? audio;
}
