import 'package:flutter/material.dart';

import '../core/orb_controller.dart';

Future<void> openPromptSettings(
  BuildContext context,
  OrbController controller,
) => Navigator.push<void>(
  context,
  MaterialPageRoute(builder: (_) => _PromptPage(controller: controller)),
);

class _PromptPage extends StatefulWidget {
  const _PromptPage({required this.controller});
  final OrbController controller;
  @override
  State<_PromptPage> createState() => _PromptState();
}

class _PromptState extends State<_PromptPage> {
  late final TextEditingController name, instructions;
  late List<PromptTemplate> templates;
  String? error;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final prompts = widget.controller.prompts;
    name = TextEditingController(text: prompts.displayName);
    instructions = TextEditingController(text: prompts.instructions);
    templates = [...prompts.templates];
  }

  @override
  void dispose() {
    name.dispose();
    instructions.dispose();
    super.dispose();
  }

  Future<void> edit([PromptTemplate? item]) async {
    final result = await showDialog<PromptTemplate>(
      context: context,
      builder: (_) => _TemplateDialog(item: item),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (item == null) {
        templates.add(result);
      } else {
        templates[templates.indexWhere((t) => t.id == item.id)] = result;
      }
    });
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.savePrompts(
        PromptSettings(
          displayName: name.text.trim().isEmpty ? 'Orb' : name.text.trim(),
          instructions: instructions.text.trim(),
          templates: List.unmodifiable(templates),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          error = '保存失败，请重试。';
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('个人提示'),
      actions: [
        TextButton(onPressed: saving ? null : save, child: const Text('保存')),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          TextField(
            controller: name,
            maxLength: 24,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '助手名称',
              hintText: 'Orb',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: instructions,
            minLines: 3,
            maxLines: 7,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: '个人指令',
              alignLabelWithHint: true,
              helperText: '随每次聊天和模型任务发送，可留空。',
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  '提示模板',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                onPressed: () => edit(),
                tooltip: '添加模板',
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (templates.isEmpty) const Text('保存常用的提问方式，在输入框的工具里选用。'),
          for (final item in templates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.name),
              subtitle: Text(
                item.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => edit(item),
              trailing: IconButton(
                tooltip: '移除模板',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() => templates.remove(item)),
              ),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}

class _TemplateDialog extends StatefulWidget {
  const _TemplateDialog({this.item});
  final PromptTemplate? item;
  @override
  State<_TemplateDialog> createState() => _TemplateState();
}

class _TemplateState extends State<_TemplateDialog> {
  late final TextEditingController title, body;
  @override
  void initState() {
    super.initState();
    title = TextEditingController(text: widget.item?.name);
    body = TextEditingController(text: widget.item?.text);
  }

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  bool get valid => title.text.trim().isNotEmpty && body.text.trim().isNotEmpty;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.item == null ? '添加模板' : '编辑模板'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(labelText: '模板名称'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: body,
            minLines: 3,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: '模板内容',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() {}),
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
        onPressed: valid
            ? () => Navigator.pop(
                context,
                PromptTemplate(
                  id:
                      widget.item?.id ??
                      DateTime.now().microsecondsSinceEpoch.toString(),
                  name: title.text.trim(),
                  text: body.text.trim(),
                ),
              )
            : null,
        child: const Text('完成'),
      ),
    ],
  );
}
