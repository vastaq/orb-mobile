import 'dart:convert';

import '../core/models.dart';
import '../core/tool_types.dart';
import 'task_service.dart';
import 'task_store.dart';

/// Each user turn uses a fresh instance. Retry/regenerate reuse the turn's key.
class ScheduleTools {
  ScheduleTools({
    required this.turnKey,
    this._open = TaskService.open,
    this._now = DateTime.now,
  });

  final String turnKey;
  final Future<TaskService> Function() _open;
  final DateTime Function() _now;
  Future<TaskService>? _service;
  int _createIndex = 0;
  bool _askedForNotifications = false;
  final _creationSources = <String, String>{};

  static const _id = {
    'type': 'integer',
    'minimum': 1,
    'description':
        'Use the exact task id. List tasks first if the target is ambiguous.',
  };
  static const _title = {'type': 'string', 'maxLength': 120};
  static const _body = {
    'type': 'string',
    'maxLength': 12000,
    'description':
        'Reminder message, or the instruction to run at the scheduled time.',
  };
  static const _due = {
    'type': 'string',
    'description': 'Next occurrence in device local time, YYYY-MM-DDTHH:mm or YYYY-MM-DDTHH:mm:ss. For weekly recurrence this date selects the weekday.',
  };
  static const _kind = {
    'type': 'string',
    'enum': ['reminder', 'prompt'],
  };
  static const _frequency = {
    'type': 'string',
    'enum': ['once', 'daily', 'weekly'],
  };
  static const _fields = {
    'title': _title,
    'body': _body,
    'kind': _kind,
    'frequency': _frequency,
    'due': _due,
  };

  static const definitions = <ChatTool>[
    ChatTool(
      name: 'schedule_create',
      description: 'Create a local reminder or scheduled model prompt at the user’s request. Resolve relative dates in the device time zone. Ask for missing timing or unsupported recurrence. A reminder requires system notifications. If permission is unavailable, explain the result and wait for the user. Return the saved id and next occurrence on success.',
      parameters: {
        'type': 'object',
        'properties': _fields,
        'required': ['title', 'body', 'due'],
        'additionalProperties': false,
      },
    ),
    ChatTool(
      name: 'schedule_list',
      description: 'List local tasks and the current local clock. Match the requested task by id/title; clarify if there is more than one match.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Optional title filter.'},
          'offset': {'type': 'integer', 'minimum': 0},
        },
        'additionalProperties': false,
      },
    ),
    ChatTool(
      name: 'schedule_view',
      description:
          'Read a local task, its reminder/prompt and recent execution status.',
      parameters: {
        'type': 'object',
        'properties': {'id': _id},
        'required': ['id'],
        'additionalProperties': false,
      },
    ),
    ChatTool(
      name: 'schedule_edit',
      description: 'Update, pause, resume or delete a specific local task. Use the id and revision from list/view or a previous result. Only delete when the user requested deletion.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': _id,
          'revision': {'type': 'integer', 'minimum': 1},
          'action': {
            'type': 'string',
            'enum': ['update', 'pause', 'resume', 'delete'],
          },
          ..._fields,
        },
        'required': ['id', 'revision', 'action'],
        'additionalProperties': false,
      },
    ),
  ];

  Future<Map<String, dynamic>> run(ChatToolCall call) =>
      execute(call.name, call.arguments);

  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    try {
      final spec = definitions.where((tool) => tool.name == name).firstOrNull;
      if (spec == null) throw const FormatException('未知任务工具。');
      final properties = spec.parameters['properties'] as Map;
      if (args.keys.any((key) => !properties.containsKey(key))) {
        throw const FormatException('包含不支持的字段或重复规则。');
      }
      final service = await (_service ??= _open());
      final now = _now().toLocal();
      switch (name) {
        case 'schedule_list':
          final query = (_text(args, 'query', 120) ?? '').toLowerCase();
          final offset = args.containsKey('offset')
              ? _int(args, 'offset', minimum: 0)
              : 0;
          final tasks = (await service.store.all())
              .where((t) => t.title.toLowerCase().contains(query))
              .toList();
          final page = tasks.skip(offset).take(30);
          return {
            'ok': true,
            'local_now': now.toIso8601String(),
            'utc_offset_minutes': now.timeZoneOffset.inMinutes,
            'tasks': [for (final t in page) _record(t)],
            'total': tasks.length,
            if (offset + 30 < tasks.length) 'next_offset': offset + 30,
          };
        case 'schedule_create':
          final draft = _draft(args, now);
          final unavailable = await _reminderPermission(service, draft);
          if (unavailable != null) return unavailable;
          final signature = jsonEncode(draft.values(1));
          final source =
              _creationSources[signature] ?? '$turnKey/create/$_createIndex';
          final saved = await service.save(draft, createSource: source);
          if (!_creationSources.containsKey(signature)) {
            _creationSources[signature] = source;
            _createIndex++;
          }
          if (!saved.enabled) {
            return {
              'ok': false,
              'error': '此轮的任务已存在，但当前未启用。可查看执行记录或按用户要求恢复。',
              'task': _record(saved, detail: true),
            };
          }
          return await _saved(service, saved);
        case 'schedule_view':
        case 'schedule_edit':
          final task = await service.store.find(_int(args, 'id'));
          if (task == null) throw const FormatException('找不到这个任务，请重新查询任务列表。');
          if (name == 'schedule_view') {
            final runs = await service.store.runs(task.id);
            return {
              'ok': true,
              'task': _record(task, detail: true),
              'recent_runs': [
                for (final run in runs.take(5))
                  {
                    'status': run.status,
                    'at': run.at.toIso8601String(),
                    if (run.threadId != null) 'thread_id': run.threadId,
                  },
              ],
            };
          }
          return await _edit(service, task, args, now);
        default:
          throw const FormatException('未知任务工具。');
      }
    } on FormatException catch (e) {
      return {'ok': false, 'error': e.message};
    } on StateError catch (e) {
      return {'ok': false, 'error': e.message};
    } on OrbException catch (e) {
      return {'ok': false, 'error': e.message};
    }
  }

  Future<Map<String, dynamic>> _edit(
    TaskService service,
    OrbTask task,
    Map<String, dynamic> args,
    DateTime now,
  ) async {
    if (_int(args, 'revision') != task.revision) {
      throw const FormatException('任务已改变，请先重新查看。');
    }
    final action = _text(args, 'action', 10);
    if (!const {'update', 'pause', 'resume', 'delete'}.contains(action)) {
      throw const FormatException('未知的任务操作。');
    }
    final changes = args.keys.where(_fields.containsKey).toList();
    if (action == 'update' && changes.isEmpty) {
      throw const FormatException('修改任务时请给出新的内容或时间。');
    }
    if (action != 'update' &&
        changes.any((key) => !(action == 'resume' && key == 'due'))) {
      throw const FormatException('此操作不接受额外的修改。');
    }
    if (action == 'delete') {
      await service.remove(task);
      return {'ok': true, 'deleted_id': task.id};
    }
    final enabled = switch (action) {
      'pause' => false,
      'resume' => true,
      _ => task.enabled,
    };
    if (action != 'update' && enabled == task.enabled && changes.isEmpty) {
      return _saved(service, task);
    }
    final draft = _draft(args, now, previous: task, enabled: enabled);
    if (action == 'resume' || draft.kind != task.kind) {
      final unavailable = await _reminderPermission(service, draft);
      if (unavailable != null) return unavailable;
    }
    final result = await service.save(draft);
    return _saved(service, result);
  }

  OrbTask _draft(
    Map<String, dynamic> args,
    DateTime now, {
    OrbTask? previous,
    bool enabled = true,
  }) {
    final title = _text(args, 'title', 120) ?? previous?.title;
    final body = _text(args, 'body', 12000) ?? previous?.body;
    if (title == null || body == null) {
      throw const FormatException('请填写任务名称和内容。');
    }
    final kind = _value(
      args,
      'kind',
      TaskKind.values,
      previous?.kind ?? TaskKind.reminder,
    );
    final frequency = _value(
      args,
      'frequency',
      TaskFrequency.values,
      previous?.frequency ?? TaskFrequency.once,
    );
    final rawDue = _text(args, 'due', 24);
    var due = rawDue == null ? previous?.due : _localDate(rawDue);
    if (due == null) throw const FormatException('请提供设备所在地的下一次执行时间。');
    if (rawDue == null && enabled && !due.isAfter(now) && previous != null) {
      due =
          OrbTask(
            title: title,
            body: body,
            kind: kind,
            frequency: frequency,
            due: due,
          ).nextAfter(now) ??
          due;
    }
    if (enabled && !due.isAfter(now)) {
      throw const FormatException('下一次执行时间必须在将来。');
    }
    return OrbTask(
      id: previous?.id ?? 0,
      revision: previous?.revision ?? 0,
      title: title,
      body: body,
      kind: kind,
      frequency: frequency,
      due: due,
      enabled: enabled,
    );
  }

  Future<Map<String, dynamic>?> _reminderPermission(
    TaskService service,
    OrbTask task,
  ) async {
    if (!task.enabled || task.kind != TaskKind.reminder) return null;
    final granted = await service.reminderNotificationPermission(
      mayAsk: !_askedForNotifications,
    );
    _askedForNotifications = true;
    if (granted == true) return null;
    return {
      'ok': false,
      'notifications_enabled': ?granted,
      'error': granted == false
          ? 'Orb 通知尚未开启，本次提醒没有安排。请在手机设置中允许 Orb 通知，然后再试。'
          : '无法确认系统通知权限，本次提醒没有安排。请打开 Orb，检查通知设置后再试。',
    };
  }

  static Future<Map<String, dynamic>> _saved(
    TaskService service,
    OrbTask task,
  ) async {
    bool? notices;
    if (task.enabled) {
      try {
        notices = await service.notificationsEnabled();
      } catch (_) {
        // The scheduler has already saved the task; inability to inspect notification settings doesn't undo it.
      }
    }
    return {
      'ok': true,
      'task': _record(task, detail: true),
      'notifications_enabled': ?notices,
      if (notices == false) 'notice': '系统通知未开启，请在手机设置打开 Orb 通知。',
    };
  }

  static Map<String, dynamic> _record(OrbTask t, {bool detail = false}) => {
    'id': t.id,
    'revision': t.revision,
    'title': t.title,
    if (detail) 'body': t.body,
    'kind': t.kind.name,
    'frequency': t.frequency.name,
    'enabled': t.enabled,
    'due': t.due.toLocal().toIso8601String(),
    'next_occurrence': t.enabled ? t.due.toLocal().toIso8601String() : null,
  };

  static T _value<T extends Enum>(
    Map<String, dynamic> args,
    String key,
    List<T> values,
    T fallback,
  ) {
    if (!args.containsKey(key)) return fallback;
    return values.where((v) => v.name == args[key]).firstOrNull ??
        (throw FormatException('不支持的 $key。'));
  }

  static int _int(Map<String, dynamic> args, String key, {int minimum = 1}) {
    final n = args[key];
    if (n is! int || n < minimum) {
      throw FormatException('$key 必须是大于或等于 $minimum 的整数。');
    }
    return n;
  }

  static String? _text(Map<String, dynamic> args, String key, int max) {
    if (!args.containsKey(key)) return null;
    final s = args[key];
    if (s is! String || s.trim().isEmpty || s.length > max) {
      throw FormatException('$key 必须为 1–$max 个字符。');
    }
    return s.trim();
  }

  static DateTime _localDate(String raw) {
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$',
    ).firstMatch(raw);
    if (match == null) throw const FormatException('请使用本地时间 YYYY-MM-DDTHH:mm。');
    final p = [for (var i = 1; i <= 6; i++) int.parse(match[i] ?? '0')];
    final d = DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
    if (d.year != p[0] ||
        d.month != p[1] ||
        d.day != p[2] ||
        d.hour != p[3] ||
        d.minute != p[4] ||
        d.second != p[5]) {
      throw const FormatException('本地日期或时间无效。');
    }
    return d;
  }
}
