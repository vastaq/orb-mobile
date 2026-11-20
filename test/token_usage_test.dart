import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/models.dart';

class _Loopback extends ModelConfig {
  _Loopback(ModelConfig base, this.port)
    : super(baseUrl: base.baseUrl, model: base.model, apiKey: 'local-fixture');
  final int port;
  @override
  Uri get endpoint =>
      super.endpoint.replace(scheme: 'http', host: '127.0.0.1', port: port);
}

const _q = [
  {'role': 'user', 'content': 'Hello'},
];
Map<String, dynamic> _chatChunk(String text, [String? stop]) => {
  'choices': [
    {
      'delta': {'content': text},
      'finish_reason': stop,
    },
  ],
};

void main() {
  late HttpServer server;
  late StreamingChatProvider provider;
  late List<Map<String, int>?> saved;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    saved = [];
    provider = StreamingChatProvider(
      usagePurpose: '对话',
      recordUsage: (_, _, v) async => saved.add(v),
    );
  });
  tearDown(() => server.close(force: true));
  Future<void> respond(HttpRequest req, List<Map> frames) async {
    for (final frame in frames) {
      req.response.write('data: ${jsonEncode(frame)}\n\n');
    }
    await req.response.close();
  }

  Future<List<ChatDelta>> complete(ModelConfig base, List<Map> frames) {
    server.listen((r) async {
      await r.drain<void>();
      await respond(r, frames);
    });
    return provider
        .replyRich(_Loopback(base, server.port), _q, const ChatOptions())
        .toList();
  }

  test('DeepSeek finish chunk includes hit tokens within input and reasoning within output', () async {
    final frames = await complete(ModelConfig.deepSeek, [
      _chatChunk('Hello'),
      {
        ..._chatChunk('', 'stop'),
        'usage': {
          'prompt_tokens': 112,
          'completion_tokens': 28,
          'total_tokens': 140,
          'prompt_cache_hit_tokens': 96,
          'prompt_cache_miss_tokens': 16,
          'prompt_tokens_details': {'cached_tokens': 96},
          'completion_tokens_details': {'reasoning_tokens': 18},
        },
      },
    ]);
    const expected = {
      'input': 112,
      'output': 28,
      'cached': 96,
      'reasoning': 18,
    };
    expect(frames.last.metadata?['usage'], expected);
    expect(saved, [expected]);
  });

  test(
    'Claude message_start and cumulative message_delta merge input only once',
    () async {
      final frames = await complete(ModelConfig.claude, [
        {
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 8,
              'cache_read_input_tokens': 64,
              'cache_creation_input_tokens': 16,
              'cache_creation': {
                'ephemeral_1h_input_tokens': 0,
                'ephemeral_5m_input_tokens': 16,
              },
              'output_tokens': 1,
            },
          },
        },
        {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Hello'},
        },
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 12},
        },
        {'type': 'message_stop'},
      ]);
      const expected = {
        'input': 88,
        'output': 12,
        'cached': 64,
        'reasoning': 0,
      };
      expect(frames.last.metadata?['usage'], expected);
      expect(saved, [expected]);
    },
  );

  test(
    'OpenAI completed response includes cached and reasoning as subsets',
    () async {
      final frames = await complete(ModelConfig.openAI, [
        {'type': 'response.output_text.delta', 'delta': 'Hello'},
        {
          'type': 'response.completed',
          'response': {
            'usage': {
              'input_tokens': 40,
              'input_tokens_details': {'cached_tokens': 32},
              'output_tokens': 17,
              'output_tokens_details': {'reasoning_tokens': 12},
              'total_tokens': 57,
            },
          },
        },
      ]);
      const expected = {
        'input': 40,
        'output': 17,
        'cached': 32,
        'reasoning': 12,
      };
      expect(frames.last.metadata?['usage'], expected);
      expect(saved, [expected]);
    },
  );

  test(
    'OpenAI incomplete terminal responses still report their actual usage',
    () async {
      final stream = complete(ModelConfig.openAI, [
        {'type': 'response.output_text.delta', 'delta': 'Part'},
        {
          'type': 'response.incomplete',
          'response': {
            'incomplete_details': {'reason': 'max_output_tokens'},
            'usage': {'input_tokens': 7, 'output_tokens': 6},
          },
        },
      ]);
      await expectLater(stream, throwsA(isA<OrbException>()));
      expect(saved, [
        {'input': 7, 'output': 6, 'cached': 0, 'reasoning': 0},
      ]);
    },
  );

  for (final rejectsOptions in [false, true]) {
    test(
      'llama.cpp usage-only final chunk, legacy server fallback=$rejectsOptions',
      () async {
        var calls = 0;
        server.listen((r) async {
          calls++;
          final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
          if (calls == 1) {
            expect(body['stream_options'], {'include_usage': true});
          }
          if (rejectsOptions && calls == 1) {
            r.response.statusCode = 422;
            r.response.write('{"detail":"unknown field stream_options"}');
            await r.response.close();
            return;
          }
          if (calls == 2) expect(body, isNot(contains('stream_options')));
          await respond(r, [
            _chatChunk('Hello'),
            _chatChunk('', 'stop'),
            if (!rejectsOptions)
              {
                'choices': [],
                'usage': {
                  'prompt_tokens': 21,
                  'completion_tokens': 5,
                  'total_tokens': 26,
                },
              },
          ]);
        });
        final config = ModelConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'mock',
        );
        final frames = await provider
            .replyRich(config, _q, const ChatOptions())
            .toList();
        expect(frames.first.text, 'Hello');
        expect(calls, rejectsOptions ? 2 : 1);
        expect(saved, [
          rejectsOptions
              ? null
              : {'input': 21, 'output': 5, 'cached': 0, 'reasoning': 0},
        ]);
      },
    );
  }
}
