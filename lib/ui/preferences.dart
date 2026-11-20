import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/orb_controller.dart';

const _surface = Color(0xff141414);
const _line = Color(0xff343434);
const _muted = Color(0xffa3a3a3);
const _warning = Color(0xffff9a9e);

Future<bool?> openModelSettings(
  BuildContext context,
  OrbController controller,
) => Navigator.of(context)
    .push<bool>(MaterialPageRoute(builder: (_) => _ModelSettings(controller)));

Future<void> openMemories(BuildContext context, OrbController controller) =>
    Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => _Memories(controller)));

Future<void> editMemoryText(
  BuildContext context,
  OrbController controller,
  String initialText,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => _MemoryEditor(controller, null, initialText: initialText),
  ),
);

AppBar _bar(String title, {Widget? action}) => AppBar(
  backgroundColor: Colors.black,
  foregroundColor: Colors.white,
  surfaceTintColor: Colors.transparent,
  scrolledUnderElevation: 0,
  leading: const BackButton(),
  centerTitle: true,
  title: Text(
    title,
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
  ),
  actions: [
    if (action != null)
      Padding(padding: const EdgeInsets.only(right: 8), child: action),
  ],
);

Widget _saveButton(VoidCallback? callback) => TextButton(
  style: TextButton.styleFrom(
    foregroundColor: Colors.black,
    backgroundColor: Colors.white,
    disabledForegroundColor: _muted,
    disabledBackgroundColor: _line,
    minimumSize: const Size(60, 44),
    padding: const EdgeInsets.symmetric(horizontal: 14),
  ),
  onPressed: callback,
  child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
);

InputDecoration _field(String label, {String? hint, Widget? trailing}) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: _line),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: const TextStyle(color: _muted),
    hintStyle: const TextStyle(color: Color(0xff888888)),
    filled: true,
    fillColor: _surface,
    enabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: const BorderSide(color: Colors.white),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    suffixIcon: trailing,
  );
}

Widget _note(String text, {bool error = false}) => Semantics(
  liveRegion: error,
  child: Text(
    text,
    style: TextStyle(
      color: error ? _warning : _muted,
      fontSize: 14,
      height: 1.5,
    ),
  ),
);

class _ModelSettings extends StatefulWidget {
  const _ModelSettings(this.controller);
  final OrbController controller;

  @override
  State<_ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<_ModelSettings> {
  static const _customName = '兼容接口';
  static const _presets = {
    'DeepSeek': ModelConfig.deepSeek,
    'OpenAI': ModelConfig.openAI,
    'Claude': ModelConfig.claude,
    _customName: ModelConfig(baseUrl: '', model: ''),
  };
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _drafts = <String, ModelConfig>{};
  late String _provider;
  String? _keyOrigin;
  bool _hidden = true;
  bool _saving = false;
  String? _error;

  bool get _custom => _provider == _customName;

  @override
  void initState() {
    super.initState();
    final active = widget.controller.config;
    final base = active.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    _provider =
        _presets.entries
            .where((entry) => entry.value.baseUrl == base)
            .firstOrNull
            ?.key ??
        _customName;
    for (final entry in _presets.entries) {
      _drafts[entry.key] =
          widget.controller.savedConfigFor(entry.value.baseUrl) ?? entry.value;
    }
    _drafts[_provider] = active;
    _loadDraft();
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  ModelConfig _readDraft() => ModelConfig(
    baseUrl: _custom ? _url.text.trim() : _presets[_provider]!.baseUrl,
    model: _model.text.trim(),
    apiKey: _key.text.trim(),
  );

  void _loadDraft() {
    final draft = _drafts[_provider]!;
    _url.text = draft.baseUrl;
    _model.text = draft.model;
    _key.text = draft.apiKey;
    _keyOrigin = _origin(draft.baseUrl);
  }

  String? _origin(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    try {
      return uri.origin;
    } on FormatException {
      return null;
    }
  }

  void _changed(String _) {
    if (_error != null) setState(() => _error = null);
  }

  // A typed or restored credential belongs to the service it was entered for.
  void _urlChanged(String text) {
    final origin = _origin(text);
    if (origin != _keyOrigin) _key.clear();
    _keyOrigin = origin;
    _changed(text);
  }

  void _switch(String provider) {
    if (provider == _provider || _saving) return;
    FocusScope.of(context).unfocus();
    _drafts[_provider] = _readDraft();
    setState(() {
      _provider = provider;
      _loadDraft();
      _hidden = true;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    final config = _readDraft();
    final invalid = config.settingsError;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveConfig(config);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '连接设置保存失败，请重试。';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar('模型连接', action: _saveButton(_saving ? null : _save)),
      body: SafeArea(
        top: false,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final name in _presets.keys)
                  ChoiceChip(
                    label: Text(name),
                    selected: name == _provider,
                    onSelected: _saving ? null : (_) => _switch(name),
                    showCheckmark: false,
                    selectedColor: Colors.white,
                    backgroundColor: _surface,
                    side: const BorderSide(color: _line),
                    shape: const StadiumBorder(),
                    labelStyle: TextStyle(
                      color: name == _provider ? Colors.black : Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 7,
                    ),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (_custom) ...[
              TextField(
                controller: _url,
                decoration: _field('服务地址', hint: 'https://example.com/v1'),
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onChanged: _urlChanged,
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: ValueKey('model-$_provider'),
              controller: _model,
              decoration: _field(
                '模型 ID',
                hint: _custom ? '服务提供的模型名称' : _presets[_provider]!.model,
              ),
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onChanged: _changed,
            ),
            const SizedBox(height: 16),
            TextField(
              key: ValueKey('key-$_provider'),
              controller: _key,
              decoration: _field(
                'API 密钥',
                trailing: IconButton(
                  tooltip: _hidden ? '显示密钥' : '隐藏密钥',
                  onPressed: () => setState(() => _hidden = !_hidden),
                  icon: Icon(
                    _hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                ),
              ),
              obscureText: _hidden,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              onChanged: _changed,
            ),
            const SizedBox(height: 12),
            _note(
              _custom
                  ? '填写兼容 Chat Completions 的服务地址和模型 ID。免鉴权服务可以留空密钥。'
                  : '可以先保存服务，发送前再填写 API 密钥。用量按你的开发者账户计费。',
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              _note(_error!, error: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _Memories extends StatelessWidget {
  const _Memories(this.controller);
  final OrbController controller;

  void _edit(BuildContext context, [OrbMemory? memory]) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => _MemoryEditor(controller, memory)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar(
        '本地记忆',
        action: IconButton(
          tooltip: '添加记忆',
          onPressed: () => _edit(context),
          icon: const Icon(Icons.add, size: 26),
        ),
      ),
      body: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final entries = controller.memories;
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                          ),
                          title: const Text(
                            '自动记忆',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          value: controller.autoMemoryEnabled,
                          onChanged: (enabled) async {
                            try {
                              await controller.setAutoMemoryEnabled(enabled);
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('自动记忆设置未能保存，请重试。'),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                          child: _note(
                            '开启后，所选模型会参考本轮对话和相关记忆，判断要记住什么。'
                            '记忆保存在本机，关闭后已有记忆仍可用于聊天。',
                          ),
                        ),
                        const Divider(color: _line, height: 1),
                      ],
                    ),
                  ),
                ),
                if (entries.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.bookmark_border_rounded,
                            size: 32,
                            color: _muted,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '暂无记忆',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => _edit(context),
                            child: const Text('写一条记忆'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverList.separated(
                    itemCount: entries.length,
                    itemBuilder: (_, index) {
                      final memory = entries[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        title: Text(
                          memory.text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            memory.isAutomatic ? '自动记录' : '手动保存',
                            style: const TextStyle(color: _muted, fontSize: 13),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: _muted,
                        ),
                        onTap: () => _edit(context, memory),
                      );
                    },
                    separatorBuilder: (_, _) => const Divider(
                      color: _line,
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MemoryEditor extends StatefulWidget {
  const _MemoryEditor(this.controller, this.memory, {this.initialText = ''});
  final String initialText;
  final OrbController controller;
  final OrbMemory? memory;

  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  late final _text = TextEditingController(
    text: widget.memory?.text ?? widget.initialText,
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _apply({bool delete = false}) async {
    if (_saving) return;
    final memory = widget.memory;
    final text = _text.text.trim();
    if (!delete && text.isEmpty) {
      setState(() => _error = '请写下想让 Orb 记住的内容。');
      return;
    }
    if (!delete && text.runes.length > OrbMemory.maxLength) {
      setState(() => _error = '请把记忆缩短到 ${OrbMemory.maxLength} 字以内。');
      return;
    }
    if (delete) {
      if (memory == null) return;
      FocusScope.of(context).unfocus();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _surface,
          title: const Text('删除这条记忆？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除', style: TextStyle(color: _warning)),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (delete) {
        await widget.controller.removeMemory(memory!.id);
      } else {
        await widget.controller.saveMemory(text, id: memory?.id);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '未能更新本地记忆，请重试。';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.memory != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar(
        editing ? '编辑记忆' : '添加记忆',
        action: _saveButton(_saving ? null : () => _apply()),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            TextField(
              controller: _text,
              autofocus: !editing,
              decoration: _field('记忆内容', hint: '例如：我希望回答简短一些。'),
              minLines: 4,
              maxLines: 10,
              maxLength: OrbMemory.maxLength,
              maxLengthEnforcement: MaxLengthEnforcement.none,
              buildCounter:
                  (
                    context, {
                    required currentLength,
                    required isFocused,
                    required maxLength,
                  }) {
                    final length = _text.text.trim().runes.length;
                    return Text(
                      '$length / ${OrbMemory.maxLength}',
                      style: TextStyle(
                        fontSize: 12,
                        color: length > OrbMemory.maxLength ? _warning : _muted,
                      ),
                    );
                  },
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) _note(_error!, error: true),
            if (editing)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: _warning,
                    minimumSize: const Size(44, 48),
                  ),
                  onPressed: _saving ? null : () => _apply(delete: true),
                  icon: const Icon(Icons.delete_outline_rounded, size: 19),
                  label: const Text('删除记忆'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
