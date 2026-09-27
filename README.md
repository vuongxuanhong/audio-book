# audio_book

Ứng dụng Flutter đọc truyện tiếng Việt: đọc bằng mắt hoặc nghe bằng giọng
tổng hợp **offline** (sherpa-onnx / VITS), có highlight câu đang đọc, lưu và
khôi phục vị trí, chỉnh tốc độ.

## Trạng thái MVP

| Chức năng | Trạng thái |
| --- | --- |
| Nhập truyện `.txt`, tự tách chương | ✅ |
| Đọc chữ (cỡ chữ / giãn dòng tuỳ chỉnh) | ✅ |
| Nghe audio offline, không cần mạng sau khi tải giọng | ✅ |
| Highlight câu đang đọc + tự cuộn theo | ✅ |
| Chạm vào câu bất kỳ để nhảy tới đó | ✅ |
| Lưu vị trí, mở lại đọc tiếp | ✅ |
| Tăng/giảm tốc độ 0.5×–2.0× (đổi tức thì) | ✅ |
| Chỉnh nhịp nghỉ: sau câu, giữa đoạn, trong câu | ✅ |
| Quản lý gói giọng đọc (tải / xoá / chọn) | ✅ |
| Đổi tên / xoá truyện, đọc lại từ đầu | ✅ |

## Chạy thử

```bash
flutter pub get
flutter run          # iOS / Android
```

Lần đầu mở app: bấm **Dùng truyện mẫu** để có nội dung ngay, rồi vào biểu
tượng loa ở góc trên bên phải để tải một gói giọng (khuyên dùng
*VAIS 1000 medium int8*, ~21 MB).

Nhập truyện của bạn: **Thêm truyện** → chọn tệp `.txt` (UTF-8). Nhấn giữ một
truyện trong tủ sách để đổi tên, đọc lại từ đầu hoặc xoá.

Kiểm tra trước một tệp mà không cần mở app:

```bash
dart run tool/parse_check.dart Chuong1-5.txt   # in ra tên chương, số câu
```

## Kiến trúc

```
lib/
  models/      Book, ChapterRef, Paragraph/Sentence, ReadingProgress, Voice
  services/
    text_parser.dart       tách chương + tách câu (giữ offset ký tự)
    library_repository.dart lưu truyện ra file trong Documents
    settings_store.dart     SharedPreferences: vị trí đọc, tốc độ, cỡ chữ…
    voice_repository.dart   tải .tar.bz2 từ release sherpa-onnx, giải nén
    tts_engine.dart         isolate chạy sherpa-onnx, trả về file WAV
  state/       AppSettings, LibraryController, ReaderController (ChangeNotifier)
  ui/          LibraryScreen, ReaderScreen, VoiceScreen + widgets
```

### Vì sao lại thiết kế như vậy

**Nhận dạng đầu chương.** `_headingOf` bóc dấu ngoặc trang trí (`【…】`, `「…」`,
`《…》`) và chấp nhận cả dấu hai chấm toàn rộng `：` trước khi so khớp — đây là
dạng phổ biến của truyện Trung dịch sang tiếng Việt (`【Chương 1：Tiêu đề】`).
Nếu tệp không có dòng nào giống đầu chương, cả tệp thành một chương duy nhất.

**Tách câu giữ offset.** `segment()` trả về các `Sentence` có `start`/`end` là
vị trí ký tự trong nguyên văn chương, và các span liền nhau phủ kín toàn bộ
văn bản (có unit test kiểm chứng). Nhờ vậy highlight chỉ là đổi `TextStyle`
của một `TextSpan` — chữ không bao giờ bị nhảy dòng khi câu đang đọc đổi.

**Mỗi câu là một clip.** Engine tổng hợp từng câu một rồi phát tuần tự. Đây
là cách rẻ nhất để biết chính xác câu nào đang phát mà không cần alignment
theo âm vị. Đổi lại phải giấu độ trễ tổng hợp: `ReaderController._prefetch`
dựng sẵn 2 câu kế tiếp trong lúc câu hiện tại đang phát.

**sherpa-onnx chạy trong isolate riêng.** Inference VITS là tác vụ CPU chặn
(~0.2× thời gian thực trên Mac, chậm hơn trên điện thoại). `TtsEngine` giữ
một `OfflineTts` sống suốt phiên trong isolate worker — nạp model tốn lâu hơn
nhiều so với tổng hợp một câu.

**Tốc độ đọc đổi ở player, không đổi ở model.** sherpa có tham số `speed`,
nhưng dùng nó thì mỗi lần kéo thanh tốc độ là phải tổng hợp lại. Thay vào đó
luôn render ở 1.0× và đổi `AudioPlayer.setSpeed` — đổi tức thì, và cache clip
vẫn dùng được.

**Chờ `ProcessingState.completed`, không chờ `play()`.** just_audio có
`if (playing) return;` ở đầu `play()`, và nó **không** đặt `playing = false`
khi một clip phát hết. Nên từ câu thứ hai trở đi `await player.play()` trả về
tức thì, vòng lặp tăng con trỏ và nạp clip kế tiếp — cắt ngang câu đang đọc.
`ReaderController._awaitClipEnd` lắng nghe `processingStateStream` để biết clip
thật sự kết thúc, kèm một timeout theo độ dài clip để một file hỏng không làm
treo vòng lặp. Đo lại trên máy thật: 6478 ms clip phát hết trong 4419 ms ở
1.5× (kỳ vọng 4319 ms).

**Con trỏ phát và highlight là một.** Việc theo dõi cuộn tay (`noteVisibleRange`)
từng ghi đè con trỏ phát mà không `notifyListeners()`, nên highlight đứng ở câu
người dùng chạm còn `play()` lại bắt đầu ở câu khác. Ba luật hiện tại:
cuộn do app tự chạy (`beginAutoScroll`/`endAutoScroll`) không được đọc ngược
thành người dùng đang lướt; câu đã chạm được giữ nguyên chừng nào đoạn của nó
còn trên màn hình (chạm câu thứ ba của một đoạn không bị kéo về câu đầu đoạn);
và mọi thay đổi con trỏ đều notify. Luật nằm trong hàm thuần
`resolveBrowseCursor` để test được — xem `test/browse_cursor_test.dart`.

**Nhịp nghỉ: ba mức, cùng một cơ chế.** Văn bản được cắt thành mệnh đề, mỗi
mệnh đề là một clip, và khoảng nghỉ là `Future.delayed` giữa hai clip:

| Nghỉ ở đâu | Mặc định | Đối chiếu tài liệu |
| --- | --- | --- |
| Dấu phẩy trong câu | 300 ms | VN 120–270 ms · EN ~600 ms |
| Hết câu | 700 ms | EN 600–1200 ms |
| Hết đoạn | 1100 ms | phải dài hơn hết câu |
| Ngắt cảnh (dòng `……`) | 2000 ms | audiobook 2000–2500 ms |

Cả bốn chia cho tốc độ phát nên nhịp giữ tỉ lệ khi nghe nhanh. Thứ tự ưu tiên
nằm trong hàm thuần `pauseMsFor` (`test/pause_tiers_test.dart`): câu đầu tiên
không nghỉ, rồi ngắt cảnh > đoạn > câu > phẩy.

Hai dòng `……` liền nhau vẫn chỉ thành **một** ngắt cảnh: dấu ngắt chỉ bật cờ
`_pendingBeat`, còn quãng nghỉ nằm ở trước câu kế tiếp.

Mặc định chọn theo tài liệu, có trừ phần model tự để lại (đo trên VAIS 1000:
**117 ms sau dấu phẩy**, chỉ **13–27 ms sau dấu chấm**, **1 ms sau dấu chấm
than** — nên delay phải gánh gần hết quãng nghỉ cuối câu):

- Tiếng Việt: [Data Processing for Optimizing Naturalness of Vietnamese TTS](https://arxiv.org/pdf/2004.09607)
  (VLSP 2019, 23 giờ một giọng) chia khoảng lặng **trong câu** thành bốn mức
  `[0.12–0.15]`, `(0.15–0.21]`, `(0.21–0.27]`, `>0.27` giây.
- Tiếng Anh: [Frontiers in Psychology 2022](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2022.778018/full)
  đo văn bản đọc thành tiếng — phẩy 0.47–0.78 s, chấm 0.98–1.43 s, tỉ lệ ~1:2;
  mức nghe tự nhiên nhất 0.6 s trong câu và 0.6 hoặc 1.2 s giữa hai câu.
- Ngắt cảnh: [Narrators Roadmap](https://www.narratorsroadmap.com/standards-for-silence-in-the-book/)
  đặt 2–3.5 s cho section break giữa chương.
- [Amazon Polly SSML](https://docs.aws.amazon.com/polly/latest/dg/break-tag.html)
  định nghĩa `medium`/`strong`/`x-strong` = nghỉ như dấu phẩy / hết câu / hết
  đoạn, nhưng không công bố số ms.

Dấu phẩy giữ ở 300 ms theo tai người dùng, cao hơn dải tiếng Việt một chút.

Bản trước làm quãng nghỉ ở dấu phẩy bằng cách **kéo dài khoảng lặng trong
audio** (`stretchPauses`, ngưỡng 60 ms). Cách đó sai về nguyên tắc và đã bị gỡ:
đo trên chính model, một câu 7.77 s có **hai** dấu phẩy nhưng bộ dò tìm thấy
**bốn** khoảng lặng 109–141 ms — hai khoảng không phải dấu phẩy dài đúng bằng
hai khoảng là dấu phẩy, nên không tiêu chí nào tách được chúng. Hậu quả nghe
thấy rõ ở câu ngắn: `Không khỏi tự lượng sức mình!` dài 1.28 s có một chỗ ngậm
hơi 74 ms ở giây 0.42, nhân 3× thành 222 ms — một khoảng câm chèn vào giữa câu.

**Dấu câu đứng một mình đọc thành im lặng.** Truyện Trung dịch dùng dòng `……`
làm dấu ngắt cảnh. Nếu đưa thẳng vào model, nó không im mà phát ra một tiếng
bụp 30 ms (đo được: `……` 0.03 s biên độ đỉnh 0.186; `…` 0.06 s / 0.217; `—`
0.06 s / 0.221). Vì vậy `Sentence.isSpeakable` đòi hỏi span phải có chữ hoặc
số; span chỉ có dấu câu (`isPauseMark`) không bao giờ tới engine, thay vào đó
trình đọc giữ im lặng đúng một nhịp đoạn. Dấu `…` gắn liền với chữ thì giữ
nguyên — `ba cây…` dài 1.53 s, `ba cây.` dài 1.52 s, model xử lý như nhau.

Cắt theo văn bản thì chính xác tuyệt đối vì ta biết dấu phẩy nằm ở đâu. Dấu
phẩy được **giữ lại trong mệnh đề** để model vẫn lên giọng như một câu chưa
kết thúc. Mệnh đề ngắn hơn 12 ký tự thì không tách (`Hắn nói:` phải đi liền).

Hai giá trị delay chia cho tốc độ phát nên nhịp giữ nguyên tỉ lệ khi nghe nhanh.

Thứ tự trong vòng phát rất quan trọng: **delay phải đặt trước `setFilePath`**.
just_audio để `playing` ở `true` sau khi một clip kết thúc, và khi nạp nguồn mới
lúc `playing` đang true nó gửi lệnh play ngay (`just_audio.dart`, nhánh
`if (playing) _sendPlayRequest(...)` trong `_setPlatformActive`). Đặt delay sau
`setFilePath` thì tiếng đã chạy rồi, quãng nghỉ bị nuốt sạch — đo được
`idleBefore=0ms` dù `want=1100ms`. Sau khi chuyển lên trước: `want=1100ms →
real=1103ms`. `setSpeed` cũng chuyển lên trước vì cùng lý do (nếu không, mấy
trăm mili giây đầu clip phát ở tốc độ cũ); tốc độ là thuộc tính của player nên
nó sống qua lần đổi nguồn.

`silenceScale` của sherpa-onnx **không** dùng được cho việc này, dù đúng là nó
sinh ra để làm việc đó. `ScaleSilence` chỉ đụng vào khoảng lặng dài hơn 200 ms,
mà giọng piper tiếng Việt chỉ để 60–150 ms ở dấu phẩy — đo thực tế trên truyện
này, kéo từ 0.2 lên 2.0 chỉ làm một câu 7.57 s dài thêm 0.17 s. Vì vậy nó được
ghim ở 1.0 (để sherpa đừng bóp ngắn) và `stretchPauses` làm phần còn lại với
ngưỡng 60 ms. Đo lại trên cùng một đoạn audio: câu nhiều dấu phẩy 8.12 s → 8.93 s
ở 2.0×, câu ngắn 2.73 s → 2.86 s (câu ngắn vốn không có gì để giãn — đó là lý do
phải có thêm hai nút delay ở trên).

Đo trên truyện thật (sau câu 200 ms, giữa đoạn 1200 ms, tốc độ 1.0):

```
para=224 prev=222 kind=paragraph want=1200ms  →  realSilence=1204ms
para=226 prev=224 kind=paragraph want=1200ms  →  realSilence=1203ms
para=226 prev=226 kind=SENTENCE  want= 200ms  →  realSilence= 205ms
para=228 prev=226 kind=paragraph want=1200ms  →  realSilence=1204ms
```

Đoạn 226 là dòng `“Ta tên Hoàng Chinh, … Long Bối Lĩnh. Thi thể con trai bà, ta
có thể vác về.”` — đúng một dòng hai câu, nên nó là chỗ duy nhất trong khúc đó
dùng "nghỉ sau câu".

Tỉ lệ sử dụng trên cả 5 chương (`dart run tool/parse_check.dart`): **21%** giao
điểm là nghỉ sau câu, **79%** là nghỉ giữa đoạn — vì truyện xuống dòng gần như
sau mỗi câu. Nghĩa là kéo thanh "nghỉ giữa đoạn" sẽ thấy khác biệt rõ hơn hẳn.

**Cache clip theo hash nội dung.** `<tmp>/tts_clips/<voiceId>_<hash>.wav`.
Đọc lại một chương đã nghe thì gần như không tốn CPU.

### Một cái bẫy đáng nhớ: độ dài đường dẫn espeak-ng

espeak-ng giữ thư mục dữ liệu trong một buffer cố định 230 byte. Nếu đường dẫn
dài hơn, nó **âm thầm** quay về `/usr/share/espeak-ng-data`, không tìm thấy
`phontab`, và gọi `exit()` — ứng dụng biến mất không một dòng stack trace Dart.

Trên iOS Simulator riêng phần tiền tố container đã ~170 ký tự, nên gói giọng
được giải nén phẳng vào `<Library>/v/<slot>/` (slot là một ký tự) thay vì
`<Application Support>/voices/<id>/<id>/`. Kết quả: 194 ký tự thay vì 293.
`VoiceRepository` cũng chủ động ném `VoicePathTooLong` nếu vượt 210 ký tự, để
lỗi hiện ra trên màn hình thay vì làm chết tiến trình.

## Giọng đọc

Lấy từ [release `tts-models` của sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models),
tải một lần rồi giải nén. Danh mục ở `lib/models/voice.dart`.

| Gói | Người đọc | Tải | Ghi chú |
| --- | --- | --- | --- |
| VAIS 1000 (medium, int8) | 1 nữ | 21 MB | Mặc định. Nhẹ nhất, nhưng chậm — xem dưới |
| VAIS 1000 (medium, đầy đủ) | 1 nữ | 64 MB | Cùng giọng, nhanh gấp 3, dải cao tốt hơn |

sherpa-onnx còn phát hành hai giọng tiếng Việt nữa nhưng không đưa vào vì
giấy phép dữ liệu: **VIVOS** (65 người đọc, gói duy nhất có giọng nam) dùng
CC BY-NC-SA 4.0 — cấm thương mại; **25 Hours Single** có giấy phép dataset
"Unknown" theo model card. Không có MMS hay Kokoro tiếng Việt. Các bản `fp16`
chỉ là mức lượng tử hoá khác của cùng giọng piper nên cũng không đưa vào.
Bản VAIS 1000 chạy engine mimic3 cũng bỏ, vì trùng giọng với hai bản piper.

### int8 và bản đầy đủ khác nhau ra sao

Đo trên MacBook Pro (Apple Silicon), cùng 6 câu đầu chương 1, tắt nhiễu VITS
(`noiseScale = noiseScaleW = 0`) để hai bộ trọng số so được với nhau:

| | int8 | đầy đủ |
| --- | --- | --- |
| Tệp `.onnx` | 17.7 MB | 60.2 MB (3.4×) |
| Tổng hợp 23.4 s tiếng | 4474 ms | **1303 ms** |
| RTF | 0.19 | **0.06** |
| Phổ dưới 5 kHz | lệch 0.8–1.7 dB | mốc so sánh |
| Phổ trên 5 kHz | **lệch 13.9 dB** | mốc so sánh |

Hai điều trái với trực giác thông thường:

**int8 chậm hơn, không nhanh hơn.** Lượng tử hoá giảm kích thước tệp, không
đảm bảo giảm thời gian chạy: onnxruntime phải chèn thêm bước quantize/dequantize
quanh mỗi toán tử, trong khi fp32 trên chip Apple vốn đã rất nhanh. Kết quả lặp
lại y hệt khi đảo thứ tự chạy (1539 ms so với 4728 ms), nên không phải do
làm nóng cache. Trên một số chip Android thì int8 có thể thắng — chưa đo.

**Sai khác dồn hết vào dải cao.** Dưới 5 kHz — nơi chứa nội dung lời nói và
chất giọng — hai bản gần như trùng nhau (~1 dB). Trên 5 kHz lệch tới 13.9 dB:
đó là tiếng xát (s, x, ch) và phần "thoáng" của giọng. Nói cách khác int8 giữ
nguyên người đọc, chỉ làm mờ phần cao.

Vì vậy bản đầy đủ **vừa nhanh hơn vừa sạch hơn**; cái giá duy nhất là 64 MB
thay vì 21 MB. Mặc định vẫn để int8 cho lần tải đầu nhẹ.

### Gói nhiều người đọc

Danh mục hiện không có gói nhiều speaker, nhưng code vẫn hỗ trợ:
`num_speakers` đọc từ `<model>.onnx.json`, speaker id lưu theo khoá
`tts.speaker.<voiceId>`, và bộ chọn giọng hiện ra khi gói có hơn một người đọc.

`tool/speaker_scan.dart` sinh thử một câu cho từng speaker rồi đo F0 trung vị
bằng autocorrelation; ghi kết quả vào `kSpeakerPitchHz` trong
`lib/models/voice_speakers.dart` thì bộ chọn hiển thị "Giọng 30 · nam · 120 Hz"
và tách hai nhóm nam/nữ. Con số Hz chỉ đáng tin ở ranh giới nam/nữ và thứ tự
cao thấp, không phải giá trị tuyệt đối.

```bash
dart run tool/speaker_scan.dart <thư-mục-gói-đã-giải-nén>
```

## Kiểm thử

```bash
flutter test                                   # unit test cho parser
dart run tool/tts_smoke.dart /tmp/tts_smoke    # kiểm tra tải + giải nén + tổng hợp thật
```

`tool/tts_smoke.dart` chạy headless: tải gói giọng, giải nén bằng `archive`,
rồi tổng hợp 3 câu tiếng Việt và in RTF. Trên MacBook Pro (Apple Silicon),
VAIS 1000 int8 cho RTF ≈ 0.20 — tức khoảng 0.5 giây để dựng 2.8 giây tiếng nói,
nên prefetch 2 câu là đủ để nghe liền mạch.

Đã chạy thử tay trên iPhone 17 Pro Simulator (iOS 26.2) với truyện thật
(`Chuong1-5.txt`, 5 chương, 48.6k chữ): nhập truyện, tải giọng, phát audio,
highlight chạy theo câu, tự cuộn, mục lục đủ 5 chương, chạm câu để nhảy tới,
tự sang chương, đổi tốc độ 1.0×→1.5×, và vị trí đọc được khôi phục đúng chương.

Ghi chú hiệu năng: `_maxSentenceChars = 220` trong `text_parser.dart` là mức
đánh đổi giữa ngữ điệu tự nhiên và độ trễ câu đầu tiên. Câu dài nhất trong
chương 1 của truyện thật là 151 ký tự — 1.6 giây để dựng trên Mac, sẽ lâu hơn
trên điện thoại. Hạ hằng số này xuống ~150 sẽ bấm play nghe nhanh hơn nhưng câu
bị cắt ở dấu phẩy.

## Việc còn lại (ngoài phạm vi MVP)

- Điều khiển từ màn hình khoá / Control Center (`audio_service`).
- Phát tiếp khi tắt màn hình trên Android (foreground service).
- Nhập EPUB, và nhập từ URL.
- Từ điển phát âm riêng cho tên riêng Hán Việt.
