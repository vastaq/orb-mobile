import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/orb_store.dart';

void main() {
  test('requires HTTPS for keys and accepts a keyless LAN endpoint', () {
    expect(const ModelConfig().usable, isFalse);
    expect(const ModelConfig().settingsError, isNull);
    expect(ModelConfig.openAI.validationError, contains('API Key'));
    expect(const ModelConfig(apiKey: 'example').usable, isTrue);
    expect(const ModelConfig(baseUrl: 'http://192.168.1.20/v1').usable, isTrue);
    expect(
      const ModelConfig(
        baseUrl: 'http://192.168.1.20/v1',
        apiKey: 'example',
      ).usable,
      isFalse,
    );
    expect(
      const ModelConfig(baseUrl: 'http://api.example.test/v1').usable,
      isFalse,
    );
    expect(
      const ModelConfig(baseUrl: 'http://192.168.1.20.attacker.test/v1').usable,
      isFalse,
    );
    expect(
      const ModelConfig(baseUrl: 'https://name:pass@api.example.test/v1')
          .usable,
      isFalse,
    );
  });

  test(
    'context preserves newest complete pairs and includes explicit notes',
    () {
      final history = [
        const OrbMessage('user', 'orphan'),
        for (var i = 1; i <= 15; i++) ...[
          OrbMessage('user', 'q$i'),
          OrbMessage('assistant', 'a$i'),
        ],
        const OrbMessage('user', 'failed'),
      ];
      final context = buildContext(history, [
        const OrbMemory('1', '昵称是雾行者'),
      ], 'new');
      expect(context.first['role'], 'system');
      expect(context.first['content'], contains('雾行者'));
      expect(context[1]['content'], 'q4');
      expect(context.last['content'], 'new');
      expect(context.map((m) => m['content']), isNot(contains('failed')));
      expect(context.length, 26);
    },
  );

  test(
    'retry keeps the previous partial until replacement text arrives',
    () async {
      final storage = _RetryStore();
      final provider = _InterruptedProvider();
      final orb = OrbController(store: storage, provider: provider);
      await orb.initialize();
      await orb.send('问题');
      expect(orb.canRetry, isTrue);
      expect(orb.messages.last.text, '已经显示的内容');
      await orb.retry();
      expect(orb.messages.map((m) => m.text), ['问题', '已经显示的内容']);
      expect(storage.saved.single, '已经显示的内容');
      await orb.retry();
      expect(orb.messages.map((m) => m.text), ['问题', '完整回复']);
      expect(orb.canRetry, isFalse);
      expect(storage.retryFlags, [false, true, true]);
      expect(provider.requests.every((context) => context.length == 1), isTrue);
      orb.dispose();
    },
  );

  test(
    'web tools default on and remember independent opt-outs after reopening',
    () async {
      final storage = _RetryStore();
      final orb = OrbController(store: storage);
      addTearDown(orb.dispose);
      await orb.initialize();
      expect(orb.search, isTrue);
      expect(orb.readLinks, isTrue);
      expect(orb.thinking, isFalse);

      await orb.setChatOptions(web: false);
      await orb.initialize();
      expect(orb.search, isFalse);
      expect(orb.readLinks, isTrue);
      await orb.setChatOptions(web: true, links: false);
      await orb.initialize();
      expect(orb.search, isTrue);
      expect(orb.readLinks, isFalse);
    },
  );

  group('streaming completions', () {
    late HttpServer server;
    late ModelConfig config;
    late StreamingChatProvider provider;
    const messages = [
      {'role': 'user', 'content': '在吗'},
    ];
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      config = ModelConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'orb-local',
      );
      provider = StreamingChatProvider();
    });
    tearDown(() async {
      provider.stop();
      await server.close(force: true);
    });

    test('sends ordinary model payload, reads split UTF-8, and ignores thought deltas', () async {
      server.listen((req) async {
        expect(req.uri.path, '/v1/chat/completions');
        expect(req.headers.value('authorization'), isNull);
        expect(jsonDecode(await utf8.decoder.bind(req).join()), {
          'model': 'orb-local',
          'messages': messages,
          'stream': true,
        });
        final raw = utf8.encode(
          'data: {"choices":[{"delta":{"reasoning_content":"thought"}}]}\n\ndata: {"choices":[{"delta":{"content":"你好"}}]}\n\ndata: [DONE]\n\n',
        );
        final split = raw.indexOf(0xe4) + 1;
        req.response.add(raw.sublist(0, split));
        await req.response.flush();
        req.response.add(raw.sublist(split));
        await req.response.close();
      });
      expect(await provider.reply(config, messages).join(), '你好');
    });

    test(
      'reports a truncated stream after delivering its visible partial text',
      () async {
        server.listen((req) async {
          await req.drain<void>();
          req.response.write(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          );
          await req.response.close();
        });
        await expectLater(
          provider.reply(config, messages),
          emitsInOrder(['partial', emitsError(isA<OrbException>())]),
        );
      },
    );

    test(
      'treats empty successful HTTP responses and rate limits as failures',
      () async {
        var i = 0;
        server.listen((req) async {
          await req.drain<void>();
          if (i++ == 0) {
            req.response.write('data: [DONE]\n\n');
          } else {
            req.response.statusCode = 429;
          }
          await req.response.close();
        });
        await expectLater(
          provider.reply(config, messages).drain<void>(),
          throwsA(
            isA<OrbException>().having(
              (e) => e.message,
              'notice',
              contains('没有返回文字'),
            ),
          ),
        );
        await expectLater(
          provider.reply(config, messages).drain<void>(),
          throwsA(
            isA<OrbException>().having(
              (e) => e.message,
              'notice',
              contains('额度'),
            ),
          ),
        );
      },
    );

    test(
      'stop interrupts a connection that is waiting for more output',
      () async {
        final started = Completer<void>();
        server.listen((req) async {
          await req.drain<void>();
          req.response.bufferOutput = false;
          req.response.write(
            'data: {"choices":[{"delta":{"content":"first"}}]}\n\n',
          );
          await req.response.flush();
        });
        final stream = provider.reply(config, messages);
        final task = () async {
          try {
            await for (final text in stream) {
              expect(text, 'first');
              started.complete();
            }
          } on OrbException {
            // Cancellation closes the transport. The controller keeps partial text.
          }
        }();
        await started.future.timeout(const Duration(seconds: 5));
        provider.stop();
        await task.timeout(const Duration(seconds: 5));
      },
    );
  });
}

class _RetryStore extends Fake implements OrbStore {
  final saved = <String>[];
  final retryFlags = <bool>[];
  final preferences = {'auto_memory': '0'};
  @override
  Future<void> open() async {}
  @override
  Future<Map<String, ModelConfig>> loadProfiles() async => {};
  @override
  Future<String?> preference(String key) async => preferences[key];
  @override
  Future<void> setPreference(String name, String value) async {
    preferences[name] = value;
  }

  @override
  Future<void> saveMetadata(int id, Map<String, dynamic> data) async {}
  @override
  Future<List<OrbMemory>> memories() async => [];
  @override
  Future<List<OrbThread>> threads() async => [];
  @override
  Future<String?> selected() async => null;
  @override
  Future<ModelConfig> loadConfig() async =>
      const ModelConfig(apiKey: 'example');
  @override
  Future<({String thread, int answer})> beginTurn(
    String? current,
    String text,
    bool retry,
  ) async {
    retryFlags.add(retry);
    return (thread: '1', answer: 1);
  }

  @override
  Future<void> writeAnswer(int id, String text, String status) async {
    saved
      ..clear()
      ..add(text);
  }
}

class _InterruptedProvider implements ChatProvider {
  final requests = <List<Map<String, String>>>[];
  @override
  void stop() {}
  @override
  Stream<String> reply(
    ModelConfig config,
    List<Map<String, String>> messages,
  ) async* {
    requests.add(messages);
    if (requests.length == 1) yield '已经显示的内容';
    if (requests.length < 3) throw const OrbException('连接中断');
    yield '完整回复';
  }
}
