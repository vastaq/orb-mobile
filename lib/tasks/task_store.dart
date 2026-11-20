import 'dart:io';

import 'package:sqflite/sqflite.dart';

enum TaskKind { reminder, prompt }

enum TaskFrequency { once, daily, weekly }

class OrbTask {
  const OrbTask({
    this.id = 0,
    this.revision = 0,
    required this.title,
    required this.body,
    required this.kind,
    required this.frequency,
    required this.due,
    this.enabled = true,
  });
  final int id, revision;
  final String title, body;
  final TaskKind kind;
  final TaskFrequency frequency;
  final DateTime due;
  final bool enabled;

  factory OrbTask.from(Map<String, Object?> row) => OrbTask(
    id: row['id'] as int,
    revision: row['revision'] as int,
    title: row['title'] as String,
    body: row['body'] as String,
    kind: TaskKind.values.byName(row['kind'] as String),
    frequency: TaskFrequency.values.byName(row['frequency'] as String),
    due: DateTime.fromMillisecondsSinceEpoch(row['due'] as int),
    enabled: row['enabled'] == 1,
  );

  String get workName => 'orb-task-$id-$revision-${due.millisecondsSinceEpoch}';

  DateTime? nextAfter(DateTime now) {
    if (frequency == TaskFrequency.once) return null;
    final dayOffset = frequency == TaskFrequency.weekly
        ? (due.weekday - now.weekday + 7) % 7
        : 0;
    DateTime onDay(int offset) =>
        DateTime(now.year, now.month, now.day + offset, due.hour, due.minute);
    final next = onDay(dayOffset);
    return next.isAfter(now)
        ? next
        : onDay(dayOffset + (frequency == TaskFrequency.daily ? 1 : 7));
  }

  Map<String, Object?> values(int revision) => {
    'title': title,
    'body': body,
    'kind': kind.name,
    'frequency': frequency.name,
    'due': due.millisecondsSinceEpoch,
    'enabled': enabled ? 1 : 0,
    'revision': revision,
  };
}

class TaskRun {
  const TaskRun(
    this.id,
    this.taskId,
    this.at,
    this.status,
    this.result,
    this.threadId,
  );
  final int id, taskId;
  final DateTime at;
  final String status, result;
  final String? threadId;
  factory TaskRun.from(Map<String, Object?> row) => TaskRun(
    row['id'] as int,
    row['task'] as int,
    DateTime.fromMillisecondsSinceEpoch(row['started'] as int),
    row['status'] as String,
    row['result'] as String,
    row['thread_id'] as String?,
  );
}

class TaskClaim {
  const TaskClaim(this.task, this.runId, this.source);
  final OrbTask task;
  final int runId;
  final String source;
}

class TaskStore {
  TaskStore(this.db);
  final Database db;
  static Future<TaskStore> open() async {
    final dir = Directory('${await getDatabasesPath()}/orb-local');
    await dir.create(recursive: true);
    final db = await openDatabase(
      '${dir.path}/tasks.db',
      version: 2,
      onUpgrade: (db, from, to) async {
        if (from < 2) await _createSources(db);
      },
      onConfigure: (db) => db.execute('PRAGMA foreign_keys=ON'),
      onCreate: createSchema,
    );
    return TaskStore(db);
  }

  static Future<void> createSchema(Database db, int _) async {
    await db.execute(
      'CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL, kind TEXT NOT NULL, frequency TEXT NOT NULL, due INTEGER NOT NULL, enabled INTEGER NOT NULL, revision INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE runs(id INTEGER PRIMARY KEY AUTOINCREMENT, occurrence TEXT UNIQUE NOT NULL, task INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, started INTEGER NOT NULL, status TEXT NOT NULL, result TEXT NOT NULL DEFAULT \'\', thread_id TEXT)',
    );
    await db.execute('CREATE INDEX runs_task ON runs(task,started DESC)');
    await _createSources(db);
  }

  static Future<void> _createSources(Database db) => db.execute(
    'CREATE TABLE chat_task_sources(source TEXT PRIMARY KEY, task INTEGER NOT NULL)',
  );

  // Preserve the receipt after deletion so retrying an old chat cannot recreate it.
  static Future<OrbTask?> _fromSource(
    DatabaseExecutor executor,
    String key,
  ) async {
    final rows = await executor.rawQuery(
      'SELECT t.* FROM chat_task_sources s LEFT JOIN tasks t ON t.id=s.task WHERE s.source=?',
      [key],
    );
    if (rows.isEmpty) return null;
    if (rows.single['id'] == null) throw StateError('此轮创建的任务已删除。');
    return OrbTask.from(rows.single);
  }

  Future<OrbTask?> createdFrom(String key) => _fromSource(db, key);

  Future<OrbTask> _createOnce(OrbTask task, String key) =>
      db.transaction((tx) async {
        final previous = await _fromSource(tx, key);
        if (previous != null) return previous;
        final id = await tx.insert('tasks', task.values(1));
        await tx.insert('chat_task_sources', {'source': key, 'task': id});
        return OrbTask.from({'id': id, ...task.values(1)});
      });

  Future<List<OrbTask>> all() async => (await db.query(
    'tasks',
    orderBy: 'enabled DESC, due, id',
  )).map(OrbTask.from).toList();
  Future<OrbTask?> find(int id) async => (await db.query(
    'tasks',
    where: 'id=?',
    whereArgs: [id],
  )).map(OrbTask.from).firstOrNull;
  Future<List<TaskRun>> runs(int id) async {
    await db.update(
      'runs',
      {'status': 'failed', 'result': '系统中断了执行。可使用「立即运行」重试。'},
      where: 'task=? AND status=? AND started<?',
      whereArgs: [
        id,
        'running',
        DateTime.now()
            .subtract(const Duration(minutes: 12))
            .millisecondsSinceEpoch,
      ],
    );
    return (await db.query(
      'runs',
      where: 'task=?',
      whereArgs: [id],
      orderBy: 'id DESC',
      limit: 50,
    )).map(TaskRun.from).toList();
  }

  Future<OrbTask> save(OrbTask task, {String? createSource}) async {
    if (createSource != null && task.id == 0) {
      return _createOnce(task, createSource);
    }
    int id = task.id;
    if (id == 0) {
      id = await db.insert('tasks', task.values(1));
    } else {
      final count = await db.update(
        'tasks',
        task.values(task.revision + 1),
        where: 'id=? AND revision=?',
        whereArgs: [id, task.revision],
      );
      if (count != 1) throw StateError('任务已改变，请重新打开。');
    }
    return (await find(id))!;
  }

  Future<void> delete(int id, {int? revision}) async {
    final count = await db.delete(
      'tasks',
      where: revision == null ? 'id=?' : 'id=? AND revision=?',
      whereArgs: [id, ?revision],
    );
    if (revision != null && count != 1) throw StateError('任务已改变，请重新查看。');
  }

  /// The OS worker, app resume and notification tap can reach the same due
  /// occurrence. Claim and advance it atomically before any billable request.
  Future<TaskClaim?> claim(
    int id, {
    required int revision,
    required int due,
    required bool manual,
    required DateTime now,
  }) => db.transaction((tx) async {
    final row = (await tx.query(
      'tasks',
      where: 'id=?',
      whereArgs: [id],
    )).firstOrNull;
    if (row == null) return null;
    final task = OrbTask.from(row);
    if (task.revision != revision) return null;
    final automatic = !manual || task.enabled && !task.due.isAfter(now);
    if (automatic &&
        (!task.enabled ||
            task.due.isAfter(now) ||
            task.due.millisecondsSinceEpoch != due)) {
      return null;
    }
    final key = automatic
        ? '$id:$revision:$due'
        : '$id:manual:${now.microsecondsSinceEpoch}';
    if ((await tx.query(
      'runs',
      columns: ['id'],
      where: 'occurrence=?',
      whereArgs: [key],
      limit: 1,
    )).isNotEmpty) {
      return null;
    }
    if (!automatic &&
        (await tx.query(
          'runs',
          columns: ['id'],
          where: 'task=? AND status=?',
          whereArgs: [id, 'running'],
          limit: 1,
        )).isNotEmpty) {
      return null;
    }
    final run = await tx.insert('runs', {
      'task': id,
      'occurrence': key,
      'started': now.millisecondsSinceEpoch,
      'status': 'running',
    });
    if (automatic) {
      final next = task.nextAfter(now);
      await tx.update(
        'tasks',
        next == null ? {'enabled': 0} : {'due': next.millisecondsSinceEpoch},
        where: 'id=?',
        whereArgs: [id],
      );
    }
    return TaskClaim(task, run, 'orb-task:$key');
  });

  Future<void> finish(
    int runId, {
    required String status,
    required String result,
    String? threadId,
  }) async {
    await db.update(
      'runs',
      {'status': status, 'result': result, 'thread_id': threadId},
      where: 'id=?',
      whereArgs: [runId],
    );
  }
}
