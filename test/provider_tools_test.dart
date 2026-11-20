import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/chat_provider.dart';
import 'package:orb_mobile/core/models.dart';

class _Loopback extends ModelConfig {
  _Loopback(this.provider, this.port)
    : super(model: 'deepseek-flash', apiKey: 'test');
  final ModelService provider;
  final int port;
  @override
  ModelService get service => provider;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:$port/v1/test');
}

const tool = ChatTool(
  name: 'schedule_list',
  description: 'List tasks',
  parameters: {
    'type': 'object',
    'properties': {
      'limit': {'type': 'integer'},
    },
  },
);
const question = [
  {'role': 'user', 'content': '列出两项任务'},
];
typedef Json = Map<String, dynamic>;
Json chunk(Json delta, {String? stop, Json? usage}) => {
  'choices': [
    {'delta': delta, 'finish_reason': stop},
  ],
  'usage': ?usage,
};
const counts = {'prompt_tokens': 10, 'completion_tokens': 4};

Future<void> respond(HttpRequest req, List<Json> items) async {
  req.response.headers.contentType = ContentType(
    'text',
    'event-stream',
    charset: 'utf-8',
  );
  for (final item in items) {
    req.response.write('data: ${jsonEncode(item)}\n\n');
  }
  await req.response.close();
}

List<Json> completionsCall({String id = 'a', String name = 'schedule_list'}) =>
    [
      chunk({
        'tool_calls': [
          {
            'index': 0,
            'id': id,
            'function': {'name': name, 'arguments': '{"lim'},
          },
        ],
      }),
      chunk({
        'tool_calls': [
          {
            'index': 0,
            'function': {'arguments': 'it":2}'},
          },
        ],
      }),
      chunk({}, stop: 'tool_calls', usage: counts),
    ];

void main() {
  late HttpServer server;
  late StreamingChatProvider provider;
  late List<Map<String, int>?> usages;
  late List<Map> requests;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    usages = [];
    requests = [];
    provider = StreamingChatProvider(
      usagePurpose: '对话',
      recordUsage: (_, _, v) async {
        usages.add(v);
      },
    );
  });
  tearDown(() async {
    provider.stop();
    await server.close(force: true);
  });
  void serve(List<Json> Function(int round) payload) {
    server.listen((req) async {
      requests.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map);
      await respond(req, payload(requests.length));
    });
  }

  Stream<ChatDelta> run(ModelService service, RunChatTool invoke) =>
      provider.replyRich(
        _Loopback(service, server.port),
        question,
        ChatOptions(tools: [tool], onTool: invoke),
      );
  Future<Map<String, dynamic>> execute(ChatToolCall c) async {
    expect(c.id, 'a');
    expect(c.name, 'schedule_list');
    expect(c.arguments, {'limit': 2});
    return {
      'ids': ['31', '32'],
    };
  }

  const output = '{"ids":["31","32"]}';

  for (final service in [ModelService.deepSeek, ModelService.custom]) {
    test(
      '${service.name} streams calls and returns tool ids and outputs on the wire',
      () async {
        serve(
          (round) => round == 1
              ? [
                  if (service == ModelService.deepSeek)
                    chunk({'reasoning_content': 'Plan'}),
                  ...completionsCall(),
                ]
              : [
                  chunk({'content': '两项任务'}, stop: 'stop', usage: counts),
                ],
        );
        final deltas = await run(service, execute).toList();
        expect(requests, hasLength(2));
        final definitions = requests.first['tools'] as List;
        expect(definitions.first, {
          'type': 'function',
          'function': {
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.parameters,
          },
        });
        if (service == ModelService.deepSeek) {
          expect(definitions.last, {'type': 'deepseek_read_url'});
        }
        final messages = requests.last['messages'] as List;
        expect(messages[messages.length - 2]['tool_calls'], [
          {
            'id': 'a',
            'type': 'function',
            'function': {'name': 'schedule_list', 'arguments': '{"limit":2}'},
          },
        ]);
        if (service == ModelService.deepSeek) {
          expect(messages[messages.length - 2]['reasoning_content'], 'Plan');
        }
        expect(messages.last, {
          'role': 'tool',
          'tool_call_id': 'a',
          'content': output,
        });
        expect(deltas.map((d) => d.text).join(), '两项任务');
        expect(deltas.last.metadata?['usage'], {
          'input': 20,
          'output': 8,
          'cached': 0,
          'reasoning': 0,
        });
        expect(usages, hasLength(2));
      },
    );
  }

  test('Responses sends encrypted reasoning, tool identity and arguments back with store disabled', () async {
    const reasoning = {
      'type': 'reasoning',
      'id': 'rs_1',
      'summary': [],
      'encrypted_content': 'opaque',
    };
    const item = {
      'type': 'function_call',
      'id': 'fc_1',
      'call_id': 'a',
      'name': 'schedule_list',
      'arguments': '',
    };
    serve(
      (round) => round == 1
          ? [
              {
                'type': 'response.output_item.done',
                'output_index': 0,
                'item': reasoning,
              },
              {
                'type': 'response.output_item.added',
                'output_index': 1,
                'item': item,
              },
              {
                'type': 'response.function_call_arguments.delta',
                'output_index': 1,
                'delta': '{"limit":',
              },
              {
                'type': 'response.function_call_arguments.delta',
                'output_index': 1,
                'delta': '2}',
              },
              {
                'type': 'response.completed',
                'response': {
                  'usage': {'input_tokens': 2, 'output_tokens': 1},
                },
              },
            ]
          : [
              {'type': 'response.output_text.delta', 'delta': '两个'},
              {
                'type': 'response.completed',
                'response': {
                  'usage': {'input_tokens': 4, 'output_tokens': 3},
                },
              },
            ],
    );
    final deltas = await run(ModelService.openAI, execute).toList();
    expect(requests.first['store'], false);
    expect(requests.first['include'], contains('reasoning.encrypted_content'));
    expect(requests.first['tools'][0]['type'], 'function');
    expect(requests.last['input'], [
      ...question,
      reasoning,
      {...item, 'arguments': '{"limit":2}'},
      {'type': 'function_call_output', 'call_id': 'a', 'output': output},
    ]);
    expect(deltas.last.metadata?['usage']['input'], 6);
  });

  test('Claude preserves signed thinking and places tool_result before further assistant text', () async {
    serve(
      (round) => round == 1
          ? [
              {
                'type': 'content_block_start',
                'index': 0,
                'content_block': {
                  'type': 'thinking',
                  'thinking': '',
                  'signature': '',
                },
              },
              {
                'type': 'content_block_delta',
                'index': 0,
                'delta': {'type': 'thinking_delta', 'thinking': 'consider'},
              },
              {
                'type': 'content_block_delta',
                'index': 0,
                'delta': {'type': 'signature_delta', 'signature': 'signed'},
              },
              {
                'type': 'content_block_start',
                'index': 1,
                'content_block': {
                  'type': 'tool_use',
                  'id': 'a',
                  'name': 'schedule_list',
                  'input': {},
                },
              },
              {
                'type': 'content_block_delta',
                'index': 1,
                'delta': {'type': 'input_json_delta', 'partial_json': '{"lim'},
              },
              {
                'type': 'content_block_delta',
                'index': 1,
                'delta': {'type': 'input_json_delta', 'partial_json': 'it":2}'},
              },
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'tool_use'},
              },
              {'type': 'message_stop'},
            ]
          : [
              {
                'type': 'content_block_delta',
                'index': 0,
                'delta': {'type': 'text_delta', 'text': '完成'},
              },
              {'type': 'message_stop'},
            ],
    );
    final deltas = await run(ModelService.claude, execute).toList();
    expect(requests.first['tools'][0]['input_schema'], tool.parameters);
    expect(requests.last['messages'], [
      ...question,
      {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': 'consider', 'signature': 'signed'},
          {
            'type': 'tool_use',
            'id': 'a',
            'name': 'schedule_list',
            'input': {'limit': 2},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'a', 'content': output},
        ],
      },
    ]);
    expect(deltas.map((d) => d.text).join(), '完成');
  });

  test('unfinished tool requests, including truncated SSE, never run a local action', () async {
    serve(
      (_) => [
        chunk({
          'tool_calls': [
            {
              'index': 0,
              'id': 'a',
              'function': {'name': 'schedule_list', 'arguments': '{}'},
            },
          ],
        }),
      ],
    );
    var calls = 0;
    await expectLater(
      run(ModelService.custom, (c) async {
        calls++;
        return {};
      }).drain<void>(),
      throwsA(isA<OrbException>()),
    );
    expect(calls, 0);
  });

  test('stop during an executing callback prevents follow-on requests or batched actions', () async {
    serve(
      (_) => [
        chunk(
          {
            'tool_calls': [
              for (var i = 0; i < 2; i++)
                {
                  'index': i,
                  'id': 'call-$i',
                  'function': {'name': 'schedule_list', 'arguments': '{}'},
                },
            ],
          },
          stop: 'tool_calls',
          usage: counts,
        ),
      ],
    );
    final started = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final done = run(ModelService.custom, (c) async {
      calls++;
      started.complete();
      await release.future;
      return {};
    }).drain<void>();
    await started.future;
    provider.stop();
    release.complete();
    await done;
    expect(requests, hasLength(1));
    expect(calls, 1);
  });

  test('unregistered tools return an error and repeated call ids do not repeat local work', () async {
    serve(
      (round) => switch (round) {
        1 => completionsCall(id: 'unknown', name: 'not_registered'),
        2 || 3 => completionsCall(),
        _ => [
          chunk({'content': 'done'}, stop: 'stop', usage: counts),
        ],
      },
    );
    var actions = 0;
    final deltas = await run(ModelService.custom, (call) async {
      actions++;
      return execute(call);
    }).toList();
    expect(actions, 1);
    final first = requests[1]['messages'].last;
    expect(jsonDecode(first['content']), contains('error'));
    expect(
      requests[2]['messages'].last['content'],
      requests[3]['messages'].last['content'],
    );
    expect(deltas.last.metadata?['usage']['input'], 40);
  });

  test('a compatible server that explicitly rejects tools still supports ordinary chat', () async {
    server.listen((req) async {
      requests.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map);
      if (requests.length == 1) {
        req.response.statusCode = 400;
        req.response.write('this model does not support tools');
        await req.response.close();
      } else {
        await respond(req, [
          chunk({'content': '聊天正常'}, stop: 'stop', usage: counts),
        ]);
      }
    });
    final deltas = await run(ModelService.custom, execute).toList();
    expect(requests.last.containsKey('tools'), isFalse);
    expect(deltas.first.text, '聊天正常');
    expect(deltas.last.metadata?['toolsUnavailable'], true);
  });
}
