import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/workspace.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});
  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  Workspace? store;
  List<String> paths = [];
  String filter = '';
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      store ??= await Workspace.open();
      final result = await store!.paths();
      if (mounted) {
        setState(() {
          paths = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法打开工作区。');
    }
  }

  Future<void> edit({WorkFile? file, String? originalHash}) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _Editor(store!, file, originalHash),
      ),
    );
    await load();
  }

  Future<void> openPath(String path) async {
    final f = await store!.read(path);
    if (mounted && f != null) await edit(file: f, originalHash: f.hash);
  }

  Future<void> importText() async {
    try {
      final pick = await FilePicker.pickFile();
      if (pick == null) return;
      if ((await pick.length() ?? 0) > workspaceFileLimit) {
        throw const OrbException('每个工作文件最多 1 MiB。');
      }
      final data = <int>[];
      await for (final chunk in pick.readAsByteStream()) {
        if (data.length + chunk.length > workspaceFileLimit) {
          throw const OrbException('每个工作文件最多 1 MiB。');
        }
        data.addAll(chunk);
      }
      final content = utf8.decode(data);
      if (content.contains('\u0000')) throw const FormatException();
      if (mounted) await edit(file: WorkFile(pick.name, content));
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is OrbException ? e.message : '请选择 UTF-8 文本文件。',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = paths.where(
      (s) => s.toLowerCase().contains(filter.toLowerCase()),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作文件'),
        actions: [
          IconButton(
            tooltip: '导入文本文件',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: store == null ? null : importText,
          ),
          IconButton(
            tooltip: '新建文件',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: store == null ? null : () => edit(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (error != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
            if (paths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '查找文件名',
                  ),
                  onChanged: (s) => setState(() => filter = s),
                ),
              ),
            Expanded(
              child: store == null && error == null
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                  ? Center(
                      child: Text(
                        paths.isEmpty ? '可以新建、导入，或在聊天中让 Orb 写一份文件。' : '没有找到文件。',
                      ),
                    )
                  : ListView(
                      children: [
                        for (final path in visible)
                          ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: Text(path),
                            onTap: () => openPath(path),
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

class _Editor extends StatefulWidget {
  const _Editor(this.store, this.file, this.originalHash);
  final Workspace store;
  final WorkFile? file;
  final String? originalHash;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final name = TextEditingController(text: widget.file?.path);
  late final body = TextEditingController(text: widget.file?.text);
  String? error;
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await widget.store.save(
        WorkFile(name.text.trim(), body.text),
        previous: widget.originalHash,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is OrbException ? e.message : '文件未保存。';
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.originalHash == null ? '新建工作文件' : '编辑工作文件'),
      actions: [
        TextButton(onPressed: saving ? null : save, child: const Text('保存')),
      ],
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          children: [
            TextField(
              controller: name,
              readOnly: widget.originalHash != null,
              decoration: const InputDecoration(
                labelText: '相对路径',
                hintText: '读书/摘录.md',
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: TextField(
                controller: body,
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: '文件内容',
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
