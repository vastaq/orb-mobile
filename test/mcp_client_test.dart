import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/mcp_client.dart';
import 'package:orb_mobile/core/tool_types.dart';

class DocumentServer {
  DocumentServer(this.socket);
  final HttpServer socket;
  String get url => 'http://127.0.0.1:${socket.port}/mcp';
  int sessions = 0, calls = 0, deletes = 0;
  bool expired = false,
      change = false,
      fail = false,
      malformed = false,
      remoteError = false;
  final methods = <String>[],
      authorizations = <String?>[],
      versions = <String?>[],
      receivedSessions = <String?>[];
  void listen() => socket.listen((req) async {
    final resp = req.response;
    if (req.method == 'DELETE') {
      deletes++;
      resp.statusCode = 204;
      await resp.close();
      return;
    }
    final b = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
    final method = b['method'] as String;
    methods.add(method);
    authorizations.add(req.headers.value('authorization'));
    versions.add(req.headers.value('mcp-protocol-version'));
    receivedSessions.add(req.headers.value('mcp-session-id'));
    if (method == 'notifications/initialized') {
      resp.statusCode = 202;
      await resp.close();
      return;
    }
    if (fail) {
      resp.statusCode = 503;
      await resp.close();
      return;
    }
    if (expired && method == 'tools/list') {
      expired = false;
      resp.statusCode = 404;
      await resp.close();
      return;
    }
    final id = b['id'];
    Map<String, dynamic> result;
    switch (method) {
      case 'initialize':
        sessions++;
        resp.headers.set('mcp-session-id', 'test-$sessions');
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
        };
      case 'tools/list':
        if ((b['params'] as Map)['cursor'] == null) {
          result = {
            'nextCursor': 'two',
            'tools': [
              {
                'name': 'note.read',
                'description': change ? '不同的操作' : '读取测试页',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'title': {'type': 'string'},
                  },
                },
                'annotations': {'readOnlyHint': true},
              },
            ],
          };
        } else {
          result = {
            'tools': [
              {
                'name': 'note.write',
                'inputSchema': {'type': 'object'},
                'annotations': {'readOnlyHint': false},
              },
              {
                'name': 'unannotated',
                'inputSchema': {'type': 'object'},
              },
            ],
          };
        }
      case 'tools/call':
        calls++;
        result = {
          'content': [
            {'type': 'text', 'text': '七号松塔'},
          ],
          'structuredContent': {'count': 1},
          'isError': remoteError,
        };
      default:
        throw StateError(method);
    }
    final answer = jsonEncode({
      'jsonrpc': '2.0',
      'id': malformed ? 1000 : id,
      'result': result,
    });
    if (method == 'tools/list' || method == 'tools/call') {
      resp.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      resp.write(
        ': keepalive\n\nevent: message\ndata: {"jsonrpc":"2.0","method":"notifications/message","params":{}}\n\n',
      );
      resp.write('id: test\nevent: message\ndata: $answer\n\n');
    } else {
      resp.headers.contentType = ContentType.json;
      resp.write(answer);
    }
    await resp.close();
  });
}

void main() {
  late DocumentServer server;
  late Directory root;
  late McpConnections store;
  late Map<String, String> secrets;
  setUp(() async {
    server = DocumentServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    )..listen();
    root = Directory.systemTemp.createTempSync('orb-mcp-');
    secrets = {};
    store = McpConnections(root, (id) async => secrets[id], (id, s) async {
      if (s == null) {
        secrets.remove(id);
      } else {
        secrets[id] = s;
      }
    });
  });
  tearDown(() async {
    await server.socket.close(force: true);
    root.deleteSync(recursive: true);
  });
  test(
    'negotiates HTTPS policy, JSON, paginated SSE, session header and opt-in',
    () async {
      expect(
        () => mcpEndpoint('http://example.org/mcp'),
        throwsFormatException,
      );
      expect(
        () => mcpEndpoint('https://user:password@example.org/mcp'),
        throwsFormatException,
      );
      expect(store.tools, isEmpty);
      expect(server.methods, isEmpty);
      final c = await store.add(
        '测试文档',
        '${server.url}?private=sample',
        'test-only-bearer',
      );
      expect(server.methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/list',
      ]);
      expect(server.receivedSessions, [null, 'test-1', 'test-1', 'test-1']);
      expect(server.versions, [null, '2025-06-18', '2025-06-18', '2025-06-18']);
      expect(server.deletes, 1);
      expect(c.catalog.length, 3);
      expect(store.tools, isEmpty);
      expect(
        File('${root.path}/${c.id}.json').readAsStringSync(),
        allOf(
          isNot(contains('test-only-bearer')),
          isNot(contains('private=sample')),
        ),
      );
      expect(
        () => store.allow(c.id, 'note.write', true),
        throwsFormatException,
      );
      expect(
        () => store.allow(c.id, 'unannotated', true),
        throwsFormatException,
      );
      store.allow(c.id, 'note.read', true);
      final alias = store.tools.single.name;
      expect(alias, matches(RegExp(r'^[a-zA-Z0-9_-]{1,64}$')));
      final call = ChatToolCall(
        id: 'tool-1',
        name: alias,
        arguments: {'title': '测试页'},
      );
      server.expired = true;
      final result = await store.execute(call);
      expect(result['text'], '七号松塔');
      expect(result['structured'], {'count': 1});
      expect(server.sessions, 3);
      expect(server.calls, 1);
      expect(server.authorizations.toSet(), {'Bearer test-only-bearer'});
      await store.remove(c.id);
      expect(secrets, isEmpty);
      expect(store.tools, isEmpty);
      await expectLater(store.execute(call), throwsFormatException);
    },
  );
  test('changed remote declarations stay unavailable until refreshed and reapproved', () async {
    final c = await store.add('资料库', server.url, '');
    store.allow(c.id, 'note.read', true);
    final call = ChatToolCall(
      id: 'a',
      name: store.tools.single.name,
      arguments: {},
    );
    server.change = true;
    await expectLater(store.execute(call), throwsFormatException);
    expect(server.calls, 0);
    await store.refresh(c.id);
    expect(store.tools, isEmpty);
    store.allow(c.id, 'note.read', true);
    server.fail = true;
    await expectLater(store.execute(call), throwsFormatException);
    expect(store.get(c.id)!.allowed, contains('note.read'));
    server.fail = false;
    server.remoteError = true;
    await expectLater(store.execute(call), throwsFormatException);
    expect(server.calls, 1);
  });
  test(
    'unmatched JSON-RPC result cannot register a service or store secrets',
    () async {
      server.malformed = true;
      await expectLater(
        store.add('资料库', server.url, 'sensitive'),
        throwsFormatException,
      );
      expect(store.list(), isEmpty);
      expect(secrets, isEmpty);
    },
  );
}
