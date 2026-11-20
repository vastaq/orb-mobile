import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ui/voice.dart';
import 'orb_controller.dart';

/// Starts the Android service isolate without creating another visible app.
void runOrbOverlay() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_OverlaySession().start());
}

class _OverlaySession {
  final channel = const MethodChannel('studio.orb/overlay-engine');
  final orb = OrbController();
  final voice = VoiceSession();
  Future<void>? opening;
  Future<void>? chat;
  int generation = 0;
  int messageCount = 0;
  bool sending = false;
  bool holding = false;
  bool startNewConversation = false;
  bool disposed = false;
  String answer = '';
  String? error;

  Future<void> start() async {
    channel.setMethodCallHandler(command);
    voice.addListener(publish);
    orb.addListener(updateAnswer);
    await orb.initialize();
    error = orb.error;
    publish();
    await channel.invokeMethod<void>('ready');
  }

  void updateAnswer() {
    if (!sending || orb.messages.length <= messageCount) return;
    final last = orb.messages.last;
    if (last.role == 'assistant' && answer != last.text) {
      answer = last.text;
      publish();
    }
  }

  void publish() {
    if (disposed) return;
    final message = error ?? voice.error;
    unawaited(
      channel.invokeMethod<void>('status', {
        'phase': message == null ? voice.phase.name : 'error',
        'error': message ?? '',
        'answer': answer,
      }),
    );
  }

  Future<void> command(MethodCall call) async {
    try {
      switch (call.method) {
        case 'voice':
        case 'newVoice':
          final turn = ++generation;
          holding = true;
          startNewConversation = call.method == 'newVoice';
          opening = begin(turn);
          await opening;
        case 'release':
          if (!holding) return;
          holding = false;
          await release(generation);
        case 'settleConversation':
          await opening;
          await chat;
        case 'latest':
          final turn = generation;
          if (holding || sending || voice.phase != VoicePhase.idle) return;
          await orb.refresh();
          if (turn != generation || disposed) return;
          answer = latestAnswer;
          publish();
        case 'read':
          await read(++generation);
        case 'cancel':
        case 'stop':
          ++generation;
          holding = false;
          await interrupt();
        case 'dispose':
          ++generation;
          disposed = true;
          holding = false;
          voice.removeListener(publish);
          orb.removeListener(updateAnswer);
          await interrupt();
          voice.dispose();
          orb.dispose();
          channel.setMethodCallHandler(null);
        default:
          throw MissingPluginException(call.method);
      }
    } on MissingPluginException {
      rethrow;
    } catch (e) {
      error = e is OrbException ? e.message : '语音暂不可用，请打开 Orb 重试。';
      publish();
    }
  }

  Future<void> interrupt() async {
    error = null;
    sending = false;
    orb.stop();
    await voice.interrupt();
    await chat;
  }

  Future<bool> prepare(int turn) async {
    await interrupt();
    if (turn != generation || disposed) return false;
    // The visible app may have switched the selected chat, model or tools.
    await orb.initialize();
    if (turn != generation || disposed) return false;
    if (!orb.ready || orb.error != null) {
      error = orb.error ?? '无法打开本机对话。';
      publish();
      return false;
    }
    return true;
  }

  Future<void> begin(int turn) async {
    if (!await prepare(turn)) return;
    answer = '';
    await voice.startListening(orb.voiceConfig);
  }

  Future<void> release(int turn) async {
    await opening;
    if (turn != generation || disposed || voice.phase != VoicePhase.listening) {
      return;
    }
    final transcript = await voice.releaseAndTranscribe();
    if (turn != generation || disposed || transcript == null) return;
    if (startNewConversation && orb.activeId != null) {
      await orb.newChat();
      if (turn != generation || disposed) return;
    }
    messageCount = orb.messages.length;
    sending = true;
    voice.setThinking();
    final pending = () async {
      await orb.send(transcript);
      if (orb.messages.length > messageCount) {
        await channel.invokeMethod<void>('conversationChanged');
      }
    }();
    chat = pending;
    await pending;
    if (identical(chat, pending)) chat = null;
    if (turn != generation || disposed) return;
    updateAnswer();
    sending = false;
    final last = orb.messages.lastOrNull;
    if (orb.error != null ||
        last?.role != 'assistant' ||
        last?.status != 'complete' ||
        answer.trim().isEmpty) {
      error = orb.error ?? '没有收到完整回复，请打开 Orb 重试。';
      publish();
      return;
    }
    await voice.speak(orb.voiceConfig, answer);
  }

  String get latestAnswer {
    for (final item in orb.messages.reversed) {
      if (item.role == 'assistant' && item.text.trim().isNotEmpty) {
        return item.text;
      }
    }
    return '';
  }

  Future<void> read(int turn) async {
    holding = false;
    if (!await prepare(turn)) return;
    answer = latestAnswer;
    if (answer.isNotEmpty) {
      await voice.speak(orb.voiceConfig, answer);
      return;
    }
    error = '当前对话还没有可朗读的回复。';
    publish();
  }
}
