import 'package:app/features/live/data/datasources/gemini_live_datasource.dart';
import 'package:app/features/live/data/datasources/live_token_datasource.dart';
import 'package:app/features/live/data/repositories/live_session_repository_impl.dart';
import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cliente que no abre sockets: la prueba decide si abre, se cierra o falla.
class _FakeClient extends GeminiLiveClient {
  _FakeClient(super.opts);
  bool connectCalled = false;
  bool disconnected = false;

  @override
  void connect() => connectCalled = true;

  @override
  void disconnect() => disconnected = true;

  void open() => receivedAny = true;
}

const _granted = LiveTokenGranted(
  token: 'auth_tokens/abc',
  url: 'wss://gemini.test/Constrained',
  model: 'models/m',
  sessionId: 7,
);

void main() {
  late List<_FakeClient> clients;
  late List<Map<String, Object?>> requests;
  late List<(int, int?)> ends;
  late List<LiveCloseCause> closes;
  late LiveTokenResult? answer;
  late DateTime now;

  LiveSessionRepositoryImpl repo() => LiveSessionRepositoryImpl(
    requestToken: (start, token) async {
      requests.add(start);
      return answer;
    },
    reportEnd: (id, code, token) async => ends.add((id, code)),
    clientFactory: (o) {
      final c = _FakeClient(o);
      clients.add(c);
      return c;
    },
    clock: () => now,
  );

  Future<void> connect(LiveSessionRepositoryImpl r) async {
    r.connect(
      language: 'es',
      assistantName: 'Aria',
      deviceToken: 'tok',
      onResponse: (_) {},
      onClose: closes.add,
      onError: (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    clients = [];
    requests = [];
    ends = [];
    closes = [];
    answer = null;
    now = DateTime(2026, 10, 30, 9);
  });

  test('con token conecta directo con Gemini y sin la API key', () async {
    answer = _granted;
    final r = repo();
    await connect(r);
    final c = clients.single;
    expect(
      c.options.url,
      'wss://gemini.test/Constrained?access_token=auth_tokens%2Fabc',
    );
    expect(c.options.directModel, 'models/m');
    expect(c.connectCalled, isTrue);
    expect(requests.single['assistantName'], 'Aria');
  });

  test('sin conexión directa en el backend usa el proxy y no vuelve a '
      'preguntar en un rato', () async {
    final r = repo();
    await connect(r);
    expect(clients.single.options.directModel, isNull);
    expect(clients.single.options.url, endsWith('/ws/live'));
    r.disconnect();
    await connect(r);
    expect(requests, hasLength(1));
    now = now.add(directRetryAfter + const Duration(seconds: 1));
    r.disconnect();
    await connect(r);
    expect(requests, hasLength(2));
  });

  test(
    'un rechazo del backend cierra con la misma causa que el proxy',
    () async {
      answer = const LiveTokenRefused(4009);
      await connect(repo());
      expect(clients, isEmpty);
      expect(closes, [LiveCloseCause.dailyLimit]);
    },
  );

  test(
    'si la directa falla antes de abrir, cae al proxy sin avisar el corte',
    () async {
      answer = _granted;
      final r = repo();
      await connect(r);
      clients.first.options.onError?.call(Exception('sin red'));
      expect(clients, hasLength(2));
      expect(clients.last.options.directModel, isNull);
      expect(clients.last.connectCalled, isTrue);
      expect(closes, isEmpty);
      expect(ends, [(7, 4002)]);
    },
  );

  test(
    'una sesión directa que abrió y se cierra informa su fin una vez',
    () async {
      answer = _granted;
      final r = repo();
      await connect(r);
      clients.single.open();
      clients.single.options.onClose?.call(4001);
      expect(closes, [LiveCloseCause.upstreamEnded]);
      expect(ends, [(7, 4001)]);
      r.disconnect();
      expect(ends, hasLength(1));
    },
  );

  test('Detener mientras llega el token no abre ninguna sesión', () async {
    answer = _granted;
    final r = repo();
    r.connect(
      language: 'es',
      onResponse: (_) {},
      onClose: closes.add,
      onError: (_) {},
    );
    r.disconnect();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(clients, isEmpty);
  });

  test('cierres de Gemini en la sesión directa', () {
    expect(
      directCloseCode(1011, 'Your prepayment credits are depleted.'),
      4005,
    );
    expect(directCloseCode(1011, 'Quota exceeded for this model.'), 4003);
    expect(directCloseCode(1000, ''), 4001);
    expect(directCloseCode(1011, 'Token has been used too many times'), 4002);
    expect(directCloseCode(null, null), 4002);
  });
}
