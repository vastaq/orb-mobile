import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import 'tool_types.dart';

const _versions = ['2025-11-25', '2025-06-18', '2025-03-26'];
const _maxBody = 2 * 1024 * 1024;
String _hash(String s) => sha256.convert(utf8.encode(s)).toString();

Uri mcpEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('请输入完整的 MCP 地址，并在令牌栏填写凭据。');
  }
  if (uri.scheme != 'https' &&
      !(uri.scheme == 'http' &&
          (uri.host == 'localhost' ||
              (InternetAddress.tryParse(uri.host)?.isLoopback ?? false)))) {
    throw const FormatException('请使用 HTTPS 地址。本机回环地址也支持 HTTP。');
  }
  return uri;
}

dynamic _stable(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _stable(value[k])};
  }
  return value is List ? value.map(_stable).toList() : value;
}

String _shortText(String text, int length) =>
    String.fromCharCodes(text.runes.take(length));

class McpRemoteTool {
  const McpRemoteTool(
    this.name,
    this.description,
    this.schema,
    this.readOnly, [
    this.hints = const {},
  ]);
  final String name, description;
  final Map<String, dynamic> schema;
  final bool readOnly;
  final Map<String, bool> hints;
  String get signature => _hash(jsonEncode(_stable(toJson())));
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': schema,
    'annotations': {'readOnlyHint': readOnly, ...hints},
  };
  static McpRemoteTool parse(Map data) {
    final name = data['name'], schema = data['inputSchema'];
    if (name is! String ||
        name.isEmpty ||
        name.length > 128 ||
        schema is! Map ||
        schema['type'] != 'object' ||
        jsonEncode(schema).length > 32000) {
      throw const FormatException('MCP 工具名称或参数格式无效。');
    }
    final annotations = data['annotations'];
    final safe =
        annotations is Map &&
        annotations['readOnlyHint'] == true &&
        annotations['destructiveHint'] != true;
    return McpRemoteTool(
      name,
      _shortText((data['description'] ?? name).toString(), 1600),
      Map<String, dynamic>.from(schema),
      safe,
      _extraHints(annotations),
    );
  }

  static Map<String, bool> _extraHints(Object? value) => value is Map
      ? {
          for (final key in [
            'destructiveHint',
            'openWorldHint',
            'idempotentHint',
          ])
            if (value[key] is bool) key: value[key] as bool,
        }
      : {};

  String alias(String connection) {
    final readable = name.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
    return 'mcp_${connection.substring(0, 10)}_${_shortText(readable, 32)}_${_hash(name).substring(0, 8)}';
  }
}

class _Expired implements Exception {}

class _Session {
  _Session(this.endpoint, this.token);
  final Uri endpoint;
  final String token;
  final http.Client client = http.Client();
  String? session, version;
  int nextId = 0;

  Map<String, String> get headers => {
    'Accept': 'application/json, text/event-stream',
    'Content-Type': 'application/json',
    if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    'Mcp-Session-Id': ?session,
    'MCP-Protocol-Version': ?version,
  };
  Future<http.StreamedResponse> post(Map object) async {
    final req = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll(headers)
      ..body = jsonEncode(object);
    final r = await client.send(req);
    if (r.statusCode == 404 && session != null) throw _Expired();
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw FormatException('MCP 服务返回 HTTP ${r.statusCode}。');
    }
    return r;
  }

  Future<void> initialized() async {
    final result = await rpc('initialize', {
      'protocolVersion': _versions.first,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'orb-mobile', 'version': '1.0'},
    });
    if (!_versions.contains(result['protocolVersion']) ||
        result['capabilities'] is! Map ||
        result['capabilities']['tools'] is! Map) {
      throw const FormatException('服务未协商出手机支持的 MCP 工具协议。');
    }
    version = result['protocolVersion'] as String;
    final r = await post({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    await r.stream.listen(null).cancel();
  }

  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++nextId;
    final r = await post({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    if (method == 'initialize') {
      final sid = r.headers['mcp-session-id'];
      if (sid != null &&
          (sid.length > 512 || !RegExp(r'^[!-~]+$').hasMatch(sid))) {
        throw const FormatException('服务返回了无效的会话标识。');
      }
      session = sid;
    }
    var bytes = 0;
    final stream = r.stream.map((part) {
      bytes += part.length;
      if (bytes > _maxBody) throw const FormatException('MCP 单次响应超过 2 MiB。');
      return part;
    });
    final type = r.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (type == 'application/json') {
      return _result(jsonDecode(await utf8.decoder.bind(stream).join()), id);
    }
    if (type != 'text/event-stream') {
      throw const FormatException('MCP 服务返回了不支持的响应格式。');
    }
    final lines = <String>[];
    Future<Map<String, dynamic>?> event() async {
      if (lines.isEmpty) return null;
      final raw = lines.join('\n');
      lines.clear();
      if (raw.isEmpty) {
        return null; // MCP may prime an event stream with an empty event.
      }
      final obj = jsonDecode(raw);
      if (obj is! Map || obj['jsonrpc'] != '2.0') {
        throw const FormatException('无法读取 MCP 事件。');
      }
      if (obj.containsKey('method')) {
        if (obj['id'] != null) {
          final response = await post({
            'jsonrpc': '2.0',
            'id': obj['id'],
            if (obj['method'] == 'ping')
              'result': <String, dynamic>{}
            else
              'error': {'code': -32601, 'message': 'Method not supported'},
          });
          await response.stream.listen(null).cancel();
        }
        return null;
      }
      if (obj['id'] != id) return null;
      return _result(obj, id);
    }

    await for (final line
        in utf8.decoder.bind(stream).transform(const LineSplitter())) {
      if (line.isEmpty) {
        final value = await event();
        if (value != null) return value;
      } else if (line == 'data' || line.startsWith('data:')) {
        final s = line.length < 5 ? '' : line.substring(5);
        lines.add(s.startsWith(' ') ? s.substring(1) : s);
      }
    }
    final value = await event();
    if (value == null) throw const FormatException('MCP 流在响应完成前中断。');
    return value;
  }

  Map<String, dynamic> _result(dynamic response, int id) {
    if (response is! Map ||
        response['jsonrpc'] != '2.0' ||
        response['id'] != id) {
      throw const FormatException('MCP 响应未匹配本次请求。');
    }
    if (response['error'] case final Map error) {
      final code = error['code'];
      throw FormatException('MCP 请求失败${code is int ? '（$code）' : ''}。');
    }
    final result = response['result'];
    if (result is! Map) throw const FormatException('MCP 响应中没有结果。');
    return Map<String, dynamic>.from(result);
  }

  Future<List<McpRemoteTool>> catalog() async {
    final items = <McpRemoteTool>[], names = <String>{}, cursors = <String>{};
    String? next;
    for (var i = 0; i < 24; i++) {
      final result = await rpc('tools/list', {'cursor': ?next});
      final tools = result['tools'];
      if (tools is! List) throw const FormatException('服务返回的工具清单无效。');
      for (final item in tools) {
        if (item is! Map) throw const FormatException('工具格式无效。');
        final t = McpRemoteTool.parse(item);
        if (!names.add(t.name)) throw const FormatException('MCP 服务重复声明了工具名称。');
        items.add(t);
        if (items.length > 256) {
          throw const FormatException('单个服务最多可载入 256 个工具。');
        }
      }
      final cursor = result['nextCursor'];
      if (cursor == null || cursor == '') return items;
      if (cursor is! String || !cursors.add(cursor)) break;
      next = cursor;
    }
    throw const FormatException('工具清单分页无效或过多。');
  }

  Future<void> close() async {
    if (session != null) {
      try {
        final r = await client
            .send(
              http.Request('DELETE', endpoint)
                ..followRedirects = false
                ..headers.addAll(headers),
            )
            .timeout(const Duration(seconds: 2));
        await r.stream.listen(null).cancel();
      } catch (_) {
        /* A server may expire its own sessions or reject DELETE. */
      }
    }
    client.close();
  }
}

/// One bounded Streamable HTTP session for user-requested discovery or execution.
class McpClient {
  McpClient(String address, [this.token = ''])
    : endpoint = mcpEndpoint(address) {
    if (token.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('令牌中有换行符。');
    }
  }
  final Uri endpoint;
  final String token;
  Future<T> _using<T>(
    Future<T> Function(_Session s) operation, {
    bool retryExpired = true,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final s = _Session(endpoint, token);
      try {
        return await (() async {
          await s.initialized();
          return await operation(s);
        })().timeout(
          const Duration(seconds: 35),
          onTimeout: () {
            s.client.close();
            throw const FormatException('MCP 服务响应超时。');
          },
        );
      } on _Expired {
        if (!retryExpired || attempt == 1) {
          throw const FormatException('MCP 会话已失效，请核对服务端状态。');
        }
      } on http.ClientException {
        throw const FormatException('无法连接 MCP 服务。');
      } on SocketException {
        throw const FormatException('无法连接 MCP 服务。');
      } finally {
        await s.close();
      }
    }
    throw const FormatException('无法建立 MCP 会话。');
  }

  Future<List<McpRemoteTool>> list() => _using((s) => s.catalog());
  Future<Map<String, dynamic>> call(
    McpRemoteTool approved,
    Map<String, dynamic> args, {
    bool Function()? stillAllowed,
    bool confirmedWrite = false,
  }) => _using((s) async {
    final tools = await s.catalog();
    final current = tools.where((t) => t.name == approved.name).firstOrNull;
    if ((!approved.readOnly && !confirmedWrite) ||
        current == null ||
        current.signature != approved.signature ||
        stillAllowed?.call() == false) {
      throw const FormatException('工具被停用或声明已更改。请在设置中重新检查并选择。');
    }
    final result = await s.rpc('tools/call', {
      'name': current.name,
      'arguments': args,
    });
    if (result['isError'] == true) {
      throw const FormatException('远端 MCP 工具执行失败。');
    }
    final content = result['content'];
    if (content is! List) throw const FormatException('MCP 工具结果格式无效。');
    final parts = <String>[];
    for (final p in content.whereType<Map>()) {
      if (p['type'] == 'text' && p['text'] is String) {
        parts.add(p['text'] as String);
      }
      if (p['type'] == 'resource' &&
          p['resource'] is Map &&
          p['resource']['text'] is String) {
        parts.add(p['resource']['text'] as String);
      }
      if (p['type'] == 'resource_link' && p['uri'] is String) {
        parts.add('${p['name'] ?? ''} ${p['uri']}');
      }
    }
    final structured = result['structuredContent'];
    final text = parts.join('\n');
    final jsonSize = structured is Map ? jsonEncode(structured).length : 0;
    if (text.isEmpty && jsonSize == 0 && content.isNotEmpty) {
      throw const FormatException('此工具返回了手机暂不支持的媒体内容。');
    }
    return {
      'ok': true,
      'tool': current.name,
      if (text.isNotEmpty) 'text': _shortText(text, 12000),
      if (jsonSize > 0 && jsonSize <= 12000) 'structured': structured,
      if (jsonSize > 12000 && text.isEmpty)
        'text': _shortText(jsonEncode(structured), 12000),
      if (text.runes.length > 12000 || jsonSize > 12000) 'truncated': true,
    };
  }, retryExpired: approved.readOnly);
}

class McpConnection {
  const McpConnection(
    this.id,
    this.name,
    this.origin,
    this.catalog,
    this.allowed,
  );
  final String id, name, origin;
  final List<McpRemoteTool> catalog;
  final Set<String> allowed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'origin': origin,
    'catalog': catalog.map((t) => t.toJson()).toList(),
    'allowed': allowed.toList(),
  };
  static McpConnection fromJson(Map data) => McpConnection(
    data['id'] as String,
    data['name'] as String,
    data['origin'] as String,
    (data['catalog'] as List)
        .map((e) => McpRemoteTool.parse(e as Map))
        .toList(),
    Set<String>.from(data['allowed'] as List),
  );
}

typedef McpSecretRead = Future<String?> Function(String id);
typedef McpSecretWrite = Future<void> Function(String id, String? value);

/// Catalogs and per-tool consent stay on this device. Endpoints and tokens live in Keychain/Keystore.
class McpConnections {
  const McpConnections(this.directory, this._read, this._write);
  final Directory directory;
  final McpSecretRead _read;
  final McpSecretWrite _write;
  static const _secrets = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static Future<McpConnections> open() async => McpConnections(
    Directory('${await getDatabasesPath()}/orb-local/mcp'),
    (id) => _secrets.read(key: 'orb.mcp.$id'),
    (id, value) => value == null
        ? _secrets.delete(key: 'orb.mcp.$id')
        : _secrets.write(key: 'orb.mcp.$id', value: value),
  );

  File _file(String id) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
      throw const FormatException('无效的 MCP 连接 ID。');
    }
    return File('${directory.path}/$id.json');
  }

  McpConnection? get(String id) {
    final f = _file(id);
    return f.existsSync()
        ? McpConnection.fromJson(jsonDecode(f.readAsStringSync()) as Map)
        : null;
  }

  List<McpConnection> list() {
    if (!directory.existsSync()) return [];
    return [
      for (final f in directory.listSync().whereType<File>())
        if (f.path.endsWith('.json'))
          McpConnection.fromJson(jsonDecode(f.readAsStringSync()) as Map),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  void _save(McpConnection config) {
    final f = _file(config.id);
    directory.createSync(recursive: true);
    final temp = File('${f.path}.next');
    temp.writeAsStringSync(jsonEncode(config.toJson()), flush: true);
    temp.renameSync(f.path);
  }

  Future<McpConnection> add(String name, String address, String token) async {
    final label = name.trim();
    if (label.isEmpty || label.length > 96) {
      throw const FormatException('请输入连接名称（最多 96 字符）。');
    }
    final client = McpClient(address, token.trim()), uri = client.endpoint;
    final id = _hash(uri.toString());
    if (get(id) != null) throw const FormatException('这个地址已经添加，修改凭据请移除后重新添加。');
    final tools = await client.list();
    final row = McpConnection(id, label, uri.origin, tools, {});
    await _write(
      id,
      jsonEncode({'url': uri.toString(), 'token': token.trim()}),
    );
    try {
      _save(row);
    } catch (_) {
      await _write(id, null);
      rethrow;
    }
    return row;
  }

  Future<McpClient> _client(String id) async {
    final value = await _read(id);
    if (value == null) throw const FormatException('连接凭据不可用，请重新添加连接。');
    final data = jsonDecode(value) as Map;
    return McpClient(data['url'] as String, data['token'] as String);
  }

  Future<void> refresh(String id) async {
    final tools = await (await _client(id)).list();
    final old = get(id);
    if (old == null) throw const FormatException('连接已移除。');
    final known = {for (final t in old.catalog) t.name: t.signature};
    final allowed = {
      for (final t in tools)
        if (old.allowed.contains(t.name) && t.signature == known[t.name])
          t.name,
    };
    _save(McpConnection(id, old.name, old.origin, tools, allowed));
  }

  void allow(
    String id,
    String tool,
    bool enabled, {
    bool permitWrites = false,
  }) {
    final row = get(id);
    if (row == null) throw const FormatException('连接已移除。');
    final t = row.catalog.where((t) => t.name == tool).firstOrNull;
    if (t == null || enabled && !t.readOnly && !permitWrites) {
      throw const FormatException('仅可启用服务声明为只读的工具。');
    }
    final next = Set<String>.of(row.allowed);
    if (enabled) {
      next.add(tool);
    } else {
      next.remove(tool);
    }
    _save(McpConnection(id, row.name, row.origin, row.catalog, next));
  }

  Future<void> remove(String id) async {
    final f = _file(id);
    if (f.existsSync()) f.deleteSync();
    await _write(id, null);
  }

  List<ChatTool> get tools => toolsForTurn();
  List<ChatTool> toolsForTurn({bool interactive = false}) => [
    for (final c in list())
      for (final t in c.catalog)
        if ((t.readOnly || interactive) && c.allowed.contains(t.name))
          ChatTool(
            name: t.alias(c.id),
            description:
                '${c.name}: ${t.description}${t.readOnly ? '' : ' (requires user confirmation each time)'}',
            parameters: t.schema,
          ),
  ];
  bool owns(String name) => name.startsWith('mcp_');
  Future<Map<String, dynamic>> execute(
    ChatToolCall call, {
    ReviewAction? review,
    bool Function()? active,
  }) async {
    for (final c in list()) {
      for (final t in c.catalog) {
        if ((t.readOnly || review != null) &&
            c.allowed.contains(t.name) &&
            t.alias(c.id) == call.name) {
          if (!t.readOnly) {
            final details = [
              c.name,
              c.origin,
              t.name,
              const JsonEncoder.withIndent('  ').convert(call.arguments),
            ].join('\n\n');
            if (active?.call() == false ||
                !await review!('允许工具更改数据？', details, '允许这次操作')) {
              throw const FormatException('用户已取消此次工具操作。');
            }
          }
          return (await _client(c.id)).call(
            t,
            call.arguments,
            confirmedWrite: !t.readOnly && review != null,
            stillAllowed: () {
              final row = get(c.id);
              return (t.readOnly || active?.call() != false) &&
                  row != null &&
                  row.allowed.contains(t.name) &&
                  row.catalog.any(
                    (x) => x.name == t.name && x.signature == t.signature,
                  );
            },
          );
        }
      }
    }
    throw const FormatException('这个 MCP 工具尚未授权或已移除。');
  }
}
