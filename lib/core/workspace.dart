import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'tool_types.dart';

const workspaceFileLimit = 1024 * 1024;

String workspacePath(String input) {
  final path = input.trim();
  final parts = path.split('/');
  if (path.isEmpty ||
      path.length > 220 ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.length > 100 ||
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(r'[\\:*?"<>|\x00-\x1f\x7f]').hasMatch(part) ||
            RegExp(
              r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw const OrbException('请使用可迁移的相对文件路径，例如 读书/摘录.md。');
  }
  return path;
}

class WorkFile {
  const WorkFile(this.path, this.text);
  final String path;
  final String text;
  String get hash => sha256.convert(utf8.encode(text)).toString();
}

typedef WorkImport = ({WorkFile file, String originalHash});

class Workspace {
  Workspace(this.db);
  final Database db;
  static Future<Workspace> open() async {
    final root = Directory('${await getDatabasesPath()}/orb-local');
    await root.create(recursive: true);
    final db = await openDatabase(
      '${root.path}/workspace.db',
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE files(path TEXT PRIMARY KEY COLLATE NOCASE, body TEXT NOT NULL, hash TEXT NOT NULL)',
      ),
    );
    return Workspace(db);
  }

  Future<List<String>> paths() async => [
    for (final row in await db.query(
      'files',
      columns: ['path'],
      orderBy: 'path COLLATE NOCASE',
    ))
      row['path'] as String,
  ];
  Future<WorkFile?> read(String name) async {
    final rows = await db.query(
      'files',
      where: 'path=?',
      whereArgs: [workspacePath(name)],
    );
    return rows.isEmpty
        ? null
        : WorkFile(rows.first['path'] as String, rows.first['body'] as String);
  }

  Future<void> save(WorkFile file, {String? previous}) =>
      db.transaction((tx) => _save(tx, file, previous: previous));
  Future<void> _save(
    DatabaseExecutor tx,
    WorkFile file, {
    String? previous,
  }) async {
    final path = workspacePath(file.path);
    if (utf8.encode(file.text).length > workspaceFileLimit) {
      throw const OrbException('每个工作文件最多 1 MiB。');
    }
    final old = await tx.query(
      'files',
      columns: ['hash'],
      where: 'path=?',
      whereArgs: [path],
    );
    if (old.isNotEmpty && old.first['hash'] == file.hash) return;
    if ((old.firstOrNull?['hash']) != previous) {
      throw const OrbException('文件已有其他内容。请重新打开后编辑，或另存为新文件。');
    }
    // A portable directory cannot contain both a file and its descendant.
    final collision = await tx.rawQuery(
      "SELECT path FROM files WHERE instr(lower(path),lower(?)||'/')=1 OR instr(lower(?),lower(path)||'/')=1 LIMIT 1",
      [path, path],
    );
    if (collision.isNotEmpty) throw const OrbException('该路径与已有文件或目录冲突。');
    await tx.insert('files', {
      'path': path,
      'body': file.text,
      'hash': file.hash,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> remove(String path) async {
    await db.delete('files', where: 'path=?', whereArgs: [workspacePath(path)]);
  }

  Future<({String path, bool changed, bool conflict})> importFile(
    WorkImport item,
  ) => db.transaction((tx) async {
    final path = workspacePath(item.file.path);
    final old = await tx.query(
      'files',
      columns: ['hash'],
      where: 'path=?',
      whereArgs: [path],
    );
    final oldHash = old.firstOrNull?['hash'] as String?;
    if (oldHash == item.file.hash ||
        oldHash != null && item.originalHash == item.file.hash) {
      return (path: path, changed: false, conflict: false);
    }
    if (oldHash == null || oldHash == item.originalHash) {
      await _save(tx, item.file, previous: oldHash);
      return (path: path, changed: true, conflict: false);
    }
    final slash = path.lastIndexOf('/'), dot = path.lastIndexOf('.');
    final split = dot > slash + 1 ? dot : path.length;
    final ext = path.substring(split), stem = path.substring(0, split);
    for (var i = 1; i <= 9999; i++) {
      final suffix = ' (导入${i == 1 ? '' : ' $i'})';
      var next = '$stem$suffix$ext';
      if (next.length > 220 || next.length - slash - 1 > 100) {
        final source = sha256
            .convert(utf8.encode(path))
            .toString()
            .substring(0, 12);
        next = '$source$suffix${ext.length <= 16 ? ext : ''}';
      }
      final existing = await tx.query(
        'files',
        columns: ['hash'],
        where: 'path=?',
        whereArgs: [next],
      );
      if (existing.firstOrNull?['hash'] == item.file.hash) {
        return (path: next, changed: false, conflict: true);
      }
      if (existing.isEmpty) {
        await _save(tx, WorkFile(next, item.file.text));
        return (path: next, changed: true, conflict: true);
      }
    }
    throw const OrbException('同名副本过多，请更改文件名。');
  });

  static const _string = {'type': 'string'};
  static ChatTool _tool(
    String name,
    String help,
    Map<String, dynamic> fields,
    List<String> required,
  ) => ChatTool(
    name: name,
    description: help,
    parameters: {
      'type': 'object',
      'properties': fields,
      'required': required,
      'additionalProperties': false,
    },
  );
  static final definitions = [
    _tool(
      'workspace_list',
      'List paths in the user’s Orb workspace. An optional prefix filters paths. Results are paginated.',
      {
        'prefix': _string,
        'offset': {'type': 'integer'},
      },
      [],
    ),
    _tool(
      'workspace_read',
      'Read a UTF-8 file in the Orb workspace. Returns exact content, SHA-256 and next offset. Offsets count Unicode code points.',
      {
        'path': _string,
        'offset': {'type': 'integer'},
      },
      ['path'],
    ),
    _tool(
      'workspace_search',
      'Find literal text in workspace file paths and contents. Returns matched lines.',
      {
        'query': _string,
        'prefix': _string,
        'offset': {'type': 'integer'},
      },
      ['query'],
    ),
    _tool(
      'workspace_write',
      'Create a text file, or overwrite one the user asked to change. First read an existing file and provide its sha256 as expected_hash.',
      {'path': _string, 'text': _string, 'expected_hash': _string},
      ['path', 'text'],
    ),
    _tool(
      'workspace_edit',
      'Replace one unique exact text occurrence in a workspace file. Read first; provide expected_hash from that read.',
      {
        'path': _string,
        'old_text': _string,
        'new_text': _string,
        'expected_hash': _string,
      },
      ['path', 'old_text', 'new_text', 'expected_hash'],
    ),
  ];
  Future<Map<String, dynamic>> run(ChatToolCall call) async {
    final a = call.arguments;
    String arg(String key) {
      final value = a[key];
      if (value is! String) throw OrbException('缺少文本参数 $key。');
      return value;
    }

    final offset = a['offset'] ?? 0;
    if (offset is! int || offset < 0) {
      throw const OrbException('offset 必须是大于或等于零的整数。');
    }
    switch (call.name) {
      case 'workspace_list':
        final rows = (await paths())
            .where((p) => p.startsWith(a['prefix'] as String? ?? ''))
            .skip(offset)
            .take(101)
            .toList();
        return {
          'paths': rows.take(100).toList(),
          if (rows.length > 100) 'next_offset': offset + 100,
        };
      case 'workspace_search':
        final query = arg('query').trim().toLowerCase(),
            prefix = a['prefix'] as String? ?? '';
        if (query.isEmpty) throw const OrbException('请输入要查找的文字。');
        final hits = <Map<String, dynamic>>[];
        var skipped = 0;
        for (final row in await db.rawQuery(
          'SELECT path,body FROM files WHERE instr(path,?)=1 AND (instr(lower(path),?)>0 OR instr(lower(body),?)>0) ORDER BY path',
          [prefix, query, query],
        )) {
          final path = row['path'] as String,
              lines = (row['body'] as String).split('\n');
          final positions = [
            if (path.toLowerCase().contains(query)) -1,
            for (var i = 0; i < lines.length; i++)
              if (lines[i].toLowerCase().contains(query)) i,
          ];
          for (final i in positions) {
            if (skipped++ < offset) continue;
            if (hits.length == 30) {
              return {'matches': hits, 'next_offset': offset + 30};
            }
            hits.add({
              'path': path,
              if (i >= 0) 'line': i + 1,
              if (i >= 0)
                'text': String.fromCharCodes(lines[i].runes.take(200)),
            });
          }
        }
        return {'matches': hits};
      case 'workspace_read':
        final file = await read(arg('path'));
        if (file == null) throw const OrbException('找不到工作文件。');
        final slice = file.text.runes.skip(offset).take(8001).toList();
        return {
          'path': file.path,
          'sha256': file.hash,
          'text': String.fromCharCodes(slice.take(8000)),
          if (slice.length > 8000) 'next_offset': offset + 8000,
        };
      case 'workspace_write':
      case 'workspace_edit':
        final path = workspacePath(arg('path'));
        late final String body;
        if (call.name == 'workspace_edit') {
          final f = await read(path),
              old = arg('old_text'),
              replacement = arg('new_text');
          if (f == null ||
              old.isEmpty ||
              !f.text.contains(old) ||
              f.text.indexOf(old) != f.text.lastIndexOf(old)) {
            throw const OrbException('待替换片段需在文件中唯一出现。');
          }
          body = f.text.replaceFirst(old, replacement);
        } else {
          body = arg('text');
        }
        final file = WorkFile(path, body);
        await save(file, previous: a['expected_hash'] as String?);
        return {
          'path': path,
          'sha256': file.hash,
          'bytes': utf8.encode(body).length,
        };
      default:
        throw const OrbException('没有这个工作区工具。');
    }
  }
}
