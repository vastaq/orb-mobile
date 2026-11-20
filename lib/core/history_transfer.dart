import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import 'models.dart';

class HistoryEntry {
  const HistoryEntry(this.sourceId, this.title, this.messageCount);
  final String sourceId;
  final String title;
  final int messageCount;
}

class ImportedThread {
  const ImportedThread(
    this.sourceId,
    this.title,
    this.messages, {
    this.otherNodes = 0,
    this.missingFiles = 0,
  });
  final String sourceId;
  final String title;
  final List<OrbMessage> messages;
  final int otherNodes;
  final int missingFiles;
}

Future<List<HistoryEntry>> previewDeepSeekHistory(String path) => Isolate.run(
  () => _readSource(
    path,
    (records, _) => [for (final record in records) _entry(record)],
    indexOnly: true,
  ),
);

Future<List<ImportedThread>> loadDeepSeekHistory(
  String path,
  Set<String> ids,
) => Isolate.run(
  () => _readSource(
    path,
    (records, archivedFile) => [
      for (final record in records)
        if (ids.contains(_id(record))) _convertThread(record, archivedFile),
    ],
    selected: ids,
  ),
);

typedef _Record = Map<String, dynamic>;
typedef _FileLookup = ArchiveFile? Function(String name);

T _readSource<T>(
  String path,
  T Function(List<_Record>, _FileLookup) convert, {
  bool indexOnly = false,
  Set<String>? selected,
}) {
  final file = File(path);
  final handle = file.openSync();
  late final bool isZip;
  try {
    final magic = handle.readSync(4);
    isZip = magic.length >= 4 && magic[0] == 0x50 && magic[1] == 0x4b;
  } finally {
    handle.closeSync();
  }
  if (!isZip) {
    return convert(_records(jsonDecode(file.readAsStringSync())), (_) => null);
  }

  final stream = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(stream, verify: true);
    final entries = <String, ArchiveFile>{
      for (final f in archive)
        if (f.isFile && !f.name.startsWith('__MACOSX/')) f.name: f,
    };
    String? locate(String name) => entries.containsKey(name)
        ? name
        : entries.keys.where((p) => p.endsWith('/$name')).firstOrNull;
    final manifest = locate('manifest.json');
    if (manifest != null) {
      final info = _jsonFile(entries[manifest]!);
      if (info is! Map || info['export_format_version'] != 3) {
        throw const FormatException(
          '暂不支持这份归档的版本。请选择 DeepSeek v3 或 conversations.json。',
        );
      }
      final root = manifest.substring(
        0,
        manifest.length - 'manifest.json'.length,
      );
      final prefix = '${root}chat_sessions/';
      final sessions = <String, ArchiveFile>{};
      for (final f in entries.values) {
        if (!f.name.startsWith(prefix)) continue;
        final suffix = f.name.substring(prefix.length);
        if (!suffix.contains('/') && suffix.endsWith('.json')) {
          sessions[suffix.substring(0, suffix.length - 5)] = f;
        }
      }
      final indexFile = entries['${root}chat_session_index.json'];
      if (indexFile != null) {
        final raw = _jsonFile(indexFile);
        if (raw is! List || raw.any((row) => row is! _Record)) {
          throw const FormatException('无法读取导出文件的会话索引。');
        }
        final rows = raw.cast<_Record>();
        final indexIds = rows.map((r) => r['id']).toSet();
        if (rows.length != sessions.length ||
            indexIds.length != rows.length ||
            !sessions.keys.every(indexIds.contains)) {
          throw const FormatException('归档缺失会话，请重新导出。');
        }
        if (indexOnly) return convert(rows, (_) => null);
      }
      final records = <_Record>[];
      for (final session in sessions.entries) {
        if (selected != null && !selected.contains('deepseek:${session.key}')) {
          continue;
        }
        final record = _jsonFile(session.value);
        if (record is! _Record || record['id']?.toString() != session.key) {
          throw const FormatException('会话文件与归档索引不匹配。');
        }
        records.add(record);
      }
      return convert(records, (name) => entries['$root$name']);
    }
    final old = locate('conversations.json');
    if (old == null) throw const FormatException('未找到 DeepSeek 会话文件。');
    final root = old.substring(0, old.length - 'conversations.json'.length);
    return convert(
      _records(_jsonFile(entries[old]!)),
      (name) => entries['$root$name'],
    );
  } finally {
    stream.closeSync();
  }
}

dynamic _jsonFile(ArchiveFile f) => jsonDecode(utf8.decode(f.content));

List<_Record> _records(dynamic value) {
  if (value is _Record && value['conversations'] is List) {
    value = value['conversations'];
  }
  final records = value is List ? value : [value];
  if (records.any(
    (r) => r is! _Record || (r['messages'] is! List && r['mapping'] is! Map),
  )) {
    throw const FormatException('未识别的会话格式。请选择 DeepSeek 导出的 JSON 或 ZIP。');
  }
  return records.cast<_Record>();
}

String _id(_Record record) {
  final id = (record['id'] ?? record['conversation_id'])?.toString();
  if (id == null || id.trim().isEmpty) {
    throw const FormatException('导出记录缺少会话 ID。');
  }
  return 'deepseek:$id';
}

String _title(_Record record) {
  final title = record['title'];
  return title is String && title.trim().isNotEmpty ? title.trim() : '未命名对话';
}

HistoryEntry _entry(_Record r) {
  final list = r['messages'];
  final tree = r['mapping'];
  final indexed = r['message_count'];
  if (list is! List && tree is! Map) {
    if (indexed is int && indexed >= 0) {
      return HistoryEntry(_id(r), _title(r), indexed);
    }
    throw const FormatException('缺少消息内容。');
  }
  final count = list is List
      ? list.length
      : (tree as Map).values
            .where((m) => m is Map && m['message'] != null)
            .length;
  return HistoryEntry(_id(r), _title(r), count);
}

List<_Record> _mainBranch(_Record record) {
  final modern = record['messages'] is List;
  final mapping = record['mapping'];
  final nodes = <String, _Record>{};
  if (modern) {
    for (final item in record['messages']) {
      if (item is! _Record ||
          item['id'] == null ||
          nodes.containsKey(item['id'].toString())) {
        throw const FormatException('消息 ID 无效。');
      }
      nodes[item['id'].toString()] = item;
    }
  } else if (mapping is Map) {
    for (final entry in mapping.entries) {
      if (entry.value is! _Record) throw const FormatException('消息节点无效。');
      nodes[entry.key.toString()] = entry.value as _Record;
    }
  }
  if (nodes.isEmpty) return [];
  final selected = record['current_message_id'] ?? record['current_node'];
  final path = <_Record>[];
  final visited = <String>{};
  if (selected != null || modern) {
    String? cursor = selected?.toString() ?? nodes.keys.last;
    while (cursor != null) {
      final node = nodes[cursor];
      if (node == null || !visited.add(cursor)) {
        throw const FormatException('消息分支损坏，请重新导出。');
      }
      final message = modern ? node : node['message'];
      if (message is _Record) path.add(message);
      cursor = node[modern ? 'parent_id' : 'parent']?.toString();
    }
    return path.reversed.toList();
  }
  // The old DeepSeek export has no active leaf; its first child is the
  // selected continuation in the ordered mapping.
  String? cursor = nodes.containsKey('root')
      ? 'root'
      : nodes.entries.where((e) => e.value['parent'] == null).firstOrNull?.key;
  if (cursor == null) throw const FormatException('找不到会话起点。');
  while (cursor != null) {
    final node = nodes[cursor];
    if (node == null || !visited.add(cursor)) {
      throw const FormatException('消息分支损坏，请重新导出。');
    }
    if (node['message'] is _Record) path.add(node['message'] as _Record);
    final children = node['children'];
    cursor = children is List && children.isNotEmpty
        ? children.first.toString()
        : null;
  }
  return path;
}

ImportedThread _convertThread(_Record record, _FileLookup findFile) {
  final entry = _entry(record);
  final path = _mainBranch(record);
  final messages = <OrbMessage>[];
  var missing = 0;
  for (final raw in path) {
    final fragments =
        (raw['fragments'] is List ? raw['fragments'] as List : const [])
            .whereType<_Record>()
            .toList();
    final types = fragments.map((f) => f['type']).toSet();
    final author = raw['author'];
    String? role = (raw['role'] ?? (author is Map ? author['role'] : null))
        ?.toString()
        .toLowerCase();
    role ??=
        types.contains('REQUEST') ||
            types.contains('FILE') && !types.contains('RESPONSE')
        ? 'user'
        : 'assistant';
    if (role != 'assistant' && role != 'user') continue;
    final parts = <String>[];
    final metadata = <String, dynamic>{};
    final thinking = <String>[];
    final attachments = <OrbAttachment>[];
    final seenFiles = <String>{};
    final files = <_Record>[
      if (raw['files'] is List) ...(raw['files'] as List).whereType<_Record>(),
    ];
    for (final frag in fragments) {
      final content = frag['content'];
      switch (frag['type']) {
        case 'REQUEST' || 'RESPONSE' || 'TEMPLATE_RESPONSE':
          if (content is String) parts.add(content);
        case 'THINK' || 'THINKING':
          if (content is String) thinking.add(content);
        case 'FILE':
          if (frag['files'] is List) {
            files.addAll((frag['files'] as List).whereType<_Record>());
          }
        default:
          (metadata['importedFragments'] ??= <_Record>[]).add(frag);
      }
    }
    if (thinking.isNotEmpty) {
      metadata['native'] = {'reasoning_content': thinking.join('\n')};
    }
    metadata['provider'] = 'deepseek';
    if (parts.isEmpty && raw['content'] is String) {
      parts.add(raw['content'] as String);
    }
    for (final f in files) {
      final name = (f['file_name'] ?? f['name'] ?? '附件').toString();
      final id = (f['id'] ?? name).toString();
      if (!seenFiles.add(id)) continue;
      final location = f['export_path'];
      final sessionDir = 'chat_sessions/${record['id']}_files/';
      final safe =
          location is String &&
          !location.startsWith('/') &&
          !location.contains('\\') &&
          !location.split('/').contains('..') &&
          (record['mapping'] != null || location.startsWith(sessionDir));
      final asset = safe ? findFile(location) : null;
      final bytes = asset?.content;
      final type = _mime(name, bytes);
      if (bytes == null) missing++;
      attachments.add(
        OrbAttachment(
          name: name,
          mime: type,
          dataUrl: bytes == null
              ? ''
              : 'data:$type;base64,${base64Encode(bytes)}',
        ),
      );
    }
    final status = switch (raw['status']?.toString().toUpperCase()) {
      'WIP' || 'INCOMPLETE' => 'stopped',
      'FAILED' ||
      'TIMEOUT' ||
      'CONTEXT_LENGTH_EXCEEDED' ||
      'CONTENT_FILTER' => 'error',
      _ => 'complete',
    };
    if (parts.isNotEmpty || attachments.isNotEmpty || metadata.isNotEmpty) {
      messages.add(
        OrbMessage(
          role,
          parts.join(),
          status: status,
          attachments: attachments,
          metadata: metadata,
        ),
      );
    }
  }
  return ImportedThread(
    entry.sourceId,
    entry.title,
    messages,
    otherNodes: entry.messageCount - path.length,
    missingFiles: missing,
  );
}

String _mime(String name, List<int>? bytes) {
  if (bytes != null && bytes.length >= 12) {
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (String.fromCharCodes(bytes.take(3)) == 'GIF') return 'image/gif';
    if (String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
  }
  return switch (name.split('.').last.toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'avif' => 'image/avif',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };
}

Future<String> threadMarkdown(String title, List<OrbMessage> messages) async {
  final output = StringBuffer(
    '# ${title.trim().replaceAll(RegExp(r'[\r\n]+'), ' ')}\n',
  );
  for (final m in messages) {
    output.writeln('\n## ${m.role == 'user' ? '我' : 'Orb'}\n');
    if (m.text.isNotEmpty) output.writeln(m.text);
    for (final file in m.attachments) {
      final label = file.name
          .replaceAll('\\', '\\\\')
          .replaceAll('[', '\\[')
          .replaceAll(']', '\\]');
      if (file.isImage && (file.dataUrl.isNotEmpty || file.localPath != null)) {
        try {
          output.writeln('\n![$label](${await file.asDataUrl()})');
          continue;
        } on FileSystemException {
          // Keep the original file name when a saved local asset is unavailable.
        }
      }
      output.writeln('\n附件：${file.name}');
    }
    final native = m.metadata['native'];
    final thought = native is Map ? native['reasoning_content'] : null;
    if (thought is String && thought.isNotEmpty) {
      output.writeln(
        '\n<details><summary>思考记录</summary>\n\n$thought\n\n</details>',
      );
    }
  }
  return output.toString();
}
