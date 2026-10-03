import 'package:audio_book/services/api_client.dart';
import 'package:audio_book/services/progress_sync.dart';
import 'package:audio_book/services/remote_book_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient implements ApiClient {
  bool loggedIn = true;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  Future<bool> checkLoggedIn() async => loggedIn;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRemote implements RemoteBookService {
  final sent = <(String, String, int, DateTime)>[];

  /// Status code to fail the next push with (null: no response at all, as
  /// when offline); unset to succeed.
  int? failWith;
  bool fail = false;

  /// Runs while a push is in flight.
  void Function()? during;

  @override
  Future<void> pushProgress(
    String bookId,
    String chapterId,
    int position, {
    required DateTime updatedAt,
  }) async {
    during?.call();
    if (fail) {
      final options = RequestOptions(path: '/v1/me/progress/$bookId');
      throw DioException(
        requestOptions: options,
        response: failWith == null
            ? null
            : Response(requestOptions: options, statusCode: failWith),
      );
    }
    sent.add((bookId, chapterId, position, updatedAt));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeClient client;
  late _FakeRemote remote;
  late SharedPreferences prefs;
  late ProgressSync sync;
  final t0 = DateTime.utc(2026, 10, 3, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    client = _FakeClient();
    remote = _FakeRemote();
    sync = ProgressSync(client, remote, prefs);
  });

  void record(String book, int position, DateTime at) => sync.record(
        remoteBookId: book,
        chapterId: 'ch-$book',
        position: position,
        updatedAt: at,
      );

  test('sends only the latest position per book, with its reading time', () async {
    record('a', 1, t0);
    record('a', 2, t0.add(const Duration(minutes: 1)));
    record('b', 7, t0);
    expect(remote.sent, isEmpty, reason: 'nothing goes out until a flush');

    await sync.flush();
    expect(remote.sent, unorderedEquals([
      ('a', 'ch-a', 2, t0.add(const Duration(minutes: 1))),
      ('b', 'ch-b', 7, t0),
    ]));

    remote.sent.clear();
    await sync.flush();
    expect(remote.sent, isEmpty, reason: 'the queue is empty once sent');
  });

  test('queues nothing while signed out', () async {
    client.loggedIn = false;
    record('a', 1, t0);
    client.loggedIn = true;
    await sync.flush();
    expect(remote.sent, isEmpty);
  });

  test('survives a restart: a new instance sends what was left', () async {
    record('a', 3, t0);
    final afterRestart = ProgressSync(client, remote, prefs);
    await afterRestart.flush();
    expect(remote.sent.single.$3, 3);
  });

  test('keeps the queue when offline and sends it later', () async {
    record('a', 3, t0);
    remote.fail = true; // no response: offline
    await sync.flush();
    expect(remote.sent, isEmpty);

    remote.fail = false;
    await sync.flush();
    expect(remote.sent.single.$3, 3);
  });

  test('drops an entry the server can never take', () async {
    record('a', 3, t0);
    remote
      ..fail = true
      ..failWith = 404;
    await sync.flush();

    remote.fail = false;
    await sync.flush();
    expect(remote.sent, isEmpty);
  });

  test('a position queued while sending is kept for the next flush', () async {
    record('a', 1, t0);
    remote.during = () {
      remote.during = null;
      record('a', 2, t0.add(const Duration(seconds: 30)));
    };
    await sync.flush();
    expect(remote.sent.map((s) => s.$3), [1]);

    await sync.flush();
    expect(remote.sent.map((s) => s.$3), [1, 2]);
  });
}
