import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/asset_bundle.dart';
import '../core/history_transfer.dart';
import '../core/orb_controller.dart';
import '../core/skill_packages.dart';
import '../core/workspace.dart';
import '../tasks/task_service.dart';
import '../tasks/task_store.dart';

enum _Kind {
  chats('对话与附件'),
  memories('记忆'),
  workspace('工作文件'),
  skills('技能'),
  tasks('定时任务'),
  prompts('个人配置');

  const _Kind(this.label);
  final String label;
}

typedef _Row = ({
  String id,
  String title,
  _Kind kind,
  VoidCallback? attachments,
});

class AssetLibrary extends StatefulWidget {
  const AssetLibrary(this.orb, {super.key});
  final OrbController orb;
  @override
  State<AssetLibrary> createState() => _AssetLibraryState();
}

class _AssetLibraryState extends State<AssetLibrary> {
  OrbController get orb => widget.orb;
  List<OrbTask> tasks = [];
  final selected = <String>{};
  List<String> paths = [];
  List<InstalledSkill> skills = [];
  String query = '';
  _Kind? filter;

  bool busy = true;
  String? notice;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final t = await (await TaskStore.open()).all();
      final w = await (await Workspace.open()).paths();
      final list = (await SkillLibrary.open()).list();
      if (mounted) {
        setState(() {
          tasks = t;
          paths = w;
          skills = list;
        });
      }
    } catch (_) {
      if (mounted) setState(() => notice = '无法读取本地资产。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await operation();
    } on ArchivePasswordException {
      if (mounted) setState(() => notice = '密码不正确。请重新选择文件并输入密码。');
    } on FormatException catch (e) {
      if (mounted) setState(() => notice = e.message);
    } on OrbException catch (e) {
      if (mounted) setState(() => notice = e.message);
    } catch (_) {
      if (mounted) setState(() => notice = '文件处理失败。请检查文件是否完整和本机剩余空间。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> password({required bool importing}) async {
    var value = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(importing ? '打开加密资产包' : '导出所选资产'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!importing) const Text('可用密码加密文件内容。ZIP 内的路径和文件名仍可见。'),
            TextField(
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (v) => value = v,
              decoration: InputDecoration(
                labelText: importing ? '密码' : '密码（可选）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, value),
            child: Text(importing ? '打开' : '导出'),
          ),
        ],
      ),
    );
  }

  Future<void> export() async {
    final pwd = await password(importing: false);
    if (!mounted || pwd == null) return;
    final data = (
      chats: <BundleThread>[],
      prompts: selected.contains('prompts') ? orb.prompts : null,
      memories: orb.memories
          .where((m) => selected.contains('m${m.id}'))
          .toList(),
      tasks: tasks.where((t) => selected.contains('t${t.id}')).toList(),
    );
    for (final t in orb.threads.where((e) => selected.contains('c${e.id}'))) {
      data.chats.add((thread: t, messages: await orb.historyFor(t.id)));
    }
    final work = <WorkFile>[];
    if (paths.any((p) => selected.contains('w$p'))) {
      final store = await Workspace.open();
      for (final p in paths.where((p) => selected.contains('w$p'))) {
        final f = await store.read(p);
        if (f != null) work.add(f);
      }
    }
    final packages = skills
        .where((s) => selected.contains('s${s.current.id}'))
        .toList();
    final raw = await compute(_encode, (data, pwd, work, packages));
    if (!mounted) return;
    final uri = await FilePicker.saveFile(
      fileName: 'Orb-assets.zip',
      bytes: raw,
      mimeType: 'application/zip',
      dialogTitle: '保存 Orb 资产包',
    );
    if (uri != null && mounted) setState(() => notice = '已保存所选资产。');
  }

  Future<void> import() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (!mounted || picked == null) return;
    if ((await picked.length() ?? 0) > maxBundleBytes + 2 * 1024 * 1024) {
      throw const FormatException('文件太大，请分批导入。');
    }
    final raw = picked.path == null
        ? Uint8List.fromList(
            await picked.readAsByteStream().expand((p) => p).toList(),
          )
        : await File(picked.path!).readAsBytes();
    BundleContents content;
    try {
      content = await compute(_decode, (raw, ''));
    } on ArchivePasswordException {
      if (!mounted) return;
      final pwd = await password(importing: true);
      if (pwd == null) return;
      content = await compute(_decode, (raw, pwd));
    }
    if (!mounted) return;
    final names = <_Kind, List<String>>{
      _Kind.chats: [for (final c in content.chats) c.title],
      _Kind.memories: [for (final m in content.memories) m.text],
      _Kind.workspace: [for (final f in content.workspace) f.file.path],
      _Kind.skills: [
        for (final s in content.skills)
          '${s.package.name} · ${s.package.versionLabel}',
      ],
      _Kind.tasks: [for (final t in content.tasks) t.title],
      _Kind.prompts: [
        if (content.prompts case final p?)
          '助手名称「${p.displayName}」、个人指令与 ${p.templates.length} 个模板',
      ],
    }..removeWhere((_, v) => v.isEmpty);
    final take = names.keys
        .where((k) => k != _Kind.prompts || names.length == 1)
        .toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 2),
          title: const Text('选择要导入的资产'),
          contentTextStyle: Theme.of(ctx).textTheme.bodyMedium
              ?.copyWith(letterSpacing: 0),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in names.entries)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: Checkbox(
                        value: take.contains(e.key),
                        onChanged: (v) => refresh(() {
                          if (v == true) {
                            take.add(e.key);
                          } else {
                            take.remove(e.key);
                          }
                        }),
                      ),
                      title: Text(
                        '${e.key.label}（${e.value.length}）',
                        style: const TextStyle(letterSpacing: 0),
                      ),
                      children: [
                        for (final text in e.value)
                          ListTile(
                            dense: true,
                            title: Text(
                              text,
                              style: const TextStyle(letterSpacing: 0),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  if (names.isEmpty) const Text('包中没有可导入的资产。'),
                  for (final warning in content.warnings) Text(warning),
                  if (names.containsKey(_Kind.workspace))
                    const Text('两端分别修改的工作文件会保留两份。'),
                  if (names.containsKey(_Kind.tasks)) const Text('导入的任务初始关闭。'),
                  if (names.containsKey(_Kind.prompts))
                    const Text('勾选个人配置会应用助手名称和个人指令。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: take.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final details = <String>[];
    int changed = 0;
    for (final c in content.chats.where((_) => take.contains(_Kind.chats))) {
      var found = false;
      for (final local in orb.threads.where((t) => t.title == c.title)) {
        if (await localChatDigest(
              local.title,
              await orb.historyFor(local.id),
            ) ==
            c.digest) {
          found = true;
          break;
        }
      }
      if (!found) {
        changed += await orb.importThreads([
          ImportedThread('orb-assets-v1:${c.digest}', c.title, c.messages),
        ]);
      }
    }
    for (final n in content.memories.where(
      (_) => take.contains(_Kind.memories),
    )) {
      if (orb.memories.any((m) => m.text == n.text)) continue;
      final previous = orb.memories
          .where((m) => textDigest(m.text) == n.originalHash)
          .toList();
      await orb.saveMemory(
        n.text,
        id: previous.length == 1 ? previous.single.id : null,
      );
      changed++;
    }
    if (content.prompts case final p? when take.contains(_Kind.prompts)) {
      final templates = {
        for (final t in [...orb.prompts.templates, ...p.templates]) t.id: t,
      };
      final merged = PromptSettings(
        displayName: p.displayName,
        instructions: p.instructions,
        templates: templates.values.toList(),
      );
      if (!mapEqualsDeep(merged, orb.prompts)) {
        await orb.savePrompts(merged);
        changed++;
      }
    }
    final store = await TaskStore.open();
    for (final t in content.tasks.where((_) => take.contains(_Kind.tasks))) {
      if (tasks.any(
        (e) =>
            e.title == t.title &&
            e.kind == t.kind &&
            e.frequency == t.frequency &&
            e.due == t.due &&
            e.body == t.body,
      )) {
        continue;
      }
      final saved = await store.save(t);
      tasks = [...tasks, saved];
      changed++;
    }
    if (take.contains(_Kind.workspace)) {
      final ws = await Workspace.open();
      for (final item in content.workspace) {
        try {
          final result = await ws.importFile(item);
          if (result.changed) changed++;
          if (result.changed && result.conflict) {
            details.add('保留副本 · ${result.path}');
          }
        } on OrbException catch (e) {
          details.add('${item.file.path} · ${e.message}');
        }
      }
    }
    if (take.contains(_Kind.skills)) {
      final library = await SkillLibrary.open();
      for (final entry in content.skills) {
        try {
          if (restoreBundleSkill(library, entry)) changed++;
        } on FormatException catch (e) {
          details.add('${entry.package.name} · ${e.message}');
        }
      }
    }
    await load();
    if (mounted) {
      setState(
        () => notice = [
          '已导入或更新 $changed 项，相同内容已跳过。',
          ...details,
          ...content.warnings,
        ].join('\n'),
      );
    }
  }

  Future<void> remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 ${selected.length} 项？'),
        content: const Text('会同时清除对话里独有的本地附件，已安排的任务将取消。此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final t in List.of(orb.threads)) {
      if (selected.contains('c${t.id}')) await orb.removeChat(t.id);
    }
    for (final m in List.of(orb.memories)) {
      if (selected.contains('m${m.id}')) await orb.removeMemory(m.id);
    }
    if (tasks.any((t) => selected.contains('t${t.id}'))) {
      final service = await TaskService.open();
      for (final t in tasks.where((t) => selected.contains('t${t.id}'))) {
        await service.remove(t);
      }
    }
    if (selected.contains('prompts')) {
      await orb.savePrompts(const PromptSettings());
    }
    final library = await SkillLibrary.open();
    for (final s in skills.where(
      (s) => selected.contains('s${s.current.id}'),
    )) {
      library.remove(s.current.id);
    }
    final work = await Workspace.open();
    for (final path in paths.where((p) => selected.contains('w$p'))) {
      await work.remove(path);
    }
    selected.clear();
    await load();
  }

  Future<void> manageAttachments(OrbThread thread) async {
    final messages = await orb.historyFor(thread.id);
    final files = <String, OrbAttachment>{
      for (final f in messages.expand((m) => m.attachments))
        '${f.name}\n${f.localPath}': f,
    };
    if (!mounted) return;
    final chosen = await showModalBottomSheet<OrbAttachment>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(thread.title),
              subtitle: Text('${files.length} 个附件'),
            ),
            for (final f in files.values)
              ListTile(
                leading: Icon(
                  f.isImage ? Icons.image_outlined : Icons.attach_file,
                ),
                title: Text(f.name),
                trailing: IconButton(
                  tooltip: '删除附件',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => Navigator.pop(ctx, f),
                ),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从这段对话删除附件？'),
        content: Text(chosen.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await orb.removeAttachment(thread.id, chosen);
  }

  Widget item(String key, String title, {VoidCallback? attachments}) {
    final select = CheckboxListTile(
      value: selected.contains(key),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: busy
          ? null
          : (v) => setState(() {
              if (v == true) {
                selected.add(key);
              } else {
                selected.remove(key);
              }
            }),
    );
    if (attachments == null) return select;
    return Row(
      children: [
        Expanded(child: select),
        IconButton(
          tooltip: '查看附件',
          onPressed: busy ? null : attachments,
          icon: const Icon(Icons.attach_file, size: 20),
        ),
      ],
    );
  }

  Widget label(String s) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Text(s, style: const TextStyle(color: Colors.grey)),
  );
  @override
  Widget build(BuildContext context) {
    final hasPrompts =
        orb.prompts.displayName != 'Orb' ||
        orb.prompts.instructions.isNotEmpty ||
        orb.prompts.templates.isNotEmpty;
    final rows = <_Row>[
      for (final c in orb.threads)
        (
          id: 'c${c.id}',
          title: c.title,
          kind: _Kind.chats,
          attachments: () => run(() => manageAttachments(c)),
        ),
      for (final m in orb.memories)
        (
          id: 'm${m.id}',
          title: m.text,
          kind: _Kind.memories,
          attachments: null,
        ),
      for (final p in paths)
        (id: 'w$p', title: p, kind: _Kind.workspace, attachments: null),
      for (final s in skills)
        (
          id: 's${s.current.id}',
          title: '${s.current.name} · ${s.current.id}',
          kind: _Kind.skills,
          attachments: null,
        ),
      for (final t in tasks)
        (id: 't${t.id}', title: t.title, kind: _Kind.tasks, attachments: null),
      if (hasPrompts)
        (
          id: 'prompts',
          title: '头栏名称、个人指令与 ${orb.prompts.templates.length} 个模板',
          kind: _Kind.prompts,
          attachments: null,
        ),
    ];
    final visible = rows
        .where(
          (r) =>
              (filter == null || r.kind == filter) &&
              r.title.toLowerCase().contains(query.trim().toLowerCase()),
        )
        .toList();
    final ids = {for (final r in visible) r.id};
    final all = ids.isNotEmpty && selected.containsAll(ids);
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地资产'),
        actions: [
          IconButton(
            tooltip: '导入资产包',
            onPressed: busy ? null : () => run(import),
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (notice != null)
              ListTile(
                dense: true,
                title: Text(
                  notice!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('处理结果'),
                    content: SingleChildScrollView(
                      child: SelectableText(notice!),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => query = v),
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search),
                        hintText: '搜索资产名称或路径',
                      ),
                    ),
                  ),
                  PopupMenuButton<_Kind?>(
                    tooltip: '筛选类别',
                    icon: Icon(
                      Icons.filter_list,
                      color: filter == null
                          ? null
                          : Theme.of(context).colorScheme.primary,
                    ),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        onTap: () => setState(() => filter = null),
                        child: const Text('全部类别'),
                      ),
                      for (final k in _Kind.values)
                        PopupMenuItem(value: k, child: Text(k.label)),
                    ],
                    onSelected: (v) => setState(() => filter = v),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: busy || ids.isEmpty
                      ? null
                      : () => setState(() {
                          if (all) {
                            selected.removeAll(ids);
                          } else {
                            selected.addAll(ids);
                          }
                        }),
                  child: Text(
                    all
                        ? '取消全选'
                        : filter != null || query.trim().isNotEmpty
                        ? '全选结果'
                        : '全选',
                  ),
                ),
                const Spacer(),
                Text('已选择 ${selected.length}'),
                const SizedBox(width: 16),
              ],
            ),
            Expanded(
              child: visible.isEmpty && !busy
                  ? ListTile(title: Text(rows.isEmpty ? '还没有本地资产' : '没有匹配的资产'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (ctx, i) {
                        final r = visible[i];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (i == 0 || visible[i - 1].kind != r.kind)
                              label(r.kind.label),
                            item(r.id, r.title, attachments: r.attachments),
                          ],
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => run(remove),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => run(export),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('导出所选'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<Uint8List> _encode(
  (AssetSnapshot, String, List<WorkFile>, List<InstalledSkill>) input,
) => encodeAssetBundle(
  input.$1,
  password: input.$2.isEmpty ? null : input.$2,
  workspace: input.$3,
  skills: input.$4,
);
BundleContents _decode((Uint8List, String) input) =>
    decodeAssetBundle(input.$1, password: input.$2.isEmpty ? null : input.$2);

bool mapEqualsDeep(PromptSettings a, PromptSettings b) =>
    jsonEncode(a.toJson()) == jsonEncode(b.toJson());
