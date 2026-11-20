import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:crypto/crypto.dart';

import 'memory_harness.dart';

import 'models.dart';

class OrbStore {
  late Database _db;
  late Directory _local;
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _credential = 'orb.connection.v1';

  Future<void> open() async {
    final directory = Directory('${await getDatabasesPath()}/orb-local');
    await directory.create(recursive: true);
    _local = directory;
    _db = await openDatabase(
      '${directory.path}/orb.db',
      version: 2,
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _addRichFields(db);
      },
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE threads(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, touched INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, thread INTEGER NOT NULL REFERENCES threads(id) ON DELETE CASCADE, role TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL)',
        );
        await db.execute('CREATE INDEX messages_thread ON messages(thread,id)');
        await db.execute(
          'CREATE TABLE memories(id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, touched INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE settings(name TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await _addRichFields(db);
      },
    );
  }

  static Future<void> _addRichFields(DatabaseExecutor db) async {
    await db.execute(
      "ALTER TABLE messages ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'",
    );
    await db.execute(
      "ALTER TABLE messages ADD COLUMN metadata TEXT NOT NULL DEFAULT '{}'",
    );
    await db.execute('ALTER TABLE messages ADD COLUMN receipt TEXT');
    await db.execute(
      'ALTER TABLE memories ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute('ALTER TABLE threads ADD COLUMN source TEXT');
    await db.execute('CREATE UNIQUE INDEX threads_source ON threads(source)');
  }

  Future<Map<String, dynamic>> _credentials() async {
    final raw = await _secure.read(key: _credential);
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  ModelConfig _config(Map value) => ModelConfig(
    baseUrl: value['url'] as String,
    model: value['model'] as String,
    apiKey: value['key'] as String,
  );
  Future<ModelConfig> loadConfig() async {
    final value = await _credentials();
    if (value.isEmpty) return const ModelConfig();
    return _config(value['current'] as Map? ?? value);
  }

  Future<Map<String, ModelConfig>> loadProfiles() async {
    final value = await _credentials();
    if (value.isEmpty) return {};
    if (value['profiles'] is Map) {
      return {
        for (final e in (value['profiles'] as Map).entries)
          e.key as String: _config(e.value as Map),
      };
    }
    final old = _config(value);
    return {old.service.name: old};
  }

  Future<void> saveConfig(ModelConfig config) async {
    final profiles = await loadProfiles();
    profiles[config.service.name] = config;
    Map<String, String> encode(ModelConfig c) => {
      'url': c.baseUrl,
      'model': c.model,
      'key': c.apiKey,
    };
    await _secure.write(
      key: _credential,
      value: jsonEncode({
        'current': encode(config),
        'profiles': profiles.map((k, v) => MapEntry(k, encode(v))),
      }),
    );
  }

  Future<String?> preference(String name) async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [name],
    );
    return rows.firstOrNull?['value'] as String?;
  }

  Future<void> setPreference(String name, String value) async => _db.insert(
    'settings',
    {'name': name, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<List<OrbAttachment>> persistAttachments(
    List<OrbAttachment> inputs,
  ) async {
    if (inputs.isEmpty) return [];
    final dir = Directory('${_local.path}/media');
    await dir.create(recursive: true);
    final result = <OrbAttachment>[];
    for (final a in inputs) {
      if (a.dataUrl.isEmpty &&
          (a.localPath == null || File(a.localPath!).parent.path == dir.path)) {
        result.add(a);
        continue;
      }
      final source = a.localPath == null ? null : File(a.localPath!);
      final bytes = source == null ? await a.bytes() : null;
      final digest = source == null
          ? sha256.convert(bytes!)
          : await sha256.bind(source.openRead()).first;
      final file = File('${dir.path}/$digest');
      if (!await file.exists()) {
        final staging = File(
          '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        final tmp = source == null
            ? await staging.writeAsBytes(bytes!, flush: true)
            : await source.copy(staging.path);
        await tmp.rename(file.path);
      }
      result.add(a.onDisk(file.path));
    }
    return result;
  }

  String _encodeAttachments(List<OrbAttachment> files) => jsonEncode(
    files.map((a) {
      final j = a.toJson();
      // Containers can move on iOS after an app upgrade.
      if (a.localPath != null) j['path'] = a.localPath!.split('/').last;
      return j;
    }).toList(),
  );
  List<OrbAttachment> _decodeAttachments(String data) => [
    for (final a in (jsonDecode(data) as List).cast<Map<String, dynamic>>())
      OrbAttachment.fromJson(
        a,
        filePath: a['path'] == null
            ? null
            : '${_local.path}/media/${a["path"]}',
      ),
  ];

  Future<List<OrbThread>> threads() async => [
    for (final row in await _db.query(
      'threads',
      orderBy: 'touched DESC, id DESC',
    ))
      OrbThread(
        row['id'].toString(),
        row['title'] as String,
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(row['touched'] as int),
      ),
  ];

  Future<List<OrbMessage>> messages(String threadId) async => [
    for (final row in await _db.query(
      'messages',
      where: "thread = ? AND (text != '' OR attachments != '[]')",
      whereArgs: [threadId],
      orderBy: 'id',
    ))
      OrbMessage(
        row['role'] as String,
        row['text'] as String,
        status: row['status'] as String,
        receipt: row['receipt'] as String?,
        attachments: _decodeAttachments(row['attachments'] as String),
        metadata: jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
      ),
  ];

  Future<List<OrbMemory>> memories() async => [
    for (final row in await _db.query(
      'memories',
      orderBy: 'touched DESC, id DESC',
    ))
      OrbMemory(
        row['id'].toString(),
        row['text'] as String,
        isAutomatic: row['automatic'] == 1,
      ),
  ];

  Future<void> saveMemory(String text, String? id) async {
    final values = {
      'automatic': 0,
      'text': text,
      'touched': DateTime.now().microsecondsSinceEpoch,
    };
    if (id == null) {
      await _db.insert('memories', values);
    } else {
      await _db.update('memories', values, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> removeMemory(String id) async {
    await _db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  Future<String?> applyMemoryPlan(
    int answerId,
    List<MemoryChange> changes,
    List<OrbMemory> snapshot,
  ) => _db.transaction((tx) async {
    final existing = await tx.query(
      'messages',
      columns: ['receipt'],
      where: 'id = ?',
      whereArgs: [answerId],
    );
    if (existing.isEmpty || existing.first['receipt'] != null) return null;
    final counts = <String>[];
    for (final change in changes) {
      if (change.kind == MemoryChangeKind.add) {
        final duplicate = await tx.query(
          'memories',
          columns: ['id'],
          where: 'text = ?',
          whereArgs: [change.text],
          limit: 1,
        );
        if (duplicate.isNotEmpty) continue;
        await tx.insert('memories', {
          'text': change.text,
          'touched': DateTime.now().microsecondsSinceEpoch,
          'automatic': 1,
        });
      } else {
        final old = snapshot.where((m) => m.id == change.id).firstOrNull;
        if (old == null) continue;
        final affected = change.kind == MemoryChangeKind.forget
            ? await tx.delete(
                'memories',
                where: 'id = ? AND text = ?',
                whereArgs: [old.id, old.text],
              )
            : await tx.update(
                'memories',
                {
                  'text': change.text,
                  'automatic': 1,
                  'touched': DateTime.now().microsecondsSinceEpoch,
                },
                where: 'id = ? AND text = ?',
                whereArgs: [old.id, old.text],
              );
        if (affected == 0) continue;
      }
      counts.add(
        change.kind == MemoryChangeKind.forget
            ? '已忘记一条记忆'
            : change.kind == MemoryChangeKind.update
            ? '已更新本地记忆'
            : '已记入本地记忆',
      );
    }
    final receipt = counts.isEmpty ? '' : counts.toSet().join(' · ');
    await tx.update(
      'messages',
      {'receipt': receipt},
      where: 'id = ?',
      whereArgs: [answerId],
    );
    return receipt.isEmpty ? null : receipt;
  });

  Future<void> renameThread(String id, String title) async =>
      _db.update('threads', {'title': title}, where: 'id = ?', whereArgs: [id]);

  Future<String?> threadIdForSource(String sourceId) async {
    final rows = await _db.query(
      'threads',
      columns: ['id'],
      where: 'source = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    return rows.firstOrNull?['id']?.toString();
  }

  Future<bool> importThread(
    String sourceId,
    String title,
    List<OrbMessage> messages,
  ) async {
    if ((await _db.query(
      'threads',
      columns: ['id'],
      where: 'source = ?',
      whereArgs: [sourceId],
      limit: 1,
    )).isNotEmpty) {
      return false;
    }
    final rows = <Map<String, Object?>>[];
    for (final m in messages) {
      rows.add({
        'role': m.role,
        'text': m.text,
        'status': m.status,
        'metadata': jsonEncode(m.metadata),
        'attachments': _encodeAttachments(
          await persistAttachments(m.attachments),
        ),
      });
    }
    return _db.transaction((tx) async {
      final id = await tx.insert('threads', {
        'source': sourceId,
        'title': title,
        'touched': DateTime.now().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (id == 0) return false;
      final batch = tx.batch();
      for (final row in rows) {
        batch.insert('messages', {'thread': id, ...row});
      }
      await batch.commit(noResult: true);
      return true;
    });
  }

  Future<String?> selected() async {
    final rows = await _db.query(
      'settings',
      where: 'name = ?',
      whereArgs: ['thread'],
    );
    final value = rows.firstOrNull?['value'] as String?;
    return value == '' ? null : value;
  }

  Future<void> select(String? id) => _setSelected(_db, id);
  Future<void> _setSelected(DatabaseExecutor db, String? id) async {
    await db.insert('settings', {
      'name': 'thread',
      'value': id ?? '',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeAttachment(
    String thread,
    String name,
    String? path,
  ) async {
    final removed = <String>{};
    await _db.transaction((tx) async {
      final rows = await tx.query(
        'messages',
        columns: ['id', 'attachments'],
        where: "thread=? AND attachments!='[]'",
        whereArgs: [thread],
      );
      for (final row in rows) {
        final old = _decodeAttachments(row['attachments'] as String);
        final kept = old
            .where((a) => a.name != name || a.localPath != path)
            .toList();
        if (kept.length == old.length) continue;
        if (path != null) removed.add(path);
        await tx.update(
          'messages',
          {'attachments': _encodeAttachments(kept)},
          where: 'id=?',
          whereArgs: [row['id']],
        );
      }
    });
    await _removeUnused(removed);
  }

  Future<void> _removeUnused(Set<String> removed) async {
    if (removed.isEmpty) return;
    for (final row in await _db.query(
      'messages',
      columns: ['attachments'],
      where: "attachments!='[]'",
    )) {
      for (final a in _decodeAttachments(row['attachments'] as String)) {
        removed.remove(a.localPath);
      }
    }
    for (final path in removed) {
      final file = File(path);
      if (file.parent.path == '${_local.path}/media' && await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> removeChat(String id) async {
    final files = (await messages(id))
        .expand((m) => m.attachments)
        .map((a) => a.localPath)
        .whereType<String>()
        .toSet();
    await _db.transaction((tx) async {
      await tx.delete('threads', where: 'id = ?', whereArgs: [id]);
      await tx.update(
        'settings',
        {'value': ''},
        where: 'name = ? AND value = ?',
        whereArgs: ['thread', id],
      );
    });
    await _removeUnused(files);
  }

  Future<({String thread, int answer})> beginTurn(
    String? current,
    String text,
    bool retry,
  ) => _db.transaction((tx) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    var threadId = current;
    if (threadId == null) {
      final title = String.fromCharCodes(
        text.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(30),
      );
      threadId = (await tx.insert('threads', {
        'title': title,
        'touched': now,
      })).toString();
    } else {
      await tx.update(
        'threads',
        {'touched': now},
        where: 'id = ?',
        whereArgs: [threadId],
      );
    }
    int? existingAnswer;
    if (retry) {
      final last = await tx.query(
        'messages',
        columns: ['id', 'role'],
        where: 'thread = ?',
        whereArgs: [threadId],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (last.isNotEmpty && last.first['role'] == 'assistant') {
        existingAnswer = last.first['id'] as int;
      }
    } else {
      await tx.insert('messages', {
        'thread': threadId,
        'role': 'user',
        'text': text,
        'status': 'complete',
      });
    }
    final answer =
        existingAnswer ??
        await tx.insert('messages', {
          'thread': threadId,
          'role': 'assistant',
          'text': '',
          'status': 'partial',
        });
    await _setSelected(tx, threadId);
    return (thread: threadId, answer: answer);
  });

  Future<void> attachToUser(int answer, List<OrbAttachment> files) async {
    if (files.isEmpty) return;
    await _db.rawUpdate(
      "UPDATE messages SET attachments = ? WHERE id = (SELECT MAX(u.id) FROM messages u JOIN messages a ON a.thread=u.thread WHERE a.id=? AND u.id<a.id AND u.role='user')",
      [_encodeAttachments(files), answer],
    );
  }

  Future<void> saveMetadata(int answer, Map<String, dynamic> metadata) async =>
      _db.update(
        'messages',
        {'metadata': jsonEncode(metadata)},
        where: 'id = ?',
        whereArgs: [answer],
      );

  Future<void> writeAnswer(int id, String text, String status) async {
    await _db.update(
      'messages',
      {'text': text, 'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
