/// Per-speaker pitch for the multi-speaker voice packs.
///
/// Median F0 in Hz, indexed by speaker id, measured by generating one probe
/// sentence per speaker with `tool/speaker_scan.dart`. It is a cheap objective
/// stand-in for "what does this voice sound like" — below ~165 Hz reads as a
/// male voice, above it as female — and it lets the picker say something
/// truthful about 65 speakers without anyone having listened to all of them.
const kSpeakerPitchHz = <String, List<int>>{
  // VIVOS x-low: 65 speakers, 31 nam / 34 nữ, 105–314 Hz.
  'vits-piper-vi_VN-vivos-x_low-int8': [
    271, 271, 138, 258, 254, 158, 170, 157, 131, 154, //
    314, 250, 254, 246, 242, 254, 276, 225, 222, 296, //
    246, 258, 267, 242, 250, 140, 235, 239, 140, 120, //
    148, 232, 225, 134, 157, 180, 150, 163, 132, 145, //
    258, 134, 180, 133, 137, 124, 138, 138, 142, 138, //
    130, 131, 157, 152, 130, 125, 124, 105, 232, 211, //
    246, 242, 225, 242, 222, //
  ],
};

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
