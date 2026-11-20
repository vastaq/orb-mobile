import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/orb_controller.dart';
import '../tasks/task_service.dart';
import '../tasks/task_store.dart';

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String _date(DateTime t) => '${t.year}/${t.month}/${t.day}';
String _when(OrbTask t) => switch (t.frequency) {
  TaskFrequency.once => '${_date(t.due)} ${_clock(t.due)}',
  TaskFrequency.daily => '每天 ${_clock(t.due)}',
  TaskFrequency.weekly => '每周${'一二三四五六日'[t.due.weekday - 1]} ${_clock(t.due)}',
};
String _failure(Object e) => e is OrbException ? e.message : '操作未完成，请重试。';
void _toast(BuildContext c, String text) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(text)));

Future<void> openOrbTasks(
  BuildContext context,
  OrbController controller, {
  int? taskId,
}) async {
  try {
    final service = await TaskService.open();
    final task = taskId == null ? null : await service.store.find(taskId);
    if (!context.mounted) return;
    if (taskId != null && task == null) _toast(context, '这项任务已删除。');
    if (task != null && Platform.isIOS) {
      unawaited(service.processAppleDue(only: task.id));
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => task == null
            ? _Tasks(service, controller)
            : _Details(service, controller, task),
      ),
    );
  } catch (_) {
    if (context.mounted) _toast(context, '未能打开本地任务。');
  }
}

class _Tasks extends StatefulWidget {
  const _Tasks(this.service, this.controller);
  final TaskService service;
  final OrbController controller;
  @override
  State<_Tasks> createState() => _TasksState();
}

class _TasksState extends State<_Tasks> {
  late Future<List<OrbTask>> _items = widget.service.store.all();
  void _reload() {
    if (!mounted) return;
    setState(() {
      _items = widget.service.store.all();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('定时任务'),
      centerTitle: true,
      actions: [
        IconButton(
          tooltip: '创建任务',
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => _Editor(widget.service)),
            );
            _reload();
          },
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: SafeArea(
      child: FutureBuilder<List<OrbTask>>(
        future: _items,
        builder: (c, s) {
          if (s.hasError) {
            return Center(
              child: TextButton(
                onPressed: _reload,
                child: const Text('加载失败，重试'),
              ),
            );
          }
          if (!s.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final tasks = s.data!;
          if (tasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.alarm_outlined, size: 34),
                  const SizedBox(height: 12),
                  const Text('暂无定时任务'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _Editor(widget.service),
                        ),
                      );
                      _reload();
                    },
                    child: const Text('创建任务'),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: tasks.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, indent: 20, endIndent: 20),
            itemBuilder: (c, i) {
              final t = tasks[i];
              return ListTile(
                leading: Icon(
                  t.kind == TaskKind.prompt
                      ? Icons.auto_awesome_outlined
                      : Icons.notifications_none_rounded,
                ),
                title: Text(
                  t.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${_when(t)} · ${t.enabled ? '已开启' : '已关闭'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          _Details(widget.service, widget.controller, t),
                    ),
                  );
                  _reload();
                },
              );
            },
          );
        },
      ),
    ),
  );
}

class _Details extends StatefulWidget {
  const _Details(this.service, this.controller, this.task);
  final TaskService service;
  final OrbController controller;
  final OrbTask task;
  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  late OrbTask _task = widget.task;
  List<TaskRun> _runs = [];
  bool _working = false;
  Timer? _update;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  @override
  void dispose() {
    _update?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final t = await widget.service.store.find(_task.id);
    final runs = await widget.service.store.runs(_task.id);
    if (!mounted || t == null) return;
    setState(() {
      _task = t;
      _runs = runs;
    });
    _update?.cancel();
    final waiting = runs.any((r) => r.status == 'running');
    if (waiting || t.enabled) {
      final until =
          t.due.difference(DateTime.now()) + const Duration(seconds: 1);
      _update = Timer(
        waiting || until.isNegative ? const Duration(seconds: 4) : until,
        _refresh,
      );
    }
  }

  Future<void> _edit({bool enable = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _Editor(widget.service, task: _task, enable: enable),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _toggle(bool on) async {
    final t = _task;
    final now = DateTime.now();
    final next = t.due.isAfter(now) ? t.due : t.nextAfter(now);
    if (on && next == null) {
      await _edit(enable: true);
      return;
    }
    setState(() => _working = true);
    try {
      final permitted = !on || await widget.service.requestNotifications();
      await widget.service.save(
        OrbTask(
          id: t.id,
          revision: t.revision,
          title: t.title,
          body: t.body,
          kind: t.kind,
          frequency: t.frequency,
          due: next ?? t.due,
          enabled: on,
        ),
      );
      if (mounted && !permitted) _toast(context, '系统通知未开启，结果仍可在执行记录查看。');
    } catch (e) {
      if (mounted) _toast(context, _failure(e));
    } finally {
      if (mounted) {
        setState(() => _working = false);
        await _refresh();
      }
    }
  }

  Future<void> _run() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await widget.service.runNow(_task);
    } catch (e) {
      if (mounted) _toast(context, _failure(e));
    } finally {
      if (mounted) {
        setState(() => _working = false);
        await _refresh();
      }
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这项定时任务？'),
        content: const Text('已生成的对话会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.service.remove(_task);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, _failure(e));
    }
  }

  Future<void> _showRun(TaskRun run) async {
    if (run.threadId != null) {
      await widget.controller.refresh();
      if (widget.controller.threads.any((t) => t.id == run.threadId)) {
        await widget.controller.selectChat(run.threadId!);
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
    }
    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('执行结果'),
          content: SingleChildScrollView(
            child: SelectableText(run.result.isEmpty ? '正在执行…' : run.result),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('任务详情'),
      centerTitle: true,
      actions: [
        IconButton(
          tooltip: '编辑任务',
          onPressed: _working ? null : () => _edit(),
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text(_task.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(_when(_task)),
          const SizedBox(height: 20),
          SelectableText(_task.body),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用任务'),
            value: _task.enabled,
            onChanged: _working ? null : _toggle,
          ),
          OutlinedButton.icon(
            onPressed: _working ? null : _run,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(_working ? '正在处理…' : '立即运行'),
          ),
          const SizedBox(height: 22),
          Text('执行记录', style: Theme.of(context).textTheme.titleMedium),
          if (_runs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('暂无记录', style: TextStyle(color: Colors.grey)),
            ),
          for (final run in _runs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${_date(run.at)} ${_clock(run.at)} · ${switch (run.status) {
                  'done' => '已完成',
                  'running' => '执行中',
                  'cancelled' => '已取消',
                  _ => '失败',
                }}',
              ),
              subtitle: Text(
                run.result.isEmpty ? '正在执行…' : run.result,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showRun(run),
            ),
          const Divider(),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _working ? null : _remove,
              child: const Text(
                '删除任务',
                style: TextStyle(color: Color(0xffff9a9e)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Editor extends StatefulWidget {
  const _Editor(this.service, {this.task, this.enable = false});
  final TaskService service;
  final OrbTask? task;
  final bool enable;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final _name = TextEditingController(text: widget.task?.title ?? '');
  late final _body = TextEditingController(text: widget.task?.body ?? '');
  late TaskKind _kind = widget.task?.kind ?? TaskKind.reminder;
  late TaskFrequency _frequency = widget.task?.frequency ?? TaskFrequency.once;
  late DateTime _due;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final proposed = widget.task?.due;
    _due = proposed != null && proposed.isAfter(DateTime.now())
        ? proposed
        : DateTime.now().add(const Duration(minutes: 3));
    _due = DateTime(_due.year, _due.month, _due.day, _due.hour, _due.minute);
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final enabled = widget.enable || (widget.task?.enabled ?? true);
      final draft = OrbTask(
        id: widget.task?.id ?? 0,
        revision: widget.task?.revision ?? 0,
        title: _name.text.trim(),
        body: _body.text.trim(),
        kind: _kind,
        frequency: _frequency,
        due: _due,
        enabled: enabled,
      );
      if (draft.body.isEmpty || draft.title.isEmpty) {
        throw const OrbException('请填写任务名称和内容。');
      }
      final permitted = !enabled || await widget.service.requestNotifications();
      await widget.service.save(draft);
      if (mounted) {
        if (!permitted) _toast(context, '系统通知未开启，结果仍可在执行记录查看。');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _failure(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.task == null ? '创建任务' : '编辑任务'),
      centerTitle: true,
      actions: [
        TextButton(onPressed: _saving ? null : _save, child: const Text('保存')),
      ],
    ),
    body: SafeArea(
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          SegmentedButton<TaskKind>(
            segments: const [
              ButtonSegment(value: TaskKind.reminder, label: Text('提醒')),
              ButtonSegment(value: TaskKind.prompt, label: Text('运行提示词')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: '任务名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: _kind == TaskKind.prompt ? '提示词' : '提醒内容',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<TaskFrequency>(
            initialValue: _frequency,
            decoration: const InputDecoration(
              labelText: '重复',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: TaskFrequency.once, child: Text('仅一次')),
              DropdownMenuItem(value: TaskFrequency.daily, child: Text('每天')),
              DropdownMenuItem(value: TaskFrequency.weekly, child: Text('每周')),
            ],
            onChanged: (f) {
              if (f != null) setState(() => _frequency = f);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              _frequency == TaskFrequency.weekly ? '首次日期（决定星期）' : '首次日期',
            ),
            trailing: Text(_date(_due)),
            onTap: () async {
              final n = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: _due,
                firstDate: DateTime(n.year, n.month, n.day),
                lastDate: DateTime(n.year + 10),
              );
              if (d != null && mounted) {
                setState(
                  () => _due = DateTime(
                    d.year,
                    d.month,
                    d.day,
                    _due.hour,
                    _due.minute,
                  ),
                );
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('本地时间'),
            trailing: Text(_clock(_due)),
            onTap: () async {
              final a = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(_due),
              );
              if (a != null && mounted) {
                setState(
                  () => _due = DateTime(
                    _due.year,
                    _due.month,
                    _due.day,
                    a.hour,
                    a.minute,
                  ),
                );
              }
            },
          ),
          if (_kind == TaskKind.prompt)
            Text(
              Platform.isIOS
                  ? 'iOS 会按系统调度在后台运行；点按到时通知也能执行。结果保存在本机对话中。'
                  : 'Android 会在系统分配的后台时间运行当前模型。结果保存在本机对话中。',
              style: const TextStyle(color: Colors.grey),
            ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xffff9a9e)),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
