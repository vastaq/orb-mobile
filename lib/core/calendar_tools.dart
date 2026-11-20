import 'package:flutter/services.dart';

import 'models.dart';
import 'tool_types.dart';

class CalendarTools {
  CalendarTools(this.review, this.active);
  final ReviewAction review;
  final bool Function() active;
  static const channel = MethodChannel('studio.orb/personal-calendar');
  bool declined = false;

  static Future<bool> available() async {
    try {
      return await channel.invokeMethod<bool>('available') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static final definitions = [
    _tool(
      'list',
      'List actual calendars on this device and their writable status.',
      {},
      [],
    ),
    _tool(
      'events',
      'List up to 50 events overlapping a time interval in a listed calendar.',
      {
        'calendar_id': 'Calendar ID from calendar_list.',
        'from': 'ISO 8601 start.',
        'to': 'ISO 8601 end.',
      },
      ['calendar_id', 'from', 'to'],
    ),
    _tool(
      'create',
      'Create one timed calendar event after an interactive preview. List calendars first.',
      {
        'calendar_id': 'Writable calendar ID.',
        'title': 'Event title.',
        'start': 'ISO 8601 start.',
        'end': 'ISO 8601 end.',
        'location': 'Optional location.',
      },
      ['calendar_id', 'title', 'start', 'end'],
    ),
    _tool(
      'update',
      'Change specified fields of an editable event after an interactive preview.',
      {
        'calendar_id': 'Calendar ID.',
        'id': 'Event ID from calendar_events.',
        'title': 'New title.',
        'start': 'New ISO 8601 start.',
        'end': 'New ISO 8601 end.',
        'location': 'New location (empty to clear).',
      },
      ['calendar_id', 'id'],
    ),
    _tool(
      'delete',
      'Remove one editable event after an interactive preview.',
      {'calendar_id': 'Calendar ID.', 'id': 'Event ID from calendar_events.'},
      ['calendar_id', 'id'],
    ),
  ];

  static ChatTool _tool(
    String name,
    String description,
    Map<String, String> fields,
    List<String> requiredFields,
  ) => ChatTool(
    name: 'calendar_$name',
    description: description,
    parameters: {
      'type': 'object',
      'properties': {
        for (final f in fields.entries)
          f.key: {'type': 'string', 'description': f.value},
      },
      'required': requiredFields,
      'additionalProperties': false,
    },
  );

  void _checkActive() {
    if (!active()) throw const OrbException('本次操作已结束。');
  }

  Future<void> _approve(String title, String body, String label) async {
    _checkActive();
    if (declined || !await review(title, body, label)) {
      declined = true;
      throw const OrbException('用户已取消本次日历操作。');
    }
    _checkActive();
  }

  Future<void> _access() async {
    _checkActive();
    var state = await channel.invokeMethod<String>('permission');
    if (state == 'undetermined') {
      await _approve(
        '允许 Orb 访问日历？',
        'Orb 可以查看你指定的日历，并将查询到的日程交给当前对话的模型处理。每次更改日程前都会显示具体内容。',
        '继续授权',
      );
      state = await channel.invokeMethod<String>('requestAccess');
    }
    if (state != 'granted') {
      throw const OrbException('Orb 没有系统日历权限。可在系统设置中为 Orb 开启日历访问。');
    }
    _checkActive();
  }

  static String _string(Map data, String key, {bool empty = false}) {
    final s = data[key];
    if (s is! String || (!empty && s.trim().isEmpty) || s.length > 1024) {
      throw OrbException('日历参数 $key 无效。');
    }
    return s;
  }

  static int _date(Map data, String key) {
    final value = _string(data, key);
    final parts = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(?:[Zz]|[+-](\d{2}):?(\d{2}))?$',
    ).firstMatch(value);
    if (parts != null) {
      final year = int.parse(parts[1]!),
          month = int.parse(parts[2]!),
          day = int.parse(parts[3]!);
      final lastDay = DateTime.utc(year, month + 1, 0).day;
      final date = DateTime.tryParse(value);
      if (date != null &&
          month >= 1 &&
          month <= 12 &&
          day >= 1 &&
          day <= lastDay &&
          int.parse(parts[4]!) < 24 &&
          int.parse(parts[5]!) < 60 &&
          int.parse(parts[6] ?? '0') < 60 &&
          int.parse(parts[7] ?? '0') < 24 &&
          int.parse(parts[8] ?? '0') < 60) {
        return date.millisecondsSinceEpoch;
      }
    }
    throw OrbException('日历参数 $key 需要有效的日期和时间。');
  }

  static String _time(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    return '${local.toIso8601String().split('.').first}$sign${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
  }

  static Map<String, dynamic> _event(Map data) => {
    'id': data['id'],
    'calendar_id': data['calendarId'],
    'title': data['title'],
    'start': _time(data['startMs'] as int),
    'end': _time(data['endMs'] as int),
    'location': data['location'],
    'all_day': data['allDay'],
    'editable': data['editable'],
  };

  static String _preview(Map data) => [
    '标题　${data['title']}',
    '开始　${_time(data['startMs'] as int)}',
    '结束　${_time(data['endMs'] as int)}',
    '地点　${(data['location'] as String? ?? '').isEmpty ? '未填写' : data['location']}',
  ].join('\n');

  Future<Map<String, dynamic>> run(ChatToolCall call) async {
    try {
      return await _run(call);
    } on PlatformException catch (e) {
      throw OrbException(e.message ?? '系统日历未能完成操作。');
    }
  }

  Future<Map<String, dynamic>> _run(ChatToolCall call) async {
    await _access();
    final calendars =
        await channel.invokeListMethod<dynamic>('calendars') ?? [];
    if (call.name == 'calendar_list') return {'calendars': calendars};
    final args = call.arguments;
    final calendarId = _string(args, 'calendar_id');
    final calendar = calendars
        .whereType<Map>()
        .where((c) => c['id'] == calendarId)
        .firstOrNull;
    if (calendar == null) throw const OrbException('找不到这个日历，请重新选择。');
    final native = <String, dynamic>{'calendarId': calendarId};
    if (call.name == 'calendar_events') {
      final from = _date(args, 'from'), to = _date(args, 'to');
      if (to <= from) throw const OrbException('查询结束时间必须晚于开始时间。');
      if (to - from > const Duration(days: 365 * 4).inMilliseconds) {
        throw const OrbException('每次最多可查询 1460 天的日程。');
      }
      final rows =
          await channel.invokeListMethod<dynamic>('events', {
            ...native,
            'fromMs': from,
            'toMs': to,
            'limit': 50,
          }) ??
          [];
      return {
        'events': rows.whereType<Map>().map(_event).toList(),
        'limit': 50,
      };
    }
    if (calendar['writable'] != true) throw const OrbException('此日历只允许查看。');
    final method = switch (call.name) {
      'calendar_create' => 'create',
      'calendar_update' => 'update',
      'calendar_delete' => 'delete',
      _ => throw const OrbException('未知日历操作。'),
    };
    Map<dynamic, dynamic>? before;
    if (method != 'create') {
      native['id'] = _string(args, 'id');
      before = await channel.invokeMapMethod<dynamic, dynamic>('get', native);
      if (before == null || before['editable'] != true) {
        throw const OrbException('此日程已不存在或无法修改。');
      }
    }
    if (method != 'delete') {
      if (method == 'create' || args.containsKey('title')) {
        native['title'] = _string(args, 'title');
      }
      if (method == 'create' || args.containsKey('start')) {
        native['startMs'] = _date(args, 'start');
      }
      if (method == 'create' || args.containsKey('end')) {
        native['endMs'] = _date(args, 'end');
      }
      if (args.containsKey('location')) {
        native['location'] = _string(args, 'location', empty: true);
      }
      if (method == 'update' && native.length == 2) {
        throw const OrbException('请指定要修改的日程字段。');
      }
    }
    final proposed = {...?before, ...native};
    if ((proposed['endMs'] as int) <= (proposed['startMs'] as int)) {
      throw const OrbException('日程结束时间必须晚于开始时间。');
    }
    final label = {
      'create': '创建日程',
      'update': '修改日程',
      'delete': '删除日程',
    }[method]!;
    final details = [
      '日历　${calendar['title']}',
      if (method == 'update') '修改前\n${_preview(before!)}',
      if (method == 'update') '修改后',
      _preview(proposed),
    ].join('\n\n');
    await _approve(label, details, label);
    if (before != null) {
      final current = await channel.invokeMapMethod<dynamic, dynamic>('get', {
        'calendarId': calendarId,
        'id': native['id'],
      });
      if (current == null || before.keys.any((k) => current[k] != before![k])) {
        throw const OrbException('日程已发生变化，请重新查看并确认。');
      }
    }
    _checkActive();
    final saved = await channel.invokeMapMethod<dynamic, dynamic>(
      method,
      native,
    );
    if (saved == null) throw const OrbException('系统日历未返回操作结果。');
    return method == 'delete'
        ? {
            'id': saved['id'],
            'calendar_id': calendarId,
            'deleted': saved['deleted'],
          }
        : _event(saved);
  }
}
