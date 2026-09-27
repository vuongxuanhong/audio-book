/// Per-speaker pitch for the multi-speaker voice packs.
///
/// Median F0 in Hz, indexed by speaker id, measured by generating one probe
/// sentence per speaker with `tool/speaker_scan.dart`. It is a cheap objective
/// stand-in for "what does this voice sound like" — below ~165 Hz reads as a
/// male voice, above it as female — and it lets the picker say something
/// truthful about 65 speakers without anyone having listened to all of them.
// No multi-speaker pack in the catalogue has been measured yet. VIVOS
// (65 speakers) was dropped for its non-commercial license.
const kSpeakerPitchHz = <String, List<int>>{};

/// Above this, a measured F0 reads as a female voice.
const kFemalePitchFloorHz = 165;

class SpeakerChoice {
  const SpeakerChoice({required this.id, required this.pitchHz});

  final int id;

  /// 0 when the pack has no measurements for this speaker.
  final int pitchHz;

  bool get isMale => pitchHz > 0 && pitchHz < kFemalePitchFloorHz;

  String get name => 'Giọng ${id + 1}';

  String get detail {
    if (pitchHz == 0) return '';
    return '${isMale ? 'nam' : 'nữ'} · $pitchHz Hz';
  }
}

/// The pickable speakers of [voiceId], newest measurements first for the packs
/// we have scanned and a plain numbered list for any we have not.
List<SpeakerChoice> speakerChoices(String voiceId, int numSpeakers) {
  final pitches = kSpeakerPitchHz[voiceId];
  return [
    for (var id = 0; id < numSpeakers; id++)
      SpeakerChoice(
        id: id,
        pitchHz: (pitches != null && id < pitches.length) ? pitches[id] : 0,
      ),
  ];
}
