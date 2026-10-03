# audio_book

Ứng dụng Flutter đọc truyện tiếng Việt: đọc bằng mắt hoặc nghe bản đọc do
backend ([`audiobook-backend`](../../audiobook-backend)) tạo sẵn và **stream**
về, có highlight câu đang đọc, lưu và khôi phục vị trí, chỉnh tốc độ. App không
còn chạy model TTS trên máy.

## Trạng thái MVP

| Chức năng | Trạng thái |
| --- | --- |
| Tủ sách: Đọc tiếp · Truyện nổi bật · Truyện mới (từ backend) | ✅ |
| Đọc chữ (cỡ chữ / giãn dòng tuỳ chỉnh) | ✅ |
| Nghe audio stream từ backend, tự sang chương | ✅ |
| Highlight câu đang đọc + tự lật trang theo | ✅ |
| Chạm vào câu bất kỳ để nhảy tới đó | ✅ |
| Lưu vị trí, mở lại đọc tiếp (đồng bộ lên server khi đăng nhập) | ✅ |
| Tăng/giảm tốc độ 0.5×–2.0× (đổi tức thì) | ✅ |
| Nghe khi tắt màn hình / điều khiển từ màn hình khoá | ✅ |

## Chạy thử

Phiên bản Flutter được ghim trong `.fvmrc` (dùng [fvm](https://fvm.app)):

```bash
fvm install          # cài đúng bản trong .fvmrc
fvm flutter pub get
fvm flutter run      # iOS / Android
```

Mặc định app gọi backend trên Railway. Chạy với backend local
(`docker compose up` trong `audiobook-backend`):

```bash
fvm flutter run --dart-define=API_BASE_URL=http://localhost:8000
```

Audio được stream từ `AUDIO_BASE_URL` mà backend ký vào URL (mặc định
`http://localhost:8080`). Với HTTP thường, iOS cần cho phép mạng cục bộ (ATS)
và Android cần cho phép cleartext.

Truyện chỉ đến từ server, app không còn nhập tệp. **Tủ sách** có ba section,
section nào trống thì ẩn:

- **Đọc tiếp** — truyện đã mở trên máy này, đọc gần nhất lên đầu.
- **Truyện nổi bật** — `GET /v1/books?featured=true`, do admin chọn và xếp
  thứ tự (`python -m scripts.feature_book <book_id> <rank>` ở backend).
- **Truyện mới** — `GET /v1/books?sort=new`, mới thêm lên đầu, cuộn tới cuối
  thì tải trang tiếp.

Truyện nổi bật và Truyện mới hiển thị dạng lưới 2 cột kèm ảnh bìa
(`cover_url`, đặt bằng `python -m scripts.set_book_cover <book_id> anh.jpg` ở
backend). Truyện chưa có ảnh dùng bìa tạm: màu chọn theo tên truyện, in tên
truyện lên.

## Kiến trúc

```
lib/
  models/      Book, ChapterRef, Paragraph/Sentence, ReadingProgress,
               ChapterAudio/TimelineChunk
  services/
    api_client.dart          Dio + token thiết bị/người dùng
    remote_book_service.dart catalog, chi tiết truyện, nội dung + audio chương
    text_parser.dart         tách câu (giữ offset ký tự)
    library_repository.dart  lưu truyện ra file trong Documents (chương remote
                             được mã hoá AES-GCM)
    settings_store.dart      SharedPreferences: vị trí đọc, tốc độ, cỡ chữ…
  state/       AppSettings, LibraryController, ReaderController (ChangeNotifier)
  ui/          LibraryScreen (Tủ sách), ReaderScreen + widgets
```

### Vì sao lại thiết kế như vậy

**Tách câu giữ offset.** `segment()` trả về các `Sentence` có `start`/`end` là
vị trí ký tự trong nguyên văn chương, và các span liền nhau phủ kín toàn bộ
văn bản (có unit test kiểm chứng). Nhờ vậy highlight chỉ là đổi `TextStyle`
của một `TextSpan` — chữ không bao giờ bị nhảy dòng khi câu đang đọc đổi.

**Audio là của backend, app chỉ stream.** `GET /v1/books/{id}/chapters/{id}`
trả về `content` cùng `audio`: một URL ký sẵn, sống ngắn, trỏ tới audio server
(nginx, hỗ trợ HTTP Range để tua) và `timeline` — danh sách chunk
`{time_ms, start_offset, end_offset}` với offset UTF-16 trỏ vào đúng `content`
đó. Chuỗi Dart cũng đánh chỉ số theo UTF-16, nên offset dùng thẳng được.

**Timeline → câu đang đọc.** Mỗi chương là một file audio. `ReaderController`
nghe `positionStream` của player, tìm chunk đang phát (`chunkIndexAt`) rồi đổi
ra câu chứa đầu chunk (`chunkSentenceIndices`) để dời highlight. Chiều ngược
lại, chạm vào một câu thì tua tới chunk đầu tiên đọc câu đó
(`sentenceStartMs`). Câu chỉ có `……` không có chunk nào, nên tua tới chunk đọc
tiếp theo. Ba hàm này là hàm thuần, xem `test/timeline_mapping_test.dart`.
Vị trí đọc vẫn lưu theo chỉ số câu như trước, nên vị trí cũ và vị trí đồng bộ
từ server không phải đổi.

**Text và timeline luôn từ cùng một response.** Timeline chỉ khớp với đúng
văn bản nó được sinh ra. Khi bấm nghe, app gọi lại API chương (lấy URL mới),
ghi đè bản text đã cache, và nếu text trên server đã đổi thì hiển thị lại
chương theo text mới trước khi phát. Response được giữ trong bộ nhớ chừng nào
URL còn hạn hơn 5 phút, để tua / tạm dừng / phát tiếp không tốn thêm lượt gọi
API (endpoint này có rate limit).

**URL hết hạn.** URL ký có hạn (mặc định 6 giờ); quá hạn audio server trả 410.
Bấm phát tiếp sau khi URL đã gần hết hạn thì app dựng lại playlist với URL
mới. Nếu stream lỗi giữa chừng, app thử lại một lần với URL mới rồi mới báo
lỗi.

**Nghe khi tắt màn hình.** Playlist của player luôn giữ sẵn chương kế tiếp
phía sau chương đang phát (`_extendQueue`), nên nghe chạy liền qua ranh giới
chương mà player không bao giờ đứng yên — một player đứng yên lúc app ở nền là
iOS treo app. Gặp chương bị khoá hoặc chưa có bản đọc thì dừng ở cuối chương
trước, rồi mở chương đó để hiện lý do. `just_audio_background` lo phần điều
khiển trên màn hình khoá / thông báo và foreground service trên Android; chúng
chỉ tồn tại khi playlist có chương, nên chỉ đọc chữ thì không có gì chạy nền.
Rời màn hình đọc là dừng hẳn.

Ở nền không có frame nào được vẽ nên hiệu ứng lật trang không chạy; màn hình
đọc bỏ qua việc lật trang lúc đó và cắt thẳng tới trang đang đọc khi quay lại
(`didChangeAppLifecycleState`). Nếu để các lần lật trang dồn lại chạy muộn,
chúng bị hiểu nhầm là người dùng tự lướt trang và dừng phát.

**Đồng bộ vị trí đọc theo lô.** Vị trí luôn lưu ở máy trước (SettingsStore).
Khi đã đăng nhập, `ProgressSync` đưa vị trí mới nhất của mỗi truyện vào hàng
chờ (lưu trong SharedPreferences, nên app bị kill hay mất mạng cũng không
mất) và đẩy lên server: 5 phút một lần, ngay khi rời màn hình đọc, khi app
xuống nền, và lúc mở app nếu hàng chờ còn sót. Mỗi bản ghi kèm thời điểm đọc
thật (`updated_at`), nên server bỏ qua bản ghi đến muộn đã bị thiết bị khác
vượt qua. Chưa đăng nhập thì không gửi gì.

**Tốc độ đọc đổi ở player.** `AudioPlayer.setSpeed` — đổi tức thì, không
cần tải lại audio.

**Con trỏ phát và highlight là một.** Việc theo dõi cuộn tay (`noteVisibleRange`)
từng ghi đè con trỏ phát mà không `notifyListeners()`, nên highlight đứng ở câu
người dùng chạm còn `play()` lại bắt đầu ở câu khác. Ba luật hiện tại:
cuộn do app tự chạy (`beginAutoScroll`/`endAutoScroll`) không được đọc ngược
thành người dùng đang lướt; câu đã chạm được giữ nguyên chừng nào đoạn của nó
còn trên màn hình (chạm câu thứ ba của một đoạn không bị kéo về câu đầu đoạn);
và mọi thay đổi con trỏ đều notify. Luật nằm trong hàm thuần
`resolvePageBrowseCursor` để test được — xem `test/page_browse_cursor_test.dart`.

## Kiểm thử

```bash
flutter test
```

Unit test cho tách câu, phân trang, quy tắc con trỏ khi lướt trang, và ánh xạ
timeline ↔ câu.

## Việc còn lại (ngoài phạm vi MVP)

- Tải audio về để nghe offline (hiện chỉ stream).
- Mua / mở khoá truyện trong app (hiện admin cấp quyền bằng tay).
- Ảnh bìa truyện (hiện dùng ảnh bìa chung).
