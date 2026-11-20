import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
      'Read exact file text and its sha256. Use start_line (1-based) and '
          'line_count (default 40) for context around a search hit. Alternatively '
          'use offset (Unicode code points, default 0). Follow next_offset to '
          'continue after the returned text, including in a long line.',
      {
        'path': _string,
        'offset': {'type': 'integer', 'minimum': 0},
        'start_line': {'type': 'integer', 'minimum': 1},
        'line_count': {'type': 'integer', 'minimum': 1, 'maximum': 200},
      },
      ['path'],
    ),
    _tool(
      'workspace_search',
      'Find literal text in paths and file contents. Results include 1-based '
          'line numbers and exact excerpts around matches. Use file_hashes[path] '
          'as expected_hash to edit a unique match, or read nearby lines for context. '
          'Search offset paginates matches.',
      {
        'query': _string,
        'prefix': _string,
        'offset': {'type': 'integer'},
      },
      ['query'],
    ),
    _tool(
      'workspace_write',
      'Create a text file, or overwrite one the user asked to change. Read the '
          'entire existing file with workspace_read first and provide its sha256 as expected_hash.',
      {'path': _string, 'text': _string, 'expected_hash': _string},
      ['path', 'text'],
    ),
    _tool(
      'workspace_edit',
      'Replace one unique exact occurrence. Provide the file sha256 from '
          'workspace_read or file_hashes[path] from workspace_search as expected_hash. '
          'Read surrounding lines to disambiguate repeated text.',
      {
        'path': _string,
        'old_text': _string,
        'new_text': _string,
        'expected_hash': _string,
      },
      ['path', 'old_text', 'new_text', 'expected_hash'],
    ),
  ];

  static String _matchExcerpt(String line, Match match) {
    const width = 200;
    if (line.length <= width) return line;
    final runes = line.runes.toList();
    if (runes.length <= width) return line;
    final before = line.substring(0, match.start).runes.length;
    final matched = match.group(0)!.runes.length;
    final margin = math.max(0, (width - matched) ~/ 2);
    final start = (before - margin).clamp(0, runes.length - width);
    return String.fromCharCodes(runes, start, start + width);
  }

  static Map<String, dynamic> _readPage(
    WorkFile file,
    Map<String, dynamic> arguments,
    int offset,
  ) {
    const limit = 8000;
    var startOffset = offset;
    Iterable<int> content = file.text.runes.skip(offset);
    int? firstLine, nextLine;
    if (arguments['start_line'] != null || arguments['line_count'] != null) {
      if (arguments['offset'] != null) {
        throw const OrbException('请单独使用 offset 或按行读取。');
      }
      final first = arguments['start_line'] ?? 1;
      final count = arguments['line_count'] ?? 40;
      if (first is! int ||
          first < 1 ||
          count is! int ||
          count < 1 ||
          count > 200) {
        throw const OrbException(
          'start_line 必须是从 1 开始的整数，line_count 必须为 1 至 200 的整数。',
        );
      }
      firstLine = first;
      var start = 0;
      for (var line = 1; line < first; line++) {
        final newline = file.text.indexOf('\n', start);
        if (newline < 0) {
          throw OrbException('start_line 超出文件范围，最后一行是第 $line 行。');
        }
        start = newline + 1;
      }
      var end = start;
      for (var i = 0; i < count && end < file.text.length; i++) {
        final newline = file.text.indexOf('\n', end);
        end = newline < 0 ? file.text.length : newline + 1;
      }
      content = file.text.substring(start, end).runes;
      startOffset = file.text.substring(0, start).runes.length;
      if (end < file.text.length) nextLine = first + count;
    }
    final page = content.take(limit + 1).toList();
    final length = math.min(page.length, limit);
    return {
      'path': file.path,
      'sha256': file.hash,
      'text': String.fromCharCodes(page, 0, length),
      'start_line': ?firstLine,
      if (page.length > limit || nextLine != null)
        'next_offset': startOffset + length,
      if (page.length <= limit && nextLine != null) 'next_line': nextLine,
    };
  }

  static String _replaceUnique(String text, String old, String replacement) {
    if (old.isEmpty) throw const OrbException('old_text 不能为空。');
    final first = text.indexOf(old);
    if (first < 0) {
      throw const OrbException('文件中找不到完全一致的 old_text。请搜索或读取当前原文再编辑。');
    }
    final second = text.indexOf(old, first + 1);
    if (second >= 0) {
      final third = text.indexOf(old, second + 1);
      final positions = [first, second, if (third >= 0) third];
      final lines = positions
          .map(
            (position) =>
                1 + '\n'.allMatches(text.substring(0, position)).length,
          )
          .toSet()
          .join('、');
      throw OrbException(
        'old_text 在第 $lines 行等位置多次出现。请用 workspace_read 读取附近几行，把唯一的上下文一起替换。',
      );
    }
    return text.replaceRange(first, first + old.length, replacement);
  }

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
        final hashes = <String, String>{};
        final literal = RegExp(
          RegExp.escape(query),
          caseSensitive: false,
          unicode: true,
        );
        var skipped = 0;
        for (final row in await db.rawQuery(
          'SELECT path,body,hash FROM files WHERE instr(path,?)=1 AND (instr(lower(path),?)>0 OR instr(lower(body),?)>0) ORDER BY path',
          [prefix, query, query],
        )) {
          final path = row['path'] as String,
              lines = (row['body'] as String).split('\n');
          for (var i = -1; i < lines.length; i++) {
            final match = literal.firstMatch(i < 0 ? path : lines[i]);
            if (match == null) continue;
            if (skipped++ < offset) continue;
            if (hits.length == 30) {
              return {
                'matches': hits,
                'file_hashes': hashes,
                'next_offset': offset + 30,
              };
            }
            hashes[path] = row['hash'] as String;
            hits.add({
              'path': path,
              if (i >= 0) 'line': i + 1,
              if (i >= 0) 'text': _matchExcerpt(lines[i], match),
            });
          }
        }
        return {'matches': hits, 'file_hashes': hashes};
      case 'workspace_read':
        final file = await read(arg('path'));
        if (file == null) throw const OrbException('找不到工作文件。');
        return _readPage(file, a, offset);
      case 'workspace_write':
      case 'workspace_edit':
        final path = workspacePath(arg('path'));
        late final String body;
        if (call.name == 'workspace_edit') {
          final file = await read(path);
          if (file == null) throw OrbException('找不到工作文件 $path，请先查找正确的路径。');
          body = _replaceUnique(file.text, arg('old_text'), arg('new_text'));
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
