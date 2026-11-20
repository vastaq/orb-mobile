import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/orb_controller.dart';

import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'history.dart';
import 'home_orb.dart';
import 'compose_tools.dart';
import 'voice.dart';
import 'orb_mark.dart';
import 'preferences.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});
  final OrbController controller;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final scaffold = GlobalKey<ScaffoldState>();
  final input = TextEditingController();
  final scroll = ScrollController();
  final focus = FocusNode();
  final drafts = <String?, String>{};
  final fileDrafts = <String?, List<OrbAttachment>>{};
  List<OrbAttachment> files = [];
  bool follow = true;
  bool submitting = false;
  Future<void>? switching;
  OrbController get orb => widget.controller;

  @override
  void initState() {
    super.initState();
    orb.addListener(onChanged);
  }

  void onChanged() {
    if (!mounted) return;
    setState(() {});
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && follow && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    orb.removeListener(onChanged);
    input.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> changeThread(String? id) async {
    if (orb.busy || switching != null) return;
    drafts[orb.activeId] = input.text;
    fileDrafts[orb.activeId] = List.of(files);
    focus.unfocus();
    follow = true;
    setState(() {
      input.text = drafts[id] ?? '';
      files = List.of(fileDrafts[id] ?? []);
    });
    final transition = id == null ? orb.newChat() : orb.selectChat(id);
    switching = transition;
    try {
      await transition;
    } finally {
      switching = null;
    }
  }

  void apply(ComposerResult? result) {
    if (!mounted || result == null) return;
    final text = result.text;
    if (text != null && text.isNotEmpty) {
      final next = [if (input.text.isNotEmpty) input.text, text].join('\n');
      input.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
    if (result.attachments.isNotEmpty) {
      setState(() => files = [...files, ...result.attachments]);
    }
  }

  Future<void> submit() async {
    if (switching != null) {
      await switching;
      if (!mounted) return;
    }
    final text = input.text.trim(), selected = List.of(files);
    if ((text.isEmpty && selected.isEmpty) ||
        submitting ||
        (orb.busy && orb.queuedText != null)) {
      return;
    }
    submitting = true;
    try {
      if (!orb.busy && selected.isEmpty && isComposerCommand(text)) {
        input.clear();
        focus.unfocus();
        apply(await runComposerCommand(context, orb, text));
        return;
      }
      if (!orb.config.usable) {
        focus.unfocus();
        if (await openModelSettings(context, orb) != true || !mounted) return;
      }
      follow = true;
      drafts.remove(orb.activeId);
      fileDrafts.remove(orb.activeId);
      input.clear();
      setState(() => files = []);
      focus.unfocus();
      final pending = orb.send(text, attachments: selected);
      submitting = false;
      await pending;
      if (mounted &&
          orb.error != null &&
          !orb.canRetry &&
          input.text.isEmpty &&
          files.isEmpty) {
        input.text = text;
        setState(() => files = selected);
      }
    } finally {
      submitting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: scaffold,
      drawer: orb.ready
          ? HistoryDrawer(controller: orb, onSelect: changeThread)
          : null,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                SizedBox(
                  height:
                      (MediaQuery.textScalerOf(context).scale(18) * 1.22 +
                              MediaQuery.textScalerOf(context).scale(11) *
                                  1.35 +
                              18)
                          .clamp(64.0, double.infinity),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          tooltip: '对话与设置',
                          onPressed: orb.ready
                              ? () {
                                  focus.unfocus();
                                  scaffold.currentState?.openDrawer();
                                }
                              : null,
                          icon: Transform.translate(
                            offset: const Offset(0, -1),
                            child: const OrbGlyph(
                              Glyph.history,
                              color: Color(0xffeeece5),
                            ),
                          ),
                        ),
                        Flexible(
                          child: Tooltip(
                            message: '模型连接',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: orb.busy
                                  ? null
                                  : () {
                                      focus.unfocus();
                                      openModelSettings(context, orb);
                                    },
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.sizeOf(context).width * .5,
                                  minHeight: 48,
                                ),
                                child: Transform.translate(
                                  offset: const Offset(0, -2),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        orb.prompts.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontFamily: 'OrbInter',
                                          fontFamilyFallback: ['OrbSans'],
                                          fontSize: 18,
                                          height: 1.22,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -.35,
                                          color: Color(0xffeeece5),
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              orb.config.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'OrbInter',
                                                fontSize: 11,
                                                letterSpacing: 0,
                                                height: 1.35,
                                                color: Color(0xffaaa9a1),
                                              ),
                                            ),
                                          ),
                                          const OrbGlyph(
                                            Glyph.chevron,
                                            size: 13,
                                            color: Color(0xffaaa9a1),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '新对话',
                          onPressed: orb.ready && !orb.busy
                              ? () => changeThread(null)
                              : null,
                          icon: Transform.translate(
                            offset: const Offset(1, -2),
                            child: const OrbGlyph(
                              Glyph.compose,
                              size: 23,
                              color: Color(0xffeeece5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!orb.ready)
                  Expanded(
                    child: Center(
                      child: orb.error == null
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(orb.error!, textAlign: TextAlign.center),
                                TextButton(
                                  onPressed: orb.initialize,
                                  child: const Text('重新打开'),
                                ),
                              ],
                            ),
                    ),
                  )
                else ...[
                  Expanded(
                    child: orb.messages.isEmpty
                        ? const _Welcome()
                        : NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n is ScrollUpdateNotification &&
                                      n.dragDetails != null ||
                                  n is ScrollEndNotification) {
                                follow = n.metrics.extentAfter < 64;
                              }
                              return false;
                            },
                            child: ListView.builder(
                              key: ValueKey(orb.activeId),
                              controller: scroll,
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
                              itemCount:
                                  orb.messages.length +
                                  (orb.busy && orb.messages.last.role == 'user'
                                      ? 1
                                      : 0),
                              itemBuilder: (context, i) => MessageView(
                                message: i == orb.messages.length
                                    ? const OrbMessage('assistant', '')
                                    : orb.messages[i],
                                controller: orb,
                                onEdit: (m) {
                                  apply(
                                    ComposerResult(
                                      text: m.text,
                                      attachments: m.attachments,
                                    ),
                                  );
                                  focus.requestFocus();
                                },
                                latest: i == orb.messages.length - 1,
                                pending:
                                    orb.busy && i >= orb.messages.length - 1,
                              ),
                            ),
                          ),
                  ),
                  if (orb.error != null || orb.canRetry)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              orb.error ?? '回复已中断',
                              style: TextStyle(
                                color: orb.error == null
                                    ? const Color(0xffaaaaaa)
                                    : const Color(0xffffaaaa),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          if (orb.canRetry)
                            TextButton(
                              onPressed: orb.busy ? null : orb.retry,
                              child: const Text('重试'),
                            ),
                        ],
                      ),
                    ),
                  if (orb.queuedText != null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.schedule_send_outlined),
                      title: Text(
                        '待发送 · ${orb.queuedText!.isEmpty ? '附件' : orb.queuedText}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: '取消待发送',
                        icon: const Icon(Icons.close),
                        onPressed: orb.cancelQueued,
                      ),
                    ),
                  if (files.isNotEmpty)
                    SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final f in files)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InputChip(
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 180,
                                  ),
                                  child: Text(
                                    f.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                avatar: Icon(
                                  f.isImage
                                      ? Icons.image_outlined
                                      : Icons.attach_file,
                                  size: 17,
                                ),
                                onDeleted: () =>
                                    setState(() => files.remove(f)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: _Composer(
                      input: input,
                      focus: focus,
                      orb: orb,
                      onSend: submit,
                      hasFiles: files.isNotEmpty,
                      onTools: () async {
                        focus.unfocus();
                        apply(await openComposeTools(context, orb));
                      },
                      onVoice: () async {
                        focus.unfocus();
                        final text = await recordVoice(
                          context,
                          orb.voiceConfig,
                        );
                        if (text != null) apply(ComposerResult(text: text));
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxHeight < 100) return const SizedBox.shrink();
        final scale = MediaQuery.textScalerOf(context).scale(38) / 38;
        final compact = c.maxWidth < 360 || scale > 1.3;
        final markSlot = compact ? 92.0 : 128.0;
        final markSize = compact ? 64.0 : 88.0;
        return Align(
          alignment: const Alignment(0, -.130),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '有什么\n想聊的？',
                    style: TextStyle(
                      fontFamily: 'OrbSong',
                      letterSpacing: 0,
                      fontVariations: const [FontVariation('wght', 500)],
                      fontSize: c.maxWidth < 360 ? 32 : 38,
                      height: 48 / 38,
                      color: const Color(0xffeeece5),
                    ),
                  ),
                ),
                if (c.maxWidth > 275 && c.maxHeight > 160)
                  SizedBox.square(
                    dimension: markSlot,
                    child: Center(
                      child: SizedBox.square(
                        dimension: markSize,
                        child: const FittedBox(child: HomeOrb()),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.input,
    required this.focus,
    required this.orb,
    required this.onSend,
    required this.hasFiles,
    required this.onTools,
    required this.onVoice,
  });
  final TextEditingController input;
  final FocusNode focus;
  final OrbController orb;
  final VoidCallback onSend, onTools, onVoice;
  final bool hasFiles;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 62),
      decoration: BoxDecoration(
        color: const Color(0xff20211f),
        borderRadius: BorderRadius.circular(31),
        border: Border.all(color: const Color(0xff353632)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '添加工具或附件',
            onPressed: onTools,
            icon: Transform.translate(
              offset: const Offset(-3, 0),
              child: const OrbGlyph(
                Glyph.add,
                size: 24,
                color: Color(0xffdadad2),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              key: const ValueKey('composer'),
              controller: input,
              focusNode: focus,
              minLines: 1,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(
                fontSize: 16,
                height: 1.42,
                color: Color(0xffeeece5),
              ),
              decoration: const InputDecoration(
                hintText: '发消息给 Orb',
                hintStyle: TextStyle(
                  fontFamily: 'OrbSans',
                  fontSize: 16,
                  letterSpacing: 0,
                  color: Color(0xffaaa9a1),
                ),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 9),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            tooltip: '语音输入',
            onPressed: onVoice,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            icon: Transform.translate(
              offset: const Offset(-4, 0),
              child: const OrbGlyph(
                Glyph.mic,
                size: 24,
                color: Color(0xffdadad2),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: input,
            builder: (_, value, _) {
              final hasDraft = hasFiles || value.text.trim().isNotEmpty;
              final stop = orb.busy && (!hasDraft || orb.queuedText != null),
                  enabled = stop || hasDraft;
              return IconButton(
                key: const ValueKey('send'),
                tooltip: stop
                    ? '停止生成'
                    : orb.busy
                    ? '排队发送'
                    : '发送',
                onPressed: stop
                    ? orb.stop
                    : enabled
                    ? onSend
                    : null,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                icon: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: enabled
                        ? const Color(0xffdaded2)
                        : const Color(0xff393b36),
                  ),
                  child: OrbGlyph(
                    stop ? Glyph.stop : Glyph.arrow,
                    color: enabled
                        ? const Color(0xff20221e)
                        : const Color(0xffa9aba3),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.controller,
    required this.pending,
    this.latest = false,
    this.onEdit,
  });
  final OrbMessage message;
  final OrbController controller;
  final bool pending, latest;
  final ValueChanged<OrbMessage>? onEdit;

  Future<void> _actions(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (key, icon, label) in [
                ('copy', Icons.copy_outlined, '复制文字'),
                if (message.role == 'user' && onEdit != null)
                  ('edit', Icons.edit_outlined, '编辑后重发'),
                ('share', Icons.ios_share, '分享'),
                ('memory', Icons.bookmark_border, '存为本地记忆'),
                if (message.metadata['context'] is Map ||
                    message.metadata['usage'] is Map)
                  ('details', Icons.data_usage, '本轮上下文与用量'),
                if (message.role == 'assistant')
                  ('read', Icons.volume_up_outlined, '朗读'),
                if (message.role == 'assistant' &&
                    latest &&
                    !controller.busy) ...[
                  ('continue', Icons.short_text, '继续写'),
                  ('retry', Icons.refresh, '重新生成'),
                ],
              ])
                ListTile(
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () => Navigator.pop(ctx, key),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
      case 'share':
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            text: message.text,
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      case 'memory':
        await editMemoryText(context, controller, message.text);
      case 'read':
        await readAloud(context, controller.voiceConfig, message.text);
      case 'edit':
        onEdit?.call(message);
      case 'details':
        final c = message.metadata['context'] as Map?,
            u = message.metadata['usage'] as Map?;
        await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                Text('本轮上下文与用量', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (u != null)
                  Text('输入 ${u['input']} · 输出 ${u['output']} token')
                else
                  const Text('模型未回报完整 token 用量。'),
                if (c != null) ...[
                  const Divider(),
                  Text('保留 ${c['keptTurns']} 轮，压缩 ${c['compressedTurns']} 轮'),
                  Text('引用 ${(c['memoryIds'] as List?)?.length ?? 0} 条本地记忆'),
                  if ((c['truncatedFields'] ?? 0) > 0)
                    Text('节选 ${c['truncatedFields']} 段长文本'),
                  if ((c['summary'] ?? '') != '')
                    ExpansionTile(
                      title: const Text('查看历史摘录'),
                      children: [SelectableText(c['summary'])],
                    ),
                ],
              ],
            ),
          ),
        );
      case 'continue':
        await controller.regenerate(extend: true);
      case 'retry':
        await controller.regenerate();
    }
  }

  Future<void> openLink(BuildContext context, String? url) async {
    final uri = Uri.tryParse(url ?? '');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return;
    }
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      /* Display the recoverable failure below. */
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开这个链接。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width.clamp(0, 760) * .8,
          ),
          margin: const EdgeInsets.only(top: 12, bottom: 18),
          decoration: BoxDecoration(
            color: const Color(0xff252620),
            borderRadius: BorderRadius.circular(19),
          ),
          child: InkWell(
            onLongPress: () => _actions(context),
            borderRadius: BorderRadius.circular(19),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in message.attachments) _AttachmentView(f),
                  if (message.text.isNotEmpty)
                    Text(
                      message.text,
                      style: const TextStyle(fontSize: 16, height: 1.45),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (message.text.isEmpty && !pending) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            OrbMark(size: 19),
            SizedBox(width: 8),
            Text(
              'Orb',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 9),
        if (message.metadata['localTools'] case final List actions
            when actions.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('工具执行 · ${actions.length}'),
            children: [
              for (final row in actions.whereType<Map>())
                ListTile(
                  dense: true,
                  leading: Icon(
                    row['ok'] == true
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                  ),
                  title: Text(row['name'].toString()),
                  subtitle: SelectableText(
                    [
                      for (final entry in row.entries)
                        if (entry.key != 'ok' && entry.key != 'name')
                          '${entry.key}  ${entry.value}',
                    ].join('    '),
                  ),
                ),
            ],
          ),
        if (message.metadata['toolsUnavailable'] == true)
          const Text('当前模型连接未提供本机工具。', style: TextStyle(color: Colors.grey)),
        if (message.metadata['thinking'] case final String thought
            when thought.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              '思考过程',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            children: [SelectableText(thought)],
          ),
        if (message.text.isEmpty)
          Semantics(
            label: '正在生成回复',
            child: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          GestureDetector(
            onLongPress: () => _actions(context),
            child: MarkdownBody(
              data: message.text,
              onTapLink: (_, url, _) => openLink(context, url),
              imageBuilder: (uri, title, alt) =>
                  Text(alt?.isNotEmpty == true ? alt! : '图片'),
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: const TextStyle(
                      fontSize: 16,
                      height: 1.55,
                      color: Color(0xffe5e6dc),
                    ),
                    code: const TextStyle(
                      color: Color(0xffdedede),
                      backgroundColor: Color(0xff242424),
                      fontFamily: 'monospace',
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: const Color(0xff171717),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
            ),
          ),
        if (message.metadata['citations'] case final List refs)
          for (final ref in refs.whereType<Map>())
            if (ref['url'] is String)
              TextButton.icon(
                onPressed: () => openLink(context, ref['url']),
                icon: const Icon(Icons.link, size: 16),
                label: Text(
                  (ref['title'] ?? ref['url']).toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        if (message.receipt?.isNotEmpty == true)
          TextButton.icon(
            onPressed: () => openMemories(context, controller),
            icon: const Icon(Icons.bookmark_added_outlined, size: 15),
            label: Text(message.receipt!),
          ),
        if (!pending && message.text.isNotEmpty)
          Row(
            children: [
              IconButton(
                tooltip: '回复操作',
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.zero,
                onPressed: () => _actions(context),
                icon: const Icon(
                  Icons.more_horiz,
                  size: 19,
                  color: Color(0xff999999),
                ),
              ),
              if (message.status == 'stopped' ||
                  message.status == 'interrupted')
                const Text(
                  '已停止',
                  style: TextStyle(fontSize: 12, color: Color(0xff999999)),
                ),
            ],
          ),
      ],
    );
  }
}

class _AttachmentView extends StatelessWidget {
  const _AttachmentView(this.file);
  final OrbAttachment file;
  @override
  Widget build(BuildContext context) {
    final fallback = Text(
      '附件 · ${file.name}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    if (!file.isImage || (file.localPath == null && file.dataUrl.isEmpty)) {
      return fallback;
    }
    ImageProvider? image;
    if (file.localPath != null) {
      image = FileImage(File(file.localPath!));
    } else {
      try {
        final Uint8List data = UriData.parse(file.dataUrl).contentAsBytes();
        image = MemoryImage(data);
      } on FormatException {
        return fallback;
      }
    }
    final source = image;
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: InteractiveViewer(
            child: Image(
              image: source,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => fallback,
            ),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image(
            image: ResizeImage.resizeIfNeeded(480, null, source),
            height: 116,
            fit: BoxFit.contain,
            semanticLabel: file.name,
            errorBuilder: (_, _, _) => fallback,
          ),
        ),
      ),
    );
  }
}
