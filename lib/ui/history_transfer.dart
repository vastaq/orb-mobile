import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/history_transfer.dart';
import '../core/orb_controller.dart';

Future<void> openHistoryImport(
  BuildContext context,
  OrbController controller,
) => Navigator.of(context)
    .push<void>(MaterialPageRoute(builder: (_) => _HistoryImport(controller)));

Future<void> shareThreadMarkdown(
  BuildContext context,
  String title,
  List<OrbMessage> messages,
) async {
  if (messages.isEmpty) return;
  final box = context.findRenderObject() as RenderBox?;
  final region = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  final normal = title.trim().replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_');
  final filename = normal.isEmpty
      ? 'Orb 对话'
      : String.fromCharCodes(normal.runes.take(80));
  try {
    final data = utf8.encode(await threadMarkdown(title, messages));
    await SharePlus.instance.share(
      ShareParams(
        title: '导出对话',
        files: [
          XFile.fromData(data, mimeType: 'text/markdown', name: '$filename.md'),
        ],
        fileNameOverrides: ['$filename.md'],
        sharePositionOrigin: region,
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未能分享该对话，请重试。')));
    }
  }
}

class _HistoryImport extends StatefulWidget {
  const _HistoryImport(this.controller);
  final OrbController controller;
  @override
  State<_HistoryImport> createState() => _HistoryImportState();
}

class _HistoryImportState extends State<_HistoryImport> {
  String? _path;
  String? _fileName;
  Directory? _temporary;
  List<HistoryEntry> _entries = [];
  final Set<String> _selected = {};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    final dir = _temporary;
    if (dir != null) unawaited(_clear(dir));
    super.dispose();
  }

  Future<void> _clear(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // System temporary storage can already have been reclaimed.
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    Directory? scratch;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'json'],
        dialogTitle: '选择 DeepSeek 导出文件',
      );
      if (files.isEmpty || !mounted) return;
      final picked = files.single;
      var path = picked.path;
      if (path == null) {
        scratch = await Directory.systemTemp.createTemp('orb-import-');
        final copy = File('${scratch.path}/archive');
        await picked.readAsByteStream().cast<List<int>>().pipe(
          copy.openWrite(),
        );
        path = copy.path;
      }
      final entries = await previewDeepSeekHistory(path);
      if (!mounted) return;
      final previous = _temporary;
      if (previous != null) await _clear(previous);
      if (!mounted) return;
      setState(() {
        _path = path;
        _fileName = picked.name;
        _temporary = scratch;
        _entries = entries;
        _selected.clear();
        if (entries.length == 1) _selected.add(entries.single.sourceId);
        if (entries.isEmpty) _error = '文件中没有对话。';
      });
      scratch = null;
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = '无法读取文件，请选择完整的 DeepSeek ZIP 或 conversations.json。',
        );
      }
    } finally {
      if (scratch != null) await _clear(scratch);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final path = _path;
    if (path == null || _busy || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final threads = await loadDeepSeekHistory(path, Set.of(_selected));
      if (!mounted) return;
      final imported = await widget.controller.importThreads(threads);
      if (!mounted) return;
      final previous = threads.length - imported;
      final alternate = threads.fold(0, (n, t) => n + t.otherNodes);
      final missing = threads.fold(0, (n, t) => n + t.missingFiles);
      final summary = [
        '新增 $imported 个对话。',
        if (previous > 0) '已导入过的 $previous 个对话保持原样。',
        if (alternate > 0) '所选归档另有 $alternate 条旁支消息，本次保留主分支。',
        if (missing > 0) '$missing 个附件缺少原件，已保留文件名。',
      ].join('\n');
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('导入完成'),
          content: Text(summary),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('完成'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '导入未完成，请检查归档或本机存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _entries.isNotEmpty && _selected.length == _entries.length;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('导入历史对话'), centerTitle: true),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '选择 DeepSeek 导出的 ZIP 或 conversations.json。所选对话的主分支将保存在本机。',
                              style: TextStyle(
                                color: Color(0xffaaaaaa),
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _pick,
                              icon: const Icon(Icons.folder_open_outlined),
                              label: Text(_path == null ? '选择文件' : '重新选择文件'),
                            ),
                            if (_fileName != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  _fileName!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (_error != null)
                              Semantics(
                                liveRegion: true,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                    _error!,
                                    style: const TextStyle(
                                      color: Color(0xffff9a9e),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (_entries.isNotEmpty)
                      SliverToBoxAdapter(
                        child: ListTile(
                          title: Text('选择对话（${_entries.length}）'),
                          trailing: TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    if (all) {
                                      _selected.clear();
                                    } else {
                                      _selected.addAll(
                                        _entries.map((e) => e.sourceId),
                                      );
                                    }
                                  }),
                            child: Text(all ? '取消全选' : '全选'),
                          ),
                        ),
                      ),
                    SliverList.builder(
                      itemCount: _entries.length,
                      itemBuilder: (_, i) {
                        final entry = _entries[i];
                        return CheckboxListTile(
                          value: _selected.contains(entry.sourceId),
                          title: Text(
                            entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${entry.messageCount} 条消息'),
                          onChanged: _busy
                              ? null
                              : (val) => setState(() {
                                  if (val == true) {
                                    _selected.add(entry.sourceId);
                                  } else {
                                    _selected.remove(entry.sourceId);
                                  }
                                }),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_entries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy || _selected.isEmpty ? null : _import,
                      child: Text('导入所选（${_selected.length}）'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
