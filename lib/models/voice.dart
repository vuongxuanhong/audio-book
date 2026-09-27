/// A downloadable sherpa-onnx VITS voice.
class VoiceCatalogEntry {
  const VoiceCatalogEntry({
    required this.id,
    required this.slot,
    required this.name,
    required this.description,
    required this.url,
    required this.downloadBytes,
    this.recommended = false,
  });

  final String id;

  /// Directory name used on disk. Deliberately one character: espeak-ng keeps
  /// its data path in a 230-byte buffer and silently falls back to
  /// `/usr/share/espeak-ng-data` when the path does not fit — which on iOS,
  /// where the container prefix alone is ~170 characters, is easy to hit.
  final String slot;

  final String name;
  final String description;
  final String url;
  final int downloadBytes;
  final bool recommended;

  String get sizeLabel =>
      '${(downloadBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

/// A voice that has been downloaded and unpacked on this device.
class InstalledVoice {
  const InstalledVoice({
    required this.id,
    required this.name,
    required this.modelPath,
    required this.tokensPath,
    required this.dataDir,
    this.numSpeakers = 1,
  });

  final String id;
  final String name;
  final String modelPath;
  final String tokensPath;
  final String dataDir;

  /// Read from the model's `.onnx.json`.
  final int numSpeakers;

  bool get isMultiSpeaker => numSpeakers > 1;
}

/// Catalogue of Vietnamese voices published by the sherpa-onnx project.
const kVoiceCatalog = <VoiceCatalogEntry>[
  VoiceCatalogEntry(
    id: 'vits-piper-vi_VN-vais1000-medium-int8',
    slot: '1',
    name: 'VAIS 1000 (medium, int8)',
    description: 'Một giọng nữ, 22 kHz. Bản lượng tử hoá: nhẹ hơn 3.4 lần '
        'nhưng tổng hợp CHẬM hơn ~3 lần bản đầy đủ trên chip Apple. '
        'Chọn khi cần tiết kiệm dung lượng máy.',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-vi_VN-vais1000-medium-int8.tar.bz2',
    downloadBytes: 21600000,
    recommended: true,
  ),
  VoiceCatalogEntry(
    id: 'vits-piper-vi_VN-vais1000-medium',
    slot: '2',
    name: 'VAIS 1000 (medium, bản đầy đủ)',
    description: 'Cùng giọng, không lượng tử hoá. Nặng gấp 3.4 lần nhưng tổng '
        'hợp nhanh gấp ~3 lần và giữ được dải cao (xem README). '
        'Đáng tải nếu máy còn chỗ.',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-vi_VN-vais1000-medium.tar.bz2',
    downloadBytes: 67100000,
  ),
];
