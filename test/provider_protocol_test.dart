import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/models.dart';

/// Keep the real service selection, request path and headers. Only the test
/// socket destination is replaced, so these tests cannot call a paid service.
class _LocalCapture extends ModelConfig {
  _LocalCapture(ModelConfig config, this.port)
    : super(
        baseUrl: config.baseUrl,
        model: config.model,
        apiKey: 'contract-fixture',
      );
  final int port;
  @override
  Uri get endpoint =>
      super.endpoint.replace(scheme: 'http', host: '127.0.0.1', port: port);
}

const messages = [
  {'role': 'system', 'content': 'Local note'},
  {'role': 'assistant', 'content': 'Hi'},
  {'role': 'user', 'content': 'Hello'},
];
const inlineImage = 'data:image/png;base64,iVBORw==';
const inlinePdf = 'data:application/pdf;base64,JVBERi0=';
const attachments = <String, dynamic>{
  'role': 'user',
  'content': [
    {'type': 'text', 'text': 'Describe these'},
    {
      'type': 'image_url',
      'image_url': {'url': inlineImage},
    },
    {
      'type': 'file',
      'file': {'filename': 'sample.pdf', 'file_data': inlinePdf},
    },
  ],
};
String _event(Map<String, dynamic> frame) =>
    'data: ${jsonEncode(frame)}\r\n\r\n';
String _chunk(
  Map<String, dynamic> delta, {
  String? finish,
  Map<String, dynamic>? event,
}) => _event({
  'choices': [
    {'delta': delta, 'finish_reason': finish, 'server_tool_event': ?event},
  ],
});

void main() {
  late HttpServer server;
  late StreamingChatProvider provider;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = StreamingChatProvider();
  });
  tearDown(() async {
    provider.stop();
    await server.close(force: true);
  });

  test('recognizes official hosts only and upgrades former Chat Completions settings', () {
    expect(ModelConfig.deepSeek.endpoint.path, '/v1/chat/completions');
    expect(ModelConfig.claude.label, 'Claude');
    expect(ModelConfig.claude.endpoint.path, '/v1/messages');
    expect(ModelConfig.openAI.label, 'OpenAI');
    expect(ModelConfig.openAI.endpoint.path, '/v1/responses');
    expect(
      const ModelConfig(baseUrl: 'https://api.openai.com/v1/chat/completions/')
          .endpoint
          .path,
      '/v1/responses',
    );
    expect(
      const ModelConfig(baseUrl: 'https://api.anthropic.com').endpoint.path,
      '/v1/messages',
    );
    expect(
      const ModelConfig(
        baseUrl: 'https://api.openai.com.test/v1',
        model: 'my server',
      ).label,
      'my server',
    );
    expect(ModelConfig.claude.validationError, contains('Claude'));
    expect(ModelConfig.openAI.validationError, contains('OpenAI'));
  });

  test(
    'OpenAI Responses receives only normalized input and emits streamed output',
    () async {
      server.listen((req) async {
        expect(req.method, 'POST');
        expect(req.uri.path, '/v1/responses');
        expect(req.headers.value('authorization'), 'Bearer contract-fixture');
        expect(req.headers.value('x-api-key'), isNull);
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(
          body.keys,
          unorderedEquals(['model', 'stream', 'store', 'input']),
        );
        expect(body['model'], ModelConfig.openAI.model);
        expect(body['stream'], isTrue);
        expect(body['store'], isFalse);
        expect(body['input'], [
          ...messages,
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'Describe these'},
              {'type': 'input_image', 'image_url': inlineImage},
              {
                'type': 'input_file',
                'file_data': inlinePdf,
                'filename': 'sample.pdf',
              },
            ],
          },
        ]);
        req.response.write(
          ': ping\r\n\r\nevent: response.output_text.delta\r\ndata: {"type":"response.output_text.delta",\r\ndata: "delta":"你好"}\r\n\r\n',
        );
        req.response.write(
          _event({
            'type': 'response.completed',
            'response': {'status': 'completed'},
          }),
        );
        await req.response.close();
      });
      final stream = provider.replyRich(
        _LocalCapture(ModelConfig.openAI, server.port),
        [...messages, attachments],
        const ChatOptions(search: true, thinking: true),
      );
      expect(await stream.map((d) => d.text).join(), '你好');
    },
  );

  test(
    'Claude Messages separates system context and owns auth and content blocks',
    () async {
      server.listen((req) async {
        expect(req.uri.path, '/v1/messages');
        expect(req.headers.value('x-api-key'), 'contract-fixture');
        expect(req.headers.value('anthropic-version'), '2023-06-01');
        expect(req.headers.value('authorization'), isNull);
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(body['model'], ModelConfig.claude.model);
        expect(body['system'], 'Local note');
        expect(body['max_tokens'], greaterThan(0));
        expect(body['messages'], [
          messages[1],
          messages[2],
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Describe these'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'iVBORw==',
                },
              },
              {
                'type': 'document',
                'source': {
                  'type': 'base64',
                  'media_type': 'application/pdf',
                  'data': 'JVBERi0=',
                },
              },
            ],
          },
        ]);
        req.response.write(_event({'type': 'ping'}));
        req.response.write(
          _event({
            'type': 'content_block_delta',
            'delta': {'type': 'thinking_delta', 'thinking': 'Thought'},
          }),
        );
        req.response.write(
          _event({
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': 'Hello'},
          }),
        );
        req.response.write(
          _event({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
          }),
        );
        req.response.write(_event({'type': 'message_stop'}));
        await req.response.close();
      });
      final stream = provider.replyRich(
        _LocalCapture(ModelConfig.claude, server.port),
        [...messages, attachments],
        const ChatOptions(),
      );
      final deltas = await stream.toList();
      expect(deltas.map((d) => d.text).join(), 'Hello');
      expect(deltas.map((d) => d.thinking).join(), 'Thought');
    },
  );

  test('DeepSeek web results retain signed tools for the next turn and expose safe links and native title', () async {
    const annotation = {
      'type': 'url_citation',
      'url_citation': {
        'url': 'https://example.org/news',
        'title': 'Source',
        'start_index': 0,
        'end_index': 2,
      },
    };
    const tools = [
      {
        'index': 0,
        'calls': [
          {
            'index': 0,
            'type': 'deepseek_read_url',
            'status': 'completed',
            'signature': 'opaque-value',
          },
        ],
      },
    ];
    final config = _LocalCapture(ModelConfig.deepSeek, server.port);
    var requests = 0;
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      expect(req.uri.path, '/v1/chat/completions');
      expect(req.headers.value('authorization'), 'Bearer contract-fixture');
      if (requests++ == 0) {
        expect(body['thinking'], {'type': 'enabled'});
        expect(body['tools'], [
          {'type': 'deepseek_web_search'},
          {'type': 'deepseek_read_url'},
        ]);
        expect(body['title'], {'enabled': true});
        expect(body['safety_check'], {'level': 'high'});
        final sent = body['messages'] as List;
        expect(sent[sent.length - 2]['role'], 'latest_reminder');
        expect(sent[sent.length - 2]['content'], endsWith(',上海,App,English'));
        expect(sent.last['content'][1], {
          'type': 'image_url',
          'image_url': {'url': inlineImage},
        });
        expect(sent.last['content'][2], {
          'type': 'file',
          'file_id': 'file-api-test',
        });
        req.response.write(_chunk({'reasoning_content': 'First search'}));
        req.response.write(
          _chunk({}, event: {'type': 'step_reasoning_done', 'step': 0}),
        );
        req.response.write(_chunk({'reasoning_content': 'Consider findings.'}));
        req.response.write(_chunk({'content': 'OK'}));
        req.response.write(
          _chunk({
            'annotations': [annotation],
            'server_tool_calls': tools,
            'title': 'A source',
          }, finish: 'stop'),
        );
      } else {
        expect(body['tools'], isNull);
        expect(body['thinking'], {'type': 'disabled'});
        expect(body['title'], isNull);
        expect(body['messages'][0], {
          'role': 'assistant',
          'content': 'OK',
          'annotations': [annotation],
          'server_tool_calls': tools,
          'reasoning_content': 'Consider findings.',
        });
        req.response.write(_chunk({'content': 'Follow-up'}, finish: 'stop'));
      }
      await req.response.close();
    });
    final result = await provider.replyRich(
      config,
      [
        {
          'role': 'user',
          'content': [
            (attachments['content'] as List)[0],
            (attachments['content'] as List)[1],
            {
              'type': 'file',
              'file': {'file_id': 'file-api-test'},
            },
          ],
        },
      ],
      const ChatOptions(
        thinking: true,
        search: true,
        region: '上海',
        language: 'en-US',
        suggestTitle: true,
      ),
    ).toList();
    expect(result.map((v) => v.text).join(), 'OK');
    expect(
      result.map((v) => v.thinking).join(),
      'First searchConsider findings.',
    );
    final meta = result.last.metadata!;
    expect(meta['citations'], [
      {'url': 'https://example.org/news', 'title': 'Source'},
    ]);
    expect(meta['title'], 'A source');
    final second = await provider.replyRich(config, [
      {
        'role': 'assistant',
        'content': 'OK',
        ...meta['native'] as Map<String, dynamic>,
      },
      {'role': 'user', 'content': 'Continue'},
    ], const ChatOptions(readLinks: false)).toList();
    expect(second.first.text, 'Follow-up');
    expect(requests, 2);
  });

  test('OpenAI and Claude incomplete, failed and abruptly ended streams preserve partial text', () async {
    final cases = [
      (
        config: ModelConfig.openAI,
        first: {'type': 'response.output_text.delta', 'delta': 'part'},
        last: {
          'type': 'response.incomplete',
          'response': {
            'incomplete_details': {'reason': 'max_output_tokens'},
          },
        },
        reason: '长度',
      ),
      (
        config: ModelConfig.openAI,
        first: {'type': 'response.output_text.delta', 'delta': 'part'},
        last: {'type': 'response.failed'},
        reason: '异常',
      ),
      (
        config: ModelConfig.openAI,
        first: {'type': 'response.output_text.delta', 'delta': 'part'},
        last: null,
        reason: '中断',
      ),
      (
        config: ModelConfig.claude,
        first: {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'part'},
        },
        last: {
          'type': 'error',
          'error': {'type': 'overloaded_error'},
        },
        reason: '异常',
      ),
      (
        config: ModelConfig.claude,
        first: {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'part'},
        },
        last: null,
        reason: '中断',
      ),
    ];
    var current = 0;
    server.listen((req) async {
      await req.drain<void>();
      final item = cases[current++];
      req.response.write(_event(item.first));
      if (item.last != null) req.response.write(_event(item.last!));
      await req.response.close();
    });
    for (final c in cases) {
      await expectLater(
        provider.reply(_LocalCapture(c.config, server.port), messages),
        emitsInOrder([
          'part',
          emitsError(
            isA<OrbException>().having(
              (e) => e.message,
              'error',
              contains(c.reason),
            ),
          ),
        ]),
      );
    }
  });
}
