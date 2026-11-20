import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_provider.dart';
import 'models.dart';
import 'memory_harness.dart';
import 'mobile_harness.dart';
import 'history_transfer.dart';
import 'turn_context.dart';

import 'package:http/http.dart' as http;

import 'orb_store.dart';

export 'models.dart';
export 'chat_provider.dart' show ChatProvider;

class OrbController extends ChangeNotifier {
  OrbController({
    OrbStore? store,
    ChatProvider? provider,
    MemoryHarness? memoryHarness,
  }) : _store = store ?? OrbStore(),
       _provider = provider ?? StreamingChatProvider(usagePurpose: '对话'),
       _memory = memoryHarness ?? MemoryHarness();

  final OrbStore _store;
  final ChatProvider _provider;
  final MemoryHarness _memory;
  bool autoMemoryEnabled = true;
  bool thinking = false, search = true, readLinks = true;
  String? region;
  String language = 'zh-CN';
  PromptSettings prompts = const PromptSettings();
  Future<void> savePrompts(PromptSettings next) async {
    await persistPromptSettings(_store, next);
    prompts = next;
    _notify();
  }

  bool remembering = false;
  Map<String, ModelConfig> _profiles = {};
  http.Client? _upload;
  Future<void> _memoryTask = Future.value();
  int _memoryGeneration = 0;
  String? queuedText;
  List<OrbAttachment> _queuedFiles = [];
  ModelConfig? savedConfigFor(String url) =>
      _profiles[ModelConfig(baseUrl: url).service.name];
  ModelConfig get voiceConfig => config.service != ModelService.claude
      ? config
      : savedConfigFor(ModelConfig.deepSeek.baseUrl) ??
            savedConfigFor(ModelConfig.openAI.baseUrl) ??
            config;
  Future<void> setAutoMemoryEnabled(bool enabled) async {
    await _store.setPreference('auto_memory', enabled ? '1' : '0');
    autoMemoryEnabled = enabled;
    if (!enabled) {
      _memoryGeneration++;
      _memory.cancel();
    }
    _notify();
  }

  Future<void> setChatOptions({
    bool? deepThinking,
    bool? web,
    bool? links,
    String? userRegion,
    String? userLanguage,
  }) async {
    if (deepThinking != null) {
      thinking = deepThinking;
      await _store.setPreference('thinking', thinking ? '1' : '0');
    }
    if (web != null) {
      search = web;
      await _store.setPreference('search', search ? '1' : '0');
    }
    if (links != null) {
      readLinks = links;
      await _store.setPreference('read_links', readLinks ? '1' : '0');
    }
    if (userLanguage != null) {
      language = userLanguage;
      await _store.setPreference('language', language);
    }
    if (userRegion != null) {
      region = userRegion.trim();
      await _store.setPreference('region', region!);
    }
    _notify();
  }

  Future<void> refresh() async {
    if (busy || remembering) return;
    threads = await _store.threads();
    memories = await _store.memories();
    activeId = await _store.selected();
    messages = activeId == null ? [] : await _store.messages(activeId!);
    autoMemoryEnabled = await _store.preference('auto_memory') != '0';
    config = await _store.loadConfig();
    _profiles = await _store.loadProfiles();
    prompts = await loadPromptSettings(_store);
    _notify();
  }

  Future<int> importThreads(List<ImportedThread> items) async {
    var count = 0;
    for (final e in items) {
      if (await _store.importThread(e.sourceId, e.title, e.messages)) count++;
    }
    threads = await _store.threads();
    _notify();
    return count;
  }

  Future<void> removeAttachment(String id, OrbAttachment file) async {
    await _store.removeAttachment(id, file.name, file.localPath);
    if (id == activeId) messages = await _store.messages(id);
    _notify();
  }

  Future<List<OrbMessage>> historyFor(String id) => _store.messages(id);

  Future<void> renameThread(String id, String title) async {
    if (title.trim().isEmpty) return;
    await _store.renameThread(id, title.trim());
    threads = await _store.threads();
    _notify();
  }

  bool ready = false;
  String? error;
  String? activeId;
  List<OrbThread> threads = [];
  List<OrbMessage> messages = [];
  List<OrbMemory> memories = [];
  ModelConfig config = const ModelConfig();
  Completer<void>? _run;
  bool _stopped = false;
  bool _disposed = false;
  bool get busy => _run != null;
  bool get canRetry {
    if (busy || messages.isEmpty) return false;
    final last = messages.last;
    return last.role == 'user' || last.status != 'complete';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      await _store.open();
      threads = await _store.threads();
      memories = await _store.memories();
      activeId = await _store.selected();
      messages = activeId == null ? [] : await _store.messages(activeId!);
      config = await _store.loadConfig();
      _profiles = await _store.loadProfiles();
      prompts = await loadPromptSettings(_store);
      autoMemoryEnabled = await _store.preference('auto_memory') != '0';
      thinking = await _store.preference('thinking') == '1';
      search = await _store.preference('search') != '0';
      readLinks = await _store.preference('read_links') != '0';
      region = await _store.preference('region');
      language = await _store.preference('language') ?? 'zh-CN';
      error = null;
      ready = true;
    } catch (_) {
      error = '无法打开本机数据，请重新打开 Orb。';
    }
    _notify();
  }

  Future<void> saveConfig(ModelConfig next) async {
    final validation = next.settingsError;
    if (validation != null) throw OrbException(validation);
    final normalized = ModelConfig(
      baseUrl: next.baseUrl.trim(),
      model: next.model.trim(),
      apiKey: next.apiKey.trim(),
    );
    await _store.saveConfig(normalized);
    _profiles[normalized.service.name] = normalized;
    config = normalized;
    error = null;
    _notify();
  }

  Future<void> saveMemory(String value, {String? id}) async {
    final text = value.trim();
    if (text.isEmpty || text.runes.length > OrbMemory.maxLength) {
      throw const OrbException('记忆需要 1 至 500 个字。');
    }
    await _store.saveMemory(text, id);
    memories = await _store.memories();
    _notify();
  }

  Future<void> removeMemory(String id) async {
    await _store.removeMemory(id);
    memories = await _store.memories();
    _notify();
  }

  Future<void> _settle() async {
    final run = _run;
    if (run == null) return;
    cancelQueued();
    stop();
    await run.future;
  }

  Future<void> newChat() async {
    await _settle();
    await _store.select(null);
    activeId = null;
    messages = [];
    error = null;
    _notify();
  }

  Future<void> selectChat(String id) async {
    if (id == activeId) return;
    await _settle();
    if (!threads.any((item) => item.id == id)) return;
    final history = await _store.messages(id);
    await _store.select(id);
    activeId = id;
    messages = history;
    error = null;
    _notify();
  }

  Future<void> removeChat(String id) async {
    if (id == activeId) await _settle();
    await _store.removeChat(id);
    if (id == activeId) {
      activeId = null;
      messages = [];
      error = null;
    }
    threads = await _store.threads();
    _notify();
  }

  Future<void> send(
    String value, {
    List<OrbAttachment> attachments = const [],
  }) async {
    final text = value.trim();
    if ((text.isEmpty && attachments.isEmpty) || !ready) return;
    if (busy) {
      if (queuedText == null) {
        queuedText = text;
        _queuedFiles = attachments;
        _notify();
      }
      return;
    }
    await _reply(
      text.isEmpty ? '请看看附件。' : text,
      List.of(messages),
      false,
      attachments: attachments,
    );
  }

  void cancelQueued() {
    queuedText = null;
    _queuedFiles = [];
    _notify();
  }

  Future<void> regenerate({bool extend = false}) async {
    if (busy || messages.isEmpty || messages.last.role != 'assistant') return;
    final history = List.of(messages)..removeLast();
    if (history.isEmpty || history.last.role != 'user') return;
    final user = history.removeLast();
    await _reply(
      user.text,
      history,
      true,
      attachments: user.attachments,
      extend: extend,
    );
  }

  Future<void> retry() async {
    if (!canRetry) return;
    final history = List.of(messages);
    if (history.last.role == 'assistant') history.removeLast();
    if (history.isEmpty || history.last.role != 'user') return;
    final user = history.removeLast();
    await _reply(user.text, history, true, attachments: user.attachments);
  }

  Future<void> _reply(
    String question,
    List<OrbMessage> history,
    bool retry, {
    List<OrbAttachment> attachments = const [],
    bool extend = false,
  }) async {
    final validation = config.validationError;
    if (validation != null) {
      error = validation;
      _notify();
      return;
    }
    final run = Completer<void>();
    _run = run;
    _stopped = false;
    error = null;
    final isFirst = activeId == null;
    final connection = config;
    var user = OrbMessage('user', question, attachments: attachments);
    var visible = [...history, user];
    var meta = <String, dynamic>{
      if (extend && messages.isNotEmpty) ...messages.last.metadata,
    };
    var thoughts = '';
    final previous = retry && messages.lastOrNull?.role == 'assistant'
        ? messages.last.text
        : '';
    final buffer = StringBuffer(extend ? previous : '');
    var status = 'partial';
    int? answerId;
    _notify();
    try {
      await _memoryTask;
      if (_stopped) return;
      var files = attachments;
      if (files.isNotEmpty) files = await _store.persistAttachments(files);
      user = OrbMessage('user', question, attachments: files);
      visible = [...history, user];
      final turn = await _store.beginTurn(activeId, question, retry);
      answerId = turn.answer;
      activeId = turn.thread;
      if (files.isNotEmpty) await _store.attachToUser(answerId, files);
      threads = await _store.threads();
      messages = [
        ...visible,
        if (previous.isNotEmpty)
          OrbMessage('assistant', previous, status: 'partial'),
      ];
      _notify();
      if (_stopped) return;

      if (files.isNotEmpty && connection.service == ModelService.deepSeek) {
        final client = http.Client();
        _upload = client;
        try {
          final prepared = <OrbAttachment>[];
          for (final f in files) {
            if (_stopped) return;
            prepared.add(await prepareDocument(connection, f, client));
          }
          await _store.attachToUser(answerId, prepared);
          user = OrbMessage('user', question, attachments: prepared);
          visible = [...history, user];
        } finally {
          client.close();
          _upload = null;
        }
      }
      final provider = _provider;
      final Stream<ChatDelta> events;
      if (provider is RichChatProvider) {
        final context = await richContext(
          connection,
          history,
          memories,
          user,
          prompts: prompts,
          onSnapshot: (snapshot) {
            meta['context'] = snapshot.toJson();
          },
        );
        if (extend) {
          context.addAll([
            {'role': 'assistant', 'content': previous},
            {'role': 'user', 'content': '从刚才停下的地方接着写，直接续写，不重复前文。'},
          ]);
        }
        final harness = await MobileHarness.forTurn(
          turnKey: '${turn.thread}:${turn.answer}',
        );
        harness.addInstructions(context);
        final priorTools = meta['localTools'] as List? ?? [];
        harness.onReceipt = () async {
          meta['localTools'] = [...priorTools, ...harness.receipts];
          await _store.saveMetadata(turn.answer, meta);
          messages = [
            ...visible,
            OrbMessage(
              'assistant',
              buffer.toString(),
              status: 'partial',
              metadata: Map.of(meta),
            ),
          ];
          _notify();
        };
        events = provider.replyRich(
          connection,
          context,
          ChatOptions(
            thinking: thinking,
            search: search,
            readLinks: readLinks,
            region: region,
            language: language,
            suggestTitle: isFirst,
            tools: harness.tools,
            onTool: harness.run,
          ),
        );
      } else {
        events = provider
            .reply(connection, buildContext(history, memories, question))
            .map((s) => ChatDelta(text: s));
      }
      final checkpoint = Stopwatch()..start();
      await for (final delta in events) {
        if (_stopped) break;
        buffer.write(delta.text);
        thoughts += delta.thinking;
        if (delta.metadata != null) meta = {...meta, ...delta.metadata!};
        meta['provider'] = connection.service.name;
        if (thoughts.isNotEmpty) meta['thinking'] = thoughts;
        messages = [
          ...visible,
          OrbMessage(
            'assistant',
            buffer.toString(),
            status: 'partial',
            metadata: meta,
          ),
        ];
        _notify();
        if (checkpoint.elapsedMilliseconds > 700) {
          await _store.writeAnswer(answerId, buffer.toString(), 'partial');
          checkpoint.reset();
        }
      }
      if (!_stopped) status = 'complete';
    } on OrbException catch (e) {
      if (!_stopped) error = e.message;
    } catch (_) {
      if (!_stopped) error = '未能完成这次对话，请重试。';
    } finally {
      try {
        if (answerId != null) {
          final text = buffer.isNotEmpty
              ? buffer.toString()
              : previous.isNotEmpty
              ? previous
              : meta['localTools'] is List &&
                    (meta['localTools'] as List).isNotEmpty
              ? '本轮工具执行记录已保存。'
              : '';
          await _store.writeAnswer(answerId, text, status);
          if (meta.isNotEmpty) await _store.saveMetadata(answerId, meta);
          if (isFirst &&
              meta['title'] is String &&
              (meta['title'] as String).trim().isNotEmpty) {
            await _store.renameThread(activeId!, meta['title'] as String);
            threads = await _store.threads();
          }
          messages = [
            ...visible,
            if (text.isNotEmpty)
              OrbMessage('assistant', text, status: status, metadata: meta),
          ];
        }
      } catch (_) {
        error = '回复未能保存到本机，请检查存储空间。';
      }
      if (status == 'complete' &&
          !retry &&
          autoMemoryEnabled &&
          answerId != null &&
          !_disposed) {
        _memoryTask = _remember(connection, question, activeId!, answerId);
      }
      _run = null;
      run.complete();
      _notify();
      if (queuedText != null && !_disposed) {
        final next = queuedText!, files = _queuedFiles;
        queuedText = null;
        _queuedFiles = [];
        unawaited(send(next, attachments: files));
      }
    }
  }

  Future<void> _remember(
    ModelConfig source,
    String utterance,
    String threadId,
    int answerId,
  ) async {
    final epoch = _memoryGeneration;
    final snapshot = List.of(memories);
    remembering = true;
    _notify();
    try {
      final plan = await _memory.plan(source, utterance, snapshot);
      if (_disposed ||
          epoch != _memoryGeneration ||
          !autoMemoryEnabled ||
          plan.isEmpty) {
        return;
      }
      final receipt = await _store.applyMemoryPlan(answerId, plan, snapshot);
      if (receipt != null) {
        memories = await _store.memories();
        if (!busy && activeId == threadId) {
          messages = await _store.messages(threadId);
        }
      }
    } on Exception {
      /* A memory suggestion must not invalidate a completed reply. */
    } finally {
      remembering = false;
      _notify();
    }
  }

  void stop() {
    if (!busy) return;
    _stopped = true;
    _upload?.close();
    _provider.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    _memory.dispose();
    stop();
    super.dispose();
  }
}
