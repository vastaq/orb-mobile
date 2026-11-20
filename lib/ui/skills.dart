import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/skill_packages.dart';

class SkillManagerPage extends StatefulWidget {
  const SkillManagerPage({super.key, this.library});
  final SkillLibrary? library;
  @override
  State<SkillManagerPage> createState() => _SkillManagerState();
}

class _SkillManagerState extends State<SkillManagerPage> {
  SkillLibrary? library;
  List<InstalledSkill> installed = [];
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    open();
  }

  Future<void> open() async {
    await run(() async {
      library = widget.library ?? await SkillLibrary.open();
    });
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
      installed = library?.list() ?? [];
    } on FormatException catch (e) {
      error = e.message;
    } catch (_) {
      error = '无法读取技能。请检查文件、网络或本机空间，再试一次。';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> importFile() async {
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['md', 'zip'],
      dialogTitle: '选择 SKILL.md 或技能 ZIP',
    );
    if (f == null || !mounted) return;
    if ((await f.length() ?? 0) > maxSkillBytes) {
      throw const FormatException('技能包超过 1 MiB。');
    }
    final raw = BytesBuilder();
    final stream = f.path == null
        ? f.readAsByteStream()
        : File(f.path!).openRead();
    await for (final chunk in stream) {
      if (raw.length + chunk.length > maxSkillBytes) {
        throw const FormatException('技能包超过 1 MiB。');
      }
      raw.add(chunk);
    }
    await preview(decodeSkillPackage(raw.takeBytes()));
  }

  Future<void> importUrl() async {
    var value = '';
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从链接导入'),
        content: TextField(
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: '技能文件的 HTTPS 地址',
            hintText: 'https://',
          ),
          onChanged: (s) => value = s,
          onSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, value),
            child: const Text('读取'),
          ),
        ],
      ),
    );
    if (input == null || !mounted) return;
    final url = skillSource(input);
    final next = await library!.fetch(url);
    await preview(next, source: url);
  }

  Future<void> preview(SkillPackage next, {Uri? source}) async {
    if (!mounted) return;
    final old = library!.get(next.id);
    final from = source ?? next.updateUrl;
    final changedSource = old != null && old.source != from;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(old == null ? '安装技能？' : '更新技能？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(next.name, style: Theme.of(ctx).textTheme.titleMedium),
              Text(next.description),
              const SizedBox(height: 12),
              SelectableText(next.id),
              Text(
                old == null
                    ? '版本 ${next.versionLabel}'
                    : '${old.current.versionLabel} → ${next.versionLabel}',
              ),
              if (next.references.isNotEmpty)
                Text('附带 ${next.references.length} 份文本资料'),
              if (changedSource) Text('原来源：${old.source ?? '本地文件'}'),
              SelectableText('更新来源：${from ?? '本地文件'}'),
              if (changedSource) const Text('确认后将更换来源，并关闭自动更新。'),
              ExpansionTile(
                title: const Text('查看技能指令'),
                tilePadding: EdgeInsets.zero,
                children: [SelectableText(next.instructions)],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              changedSource
                  ? '更换来源并更新'
                  : old == null
                  ? '安装'
                  : '更新',
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      library!.install(next, source: source, replaceSource: changedSource);
    }
  }

  Future<void> showSkill(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _SkillDetails(library: library!, id: id),
      ),
    );
    if (mounted) setState(() => installed = library!.list());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('技能包')),
    body: SafeArea(
      child: ListView(
        children: [
          if (busy) const LinearProgressIndicator(),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('导入技能文件', style: TextStyle(letterSpacing: 0)),
            subtitle: const Text(
              'SKILL.md 或 ZIP',
              style: TextStyle(letterSpacing: 0),
            ),
            onTap: busy || library == null ? null : () => run(importFile),
          ),
          ListTile(
            leading: Transform.translate(
              offset: const Offset(-4, 0),
              child: const Icon(Icons.link),
            ),
            title: const Text('从链接导入', style: TextStyle(letterSpacing: 0)),
            onTap: busy || library == null ? null : () => run(importUrl),
          ),
          Transform.translate(
            offset: const Offset(0, -.5),
            child: const Divider(
              height: 16,
              thickness: 1,
              color: Color(0xffa19f97),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!busy && installed.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('还没有技能。导入后，可在聊天工具里选用。'),
            ),
          for (final row in installed)
            ListTile(
              title: Text(
                row.current.name,
                style: const TextStyle(letterSpacing: 0),
              ),
              subtitle: Text(
                '${row.enabled ? '已启用' : '已停用'} · ${row.current.versionLabel}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => showSkill(row.current.id),
            ),
        ],
      ),
    ),
  );
}

class _SkillDetails extends StatefulWidget {
  const _SkillDetails({required this.library, required this.id});
  final SkillLibrary library;
  final String id;
  @override
  State<_SkillDetails> createState() => _SkillDetailState();
}

class _SkillDetailState extends State<_SkillDetails> {
  bool busy = false;
  String? notice;
  Future<void> run(Future<String?> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      notice = await action();
    } on FormatException catch (e) {
      notice = e.message;
    } catch (_) {
      notice = '操作未完成。请检查网络或文件后重试。';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final lib = widget.library, id = widget.id, item = lib.get(id);
    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('技能已移除。')),
      );
    }
    final p = item.current;
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 18),
          children: [
            if (busy) const LinearProgressIndicator(),
            ListTile(
              title: Text(p.description),
              subtitle: SelectableText('${p.id} · ${p.versionLabel}'),
            ),
            SwitchListTile(
              title: const Text('在聊天中启用'),
              value: item.enabled,
              onChanged: busy
                  ? null
                  : (v) => run(() async {
                      lib.configure(id, enabled: v);
                      return null;
                    }),
            ),
            ExpansionTile(
              title: const Text('技能指令'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SelectableText(p.instructions),
                ),
              ],
            ),
            for (final e in p.references.entries)
              ExpansionTile(
                title: Text(e.key),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SelectableText(e.value),
                  ),
                ],
              ),
            const Divider(),
            if (item.source != null) ...[
              ListTile(
                title: const Text('更新来源'),
                subtitle: SelectableText(item.source.toString()),
              ),
              if (p.versioned)
                SwitchListTile(
                  title: const Text('自动更新'),
                  subtitle: const Text('打开 Orb 时检查同一来源的新版本。'),
                  value: item.autoUpdate,
                  onChanged: busy
                      ? null
                      : (v) => run(() async {
                          lib.configure(id, autoUpdate: v);
                          return null;
                        }),
                ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('检查更新'),
                onTap: busy
                    ? null
                    : () => run(
                        () async =>
                            await lib.update(id) ? '已更新到新版本。' : '已是当前版本。',
                      ),
              ),
            ] else
              const ListTile(
                title: Text('文件更新'),
                subtitle: Text('再次导入同一技能的新文件即可更新。'),
              ),
            if (item.previous != null)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('回退到上一版'),
                subtitle: Text(item.previous!.versionLabel),
                onTap: busy
                    ? null
                    : () => run(() async {
                        if (await confirm(
                          '回退到 ${item.previous!.versionLabel} 并关闭自动更新？',
                          '回退',
                        )) {
                          lib.rollback(id);
                          return '已回退。';
                        }
                        return null;
                      }),
              ),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('导出技能包'),
              onTap: busy
                  ? null
                  : () => run(() async {
                      final result = await FilePicker.saveFile(
                        dialogTitle: '保存技能包',
                        fileName: '${p.id}.zip',
                        mimeType: 'application/zip',
                        bytes: encodeSkillPackage(p),
                      );
                      return result == null ? null : '已保存技能包。';
                    }),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('移除技能'),
              onTap: busy
                  ? null
                  : () => run(() async {
                      if (await confirm('从手机移除「${p.name}」？', '移除')) {
                        lib.remove(id);
                        if (context.mounted) Navigator.pop(context);
                      }
                      return null;
                    }),
            ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(liveRegion: true, child: Text(notice!)),
              ),
          ],
        ),
      ),
    );
  }
}
