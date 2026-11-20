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
import 'voice.dart';

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
  showDragHandle: true,
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

class _Tools extends StatefulWidget {
  const _Tools({required this.controller});
  final OrbController controller;
  @override
  State<_Tools> createState() => _ToolsState();
}

class _ToolsState extends State<_Tools> {
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

  Future<ComposerResult?> chooseFile({bool ocr = false}) async {
    final extensions = ocr
        ? {...imageExtensions, 'pdf', 'doc', 'docx', 'ppt', 'pptx'}
        : {...textExtensions, ...documentMime.keys, ...imageExtensions};
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: extensions.toList(),
    );
    if (selected == null || !mounted) return null;
    final path = selected.path;
    if (path == null) throw const OrbException('无法读取所选文件，请先保存到本机。');
    final file = File(path);
    final ext = selected.extension?.toLowerCase() ?? '';
    var rich = false;
    if (ocr ||
        orb.config.supportsDeepSeekTools &&
            {'pdf', 'doc', 'docx', 'ppt', 'pptx'}.contains(ext)) {
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
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(ocr ? '识别版面' : '保留图表与版面'),
                subtitle: Text(ocr ? '逐页识别文档布局' : '适合报告和演示文稿'),
              ),
            ),
          ],
        ),
      );
      if (mode == null || !mounted) return null;
      rich = mode;
    }
    if (ocr) {
      media = DeepSeekMedia(orb.config);
      return ComposerResult(text: await media!.ocr(file, rich: rich));
    }
    return ComposerResult(
      attachments: [
        await pickedAttachment(
          file,
          selected.name,
          orb.config,
          purpose: rich ? 'rich_layout_recognition' : 'text_recognition',
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

  Future<ComposerResult?> region() async {
    var area = orb.region ?? '';
    var lang = orb.language;
    final result = await showDialog<({String region, String language})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('地区与语言'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: area,
                maxLength: 80,
                onChanged: (v) => area = v,
                decoration: const InputDecoration(
                  labelText: '地区（可选）',
                  hintText: '例如：中国上海',
                ),
              ),
              TextFormField(
                initialValue: lang,
                maxLength: 35,
                onChanged: (v) => lang = v,
                decoration: const InputDecoration(
                  labelText: '语言',
                  hintText: '例如：zh-CN 或 en-US',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, (
                region: area.trim(),
                language: lang.trim().isEmpty ? 'zh-CN' : lang.trim(),
              ));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await orb.setChatOptions(
        userRegion: result.region,
        userLanguage: result.language,
      );
    }
    return null;
  }

  Widget quick(
    IconData icon,
    String label,
    Future<ComposerResult?> Function() action,
  ) => Expanded(
    child: TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      onPressed: busy == null ? () => run(label, action) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
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
    trailing: const Icon(Icons.chevron_right, size: 18),
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
        child: ListenableBuilder(
          listenable: orb,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '工具',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭工具',
                    onPressed: close,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Row(
                children: [
                  if (!ds || flash)
                    quick(
                      Icons.photo_outlined,
                      '照片',
                      () => photo(ImageSource.gallery),
                    ),
                  if (!ds || flash)
                    quick(
                      Icons.camera_alt_outlined,
                      '拍照',
                      () => photo(ImageSource.camera),
                    ),
                  quick(Icons.attach_file, '文件', () => chooseFile()),
                  if (DeepSeekMedia.supportsVoice(orb.voiceConfig))
                    quick(Icons.mic_none, '语音', () async {
                      final text = await recordVoice(context, orb.voiceConfig);
                      return text == null ? null : ComposerResult(text: text);
                    }),
                ],
              ),
              if (busy != null)
                ListTile(
                  leading: const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text(busy!),
                  trailing: TextButton(
                    onPressed: close,
                    child: const Text('取消'),
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.extension_outlined),
                title: const Text('使用技能'),
                onTap: busy != null
                    ? null
                    : () => run('选择技能', () => chooseSkill(context)),
              ),
              if (ds) ...[
                ExpansionTile(
                  title: const Text('对话选项'),
                  leading: const Icon(Icons.tune),
                  children: [
                    SwitchListTile(
                      title: const Text('深度思考'),
                      value: orb.thinking,
                      onChanged: busy == null
                          ? (v) => run('保存设置', () async {
                              await orb.setChatOptions(deepThinking: v);
                              return null;
                            })
                          : null,
                    ),
                    if (flash) ...[
                      SwitchListTile(
                        title: const Text('联网搜索'),
                        value: orb.search,
                        onChanged: busy == null
                            ? (v) => run('保存设置', () async {
                                await orb.setChatOptions(web: v);
                                return null;
                              })
                            : null,
                      ),
                      SwitchListTile(
                        title: const Text('读取消息中的链接'),
                        value: orb.readLinks,
                        onChanged: busy == null
                            ? (v) => run('保存设置', () async {
                                await orb.setChatOptions(links: v);
                                return null;
                              })
                            : null,
                      ),
                      ListTile(
                        title: const Text('地区与语言'),
                        subtitle: Text(
                          orb.region?.isNotEmpty == true
                              ? '${orb.region} · ${orb.language}'
                              : '未提供地区 · ${orb.language}',
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => run('地区与语言', region),
                      ),
                    ],
                  ],
                ),
                ExpansionTile(
                  title: const Text('DeepSeek 工具'),
                  leading: const Icon(Icons.travel_explore),
                  children: [
                    row(
                      Icons.document_scanner_outlined,
                      '识别图片或文档文字',
                      () => chooseFile(ocr: true),
                    ),
                    row(Icons.search, '独立搜索网页', () => web(false)),
                    row(Icons.link, '读取指定网页', () => web(true)),
                  ],
                ),
              ],
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
                        ? () => openPromptSettings(context, orb)
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
                      trailing: Text(
                        cmd.name,
                        style: const TextStyle(color: Colors.grey),
                      ),
                      onTap: busy == null
                          ? () => run(
                              cmd.label,
                              () => runComposerCommand(context, orb, cmd.name),
                            )
                          : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
