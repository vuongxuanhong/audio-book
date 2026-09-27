import 'package:flutter/foundation.dart';

/// Attribution for a third-party asset the app downloads at runtime (voice
/// models), which the package-based license list can't see on its own.
class ThirdPartyNotice {
  const ThirdPartyNotice({
    required this.name,
    required this.usedFor,
    required this.license,
    required this.url,
  });

  final String name;
  final String usedFor;
  final String license;
  final String url;
}

/// Datasets and data files behind the voices in `kVoiceCatalog`, taken from
/// each voice's MODEL_CARD (rhasspy/piper-voices). Re-check these when adding
/// a voice.
const kThirdPartyNotices = <ThirdPartyNotice>[
  ThirdPartyNotice(
    name: 'VAIS-1000 Vietnamese Speech Synthesis Corpus',
    usedFor: 'Giọng VAIS 1000',
    license: 'CC BY 4.0',
    url:
        'https://ieee-dataport.org/documents/vais-1000-vietnamese-speech-synthesis-corpus',
  ),
  ThirdPartyNotice(
    name: 'Piper voices (rhasspy/piper-voices)',
    usedFor: 'Mô hình giọng piper',
    license: 'Theo giấy phép của từng bộ dữ liệu ở trên',
    url: 'https://huggingface.co/rhasspy/piper-voices',
  ),
  ThirdPartyNotice(
    name: 'eSpeak NG data',
    usedFor: 'Chuyển chữ thành âm vị, đi kèm các gói giọng',
    license: 'GPL-3.0',
    url: 'https://github.com/espeak-ng/espeak-ng',
  ),
];

/// Adds [kThirdPartyNotices] to Flutter's [LicenseRegistry] so they show up
/// in `showLicensePage` next to the pub packages.
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final n in kThirdPartyNotices) {
      yield LicenseEntryWithLineBreaks(
        [n.name],
        'Dùng cho: ${n.usedFor}\nGiấy phép: ${n.license}\n${n.url}',
      );
    }
  });
}
