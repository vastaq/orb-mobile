import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/deepseek_media.dart';
import '../core/mobile_tools.dart';
import '../core/skill_packages.dart';
import 'skills.dart';
import '../core/orb_controller.dart';
import 'preferences.dart';
import 'prompt_settings.dart';

class ComposerResult {
  const ComposerResult({this.text, this.attachments = const []});
  final String? text;
  final List<OrbAttachment> attachments;
}

Future<ComposerResult?> openComposeTools(
  BuildContext context,
  OrbController controller,
) => showModalBottomSheet<ComposerResult>(
  context: context,
  isScrollControlled: true,
  barrierColor: const Color(0x99000000),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  useSafeArea: true,
  builder: (_) => _Tools(controller: controller),
);

bool isComposerCommand(String input) =>
    MobileCommand.parse(input) != null ||
    ['/skill', '/skills'].contains(input.trim());

Future<ComposerResult?> chooseSkill(BuildContext context) async {
  final items = (await SkillLibrary.open())
      .list()
      .where((s) => s.enabled)
      .toList();
  if (!context.mounted) return null;
  final id = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => ListView(
      shrinkWrap: true,
      children: [
        for (final item in items)
          ListTile(
            title: Text(item.current.name),
            subtitle: Text(
              item.current.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pop(ctx, item.current.id),
          ),
        ListTile(
          leading: const Icon(Icons.extension_outlined),
          title: const Text('管理技能'),
          onTap: () => Navigator.pop(ctx, '@manage'),
        ),
      ],
    ),
  );
  if (id == '@manage' && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const SkillManagerPage()),
    );
    return null;
  }
  return id == null ? null : ComposerResult(text: '/skill $id ');
}

Future<ComposerResult?> runComposerCommand(
  BuildContext context,
  OrbController controller,
  String input,
) async {
  if (['/skill', '/skills'].contains(input.trim())) return chooseSkill(context);
  switch (MobileCommand.parse(input)) {
    case MobileCommand.newChat:
      await controller.newChat();
      return const ComposerResult();
    case MobileCommand.memory:
      final note = input.trim().substring('/memory'.length).trim();
      if (note.isEmpty) {
        await openMemories(context, controller);
      } else {
        await editMemoryText(context, controller, note);
      }
      return const ComposerResult();
    case MobileCommand.time:
      return ComposerResult(text: localTimeText(DateTime.now()));
    case MobileCommand.tools:
      return openComposeTools(context, controller);
    case null:
      return null;
  }
}

enum _FileInput { attachment, ocr, layout }

class _Tools extends StatefulWidget {
  const _Tools({required this.controller});
  final OrbController controller;
  @override
  State<_Tools> createState() => _ToolsState();
}

class _ToolsState extends State<_Tools> {
  bool more = false;
  String? busy, error;
  DeepSeekMedia? media;
  OrbController get orb => widget.controller;
  @override
  void dispose() {
    media?.close();
    super.dispose();
  }

  void close() => Navigator.pop(context);
  Future<void> run(
    String label,
    Future<ComposerResult?> Function() action,
  ) async {
    if (busy != null) return;
    setState(() {
      busy = label;
      error = null;
    });
    try {
      final result = await action();
      if (mounted && result != null) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is OrbException ? e.message : '操作未完成，请检查权限和文件后重试。',
        );
      }
    } finally {
      media?.close();
      media = null;
      if (mounted) setState(() => busy = null);
    }
  }

  Future<String?> ask(
    String title,
    String hint, {
    String initial = '',
    String action = '确定',
    bool allowEmpty = false,
  }) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          onChanged: (s) => value = s,
          decoration: InputDecoration(hintText: hint),
          onFieldSubmitted: (s) {
            if (allowEmpty || s.trim().isNotEmpty) {
              Navigator.pop(context, s.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (allowEmpty || value.trim().isNotEmpty) {
                Navigator.pop(context, value.trim());
              }
            },
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<ComposerResult?> photo(ImageSource source) async {
    final pick = await ImagePicker().pickImage(
      source: source,
      requestFullMetadata: false,
    );
    if (pick == null || !mounted) return null;
    return ComposerResult(
      attachments: [
        await pickedAttachment(
          File(pick.path),
          pick.name,
          orb.config,
          image: true,
        ),
      ],
    );
  }

  Future<ComposerResult?> chooseFile([
    _FileInput input = _FileInput.attachment,
  ]) async {
    const documents = {'pdf', 'doc', 'docx', 'ppt', 'pptx'};
    final extensions = switch (input) {
      _FileInput.ocr => {...imageExtensions, ...documents},
      _FileInput.layout => documents,
      _FileInput.attachment => {
        ...textExtensions,
        ...documentMime.keys,
        ...imageExtensions,
      },
    };
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: extensions.toList(),
    );
    if (selected == null || !mounted) return null;
    final path = selected.path;
    if (path == null) throw const OrbException('无法读取所选文件，请先保存到本机。');
    final file = File(path);
    String? purpose;
    if (input != _FileInput.attachment) {
      final ocr = input == _FileInput.ocr;
      final mode = await showDialog<bool>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(ocr ? '识别方式' : '文档解析方式'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, false),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('提取文字'),
                subtitle: Text('适合合同、文章和扫描件'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, true),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('识别版面'),
                subtitle: Text('逐页识别文档布局'),
              ),
            ),
          ],
        ),
      );
      if (mode == null || !mounted) return null;
      if (ocr) {
        media = DeepSeekMedia(orb.config);
        return ComposerResult(text: await media!.ocr(file, rich: mode));
      }
      purpose = mode ? 'rich_layout_recognition' : 'text_recognition';
    }
    return ComposerResult(
      attachments: [
        await pickedAttachment(
          file,
          selected.name,
          orb.config,
          purpose: purpose,
        ),
      ],
    );
  }

  Future<ComposerResult?> web(bool fetch) async {
    final input = await ask(
      fetch ? '读取网页' : '搜索网页',
      fetch ? 'https://…' : '输入关键词',
      action: fetch ? '读取' : '搜索',
    );
    if (input == null || !mounted) return null;
    media = DeepSeekMedia(orb.config);
    return ComposerResult(
      text: fetch ? await media!.fetch(input) : await media!.search(input),
    );
  }

  Widget quick(IconData icon, String label, VoidCallback action) => Expanded(
    child: InkWell(
      onTap: busy == null ? action : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 16, 2, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: const Color(0xffdbddd2)),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'OrbSans',
                fontSize: 14,
                height: 20 / 14,
                letterSpacing: 0,
                color: Color(0xffdbddd2),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget row(
    IconData icon,
    String label,
    Future<ComposerResult?> Function() action,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    onTap: busy == null ? () => run(label, action) : null,
  );

  @override
  Widget build(BuildContext context) {
    final ds = orb.config.service == ModelService.deepSeek;
    final flash = orb.config.supportsDeepSeekTools;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .78,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xff66685f),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!more)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!ds || flash)
                    quick(
                      Icons.photo_outlined,
                      '照片',
                      () => run('照片', () => photo(ImageSource.gallery)),
                    ),
                  if (!ds || flash)
                    quick(
                      Icons.camera_alt_outlined,
                      '拍照',
                      () => run('拍照', () => photo(ImageSource.camera)),
                    ),
                  quick(
                    Icons.attach_file,
                    '文件',
                    () => run('文件', () => chooseFile()),
                  ),
                  quick(
                    Icons.more_horiz,
                    '更多输入',
                    () => setState(() => more = true),
                  ),
                ],
              )
            else ...[
              Row(
                children: [
                  IconButton(
                    tooltip: '返回附件',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: busy == null
                        ? () => setState(() => more = false)
                        : null,
                  ),
                  const Expanded(
                    child: Text(
                      '更多输入',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              row(Icons.extension_outlined, '使用技能', () => chooseSkill(context)),
              ExpansionTile(
                leading: const Icon(Icons.text_snippet_outlined),
                title: const Text('提示模板'),
                children: [
                  for (final template in orb.prompts.templates)
                    ListTile(
                      title: Text(template.name),
                      subtitle: Text(
                        template.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: busy == null
                          ? () => Navigator.pop(
                              context,
                              ComposerResult(text: template.text),
                            )
                          : null,
                    ),
                  ListTile(
                    title: const Text('管理模板'),
                    leading: const Icon(Icons.edit_outlined),
                    onTap: busy == null
                        ? () async {
                            await openPromptSettings(context, orb);
                            if (mounted) setState(() {});
                          }
                        : null,
                  ),
                ],
              ),
              ExpansionTile(
                leading: const Icon(Icons.terminal_outlined),
                title: const Text('快捷指令'),
                children: [
                  for (final cmd in MobileCommand.values.where(
                    (c) => c != MobileCommand.tools,
                  ))
                    ListTile(
                      title: Text(cmd.label),
                      trailing: Text(cmd.name),
                      onTap: busy == null
                          ? () => run(
                              cmd.label,
                              () => runComposerCommand(context, orb, cmd.name),
                            )
                          : null,
                    ),
                ],
              ),
              if (ds)
                ExpansionTile(
                  leading: const Icon(Icons.post_add_outlined),
                  title: const Text('从文件或网页插入'),
                  children: [
                    row(
                      Icons.document_scanner_outlined,
                      '识别文字到草稿',
                      () => chooseFile(_FileInput.ocr),
                    ),
                    if (flash)
                      row(
                        Icons.slideshow_outlined,
                        '选择文档解析方式',
                        () => chooseFile(_FileInput.layout),
                      ),
                    row(Icons.search, '插入网页搜索结果', () => web(false)),
                    row(Icons.link, '插入网页正文', () => web(true)),
                  ],
                ),
              const SizedBox(height: 12),
            ],
            if (busy != null)
              ListTile(
                leading: const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text(busy!),
                trailing: TextButton(onPressed: close, child: const Text('取消')),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
