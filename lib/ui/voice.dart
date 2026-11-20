import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/deepseek_media.dart';
import '../core/models.dart';
import '../core/recorded_audio.dart';

enum VoicePhase { idle, listening, transcribing, thinking, speaking, error }

/// Runtime shared by the foreground controls and the Android overlay engine.
/// Overlay permission requests are made by the foreground Activity beforehand.
class VoiceSession extends ChangeNotifier {
  VoiceSession({
    this.requestPermission = false,
    DeepSeekMedia Function(ModelConfig)? createMedia,
    AudioRecorder Function()? createRecorder,
    AudioPlayer Function()? createPlayer,
    Future<Directory> Function()? temporaryDirectory,
  }) : _createMedia = createMedia ?? DeepSeekMedia.new,
       _createRecorder = createRecorder ?? AudioRecorder.new,
       _createPlayer = createPlayer ?? AudioPlayer.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  final AudioRecorder Function() _createRecorder;
  final AudioPlayer Function() _createPlayer;
  final Future<Directory> Function() _temporaryDirectory;
  final bool requestPermission;
  final DeepSeekMedia Function(ModelConfig) _createMedia;
  VoicePhase _phase = VoicePhase.idle;
  VoicePhase get phase => _phase;
  String? _error;
  String? get error => _error;
  _VoiceTurn? _turn;
  bool _disposed = false;

  void _state(VoicePhase value, [String? message]) {
    if (_disposed) return;
    _phase = value;
    _error = message;
    notifyListeners();
  }

  bool _current(_VoiceTurn t) =>
      !_disposed && identical(_turn, t) && !t.cancelled;
  String _message(Object e, String fallback) =>
      e is OrbException ? e.message : fallback;

  Future<void> startListening(ModelConfig config) {
    if (_disposed) return Future.value();
    final prior = _turn;
    final t = _VoiceTurn(_createMedia(config));
    _turn = t;
    t.opening = () async {
      try {
        await prior?.close();
        if (!_current(t)) return;
        if (!DeepSeekMedia.supportsVoice(config)) {
          throw const OrbException('请选择支持语音的模型连接。');
        }
        if (!config.usable) throw OrbException(config.validationError!);
        final r = _createRecorder();
        t.recorder = r;
        if (!await r.hasPermission(request: requestPermission)) {
          throw const OrbException('请在系统设置中允许 Orb 使用麦克风。');
        }
        if (!_current(t)) return;
        final folder = await (await _temporaryDirectory()).createTemp(
          'orb-voice-',
        );
        t.folder = folder;
        if (!_current(t)) return;
        t.file = File('${folder.path}/input.wav');
        await r.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: t.file!.path,
        );
        t.recording = true;
        if (!_current(t)) return;
        // Leave a margin for platform scheduling against the 120 s ASR limit.
        t.limit = Timer(const Duration(seconds: 119), () async {
          try {
            await t.stopRecording();
          } catch (e) {
            if (_current(t)) {
              _state(VoicePhase.error, _message(e, '录音已中断，请重试。'));
            }
          }
        });
      } catch (e) {
        if (_current(t)) {
          _state(VoicePhase.error, _message(e, '麦克风暂不可用，请检查系统权限。'));
        }
      }
    }();
    _state(VoicePhase.listening);
    // Closing waits on the opening operation, so schedule it only after it settles.
    return t.opening!.then((_) async {
      if (_current(t) && _phase == VoicePhase.error) await t.close();
    });
  }

  Future<String?> releaseAndTranscribe() {
    final t = _turn;
    if (t == null || !_current(t)) return Future.value();
    return t.transcription ??= _transcribe(t);
  }

  Future<String?> _transcribe(_VoiceTurn t) async {
    try {
      await t.opening;
      if (!_current(t) || _phase != VoicePhase.listening || t.file == null) {
        return null;
      }
      await t.stopRecording();
      if (!_current(t)) return null;
      final file = t.file!;
      final hasInput =
          await file.exists() && hasRecordedSignal(await file.readAsBytes());
      if (!_current(t)) return null;
      if (!hasInput) {
        _state(VoicePhase.idle);
        return null;
      }
      _state(VoicePhase.transcribing);
      final text = (await t.media.transcribe(file)).trim();
      if (!_current(t)) return null;
      _state(VoicePhase.idle);
      return text.isEmpty ? null : text;
    } catch (e) {
      if (_current(t)) _state(VoicePhase.error, _message(e, '语音识别失败，请再试一次。'));
      return null;
    } finally {
      await t.close();
    }
  }

  Future<void> cancelListening() => interrupt();
  void setThinking() => _state(VoicePhase.thinking);

  Future<void> speak(ModelConfig config, String text) async {
    if (_disposed || text.trim().isEmpty) return;
    final previous = _turn;
    final t = _VoiceTurn(_createMedia(config));
    _turn = t;
    _state(VoicePhase.speaking);
    try {
      await previous?.close();
      if (!_current(t)) return;
      if (!DeepSeekMedia.supportsVoice(config)) {
        throw const OrbException('请选择支持朗读的语音服务。');
      }
      final folder = await (await _temporaryDirectory()).createTemp(
        'orb-voice-',
      );
      t.folder = folder;
      if (!_current(t)) {
        await t.removeFolder();
        return;
      }
      final player = _createPlayer();
      t.player = player;
      int part = 0;
      for (final chunk in _speechParts(text.trim())) {
        if (!_current(t)) return;
        final wav = await t.media.synthesize(chunk);
        if (!_current(t)) return;
        final file = File('${folder.path}/reply-${part++}.wav');
        await file.writeAsBytes(wav);
        if (!_current(t)) return;
        final done = Completer<void>();
        final sub = player.onPlayerComplete.listen(
          (_) {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object e) {
            if (!done.isCompleted) done.completeError(e);
          },
        );
        try {
          await player.play(DeviceFileSource(file.path, mimeType: 'audio/wav'));
          if (!_current(t)) return;
          await Future.any([done.future, t.interrupted.future]);
        } finally {
          await sub.cancel();
        }
        if (!_current(t)) return;
        if (await file.exists()) await file.delete();
      }
      if (_current(t)) _state(VoicePhase.idle);
    } catch (e) {
      if (_current(t)) {
        _state(VoicePhase.error, _message(e, '无法朗读这段回复，请检查语音连接。'));
      }
    } finally {
      await t.close();
    }
  }

  static Iterable<String> _speechParts(String text) sync* {
    final buffer = StringBuffer();
    var count = 0;
    for (final rune in text.runes) {
      buffer.writeCharCode(rune);
      count++;
      if (count >= 1800 || count >= 900 && '。！？.!?\n'.runes.contains(rune)) {
        yield buffer.toString();
        buffer.clear();
        count = 0;
      }
    }
    if (buffer.isNotEmpty) yield buffer.toString();
  }

  Future<void> interrupt() async {
    final t = _turn;
    _turn = null;
    _state(VoicePhase.idle);
    await t?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(interrupt());
    super.dispose();
  }
}

// Resources belong to a single turn. An old ASR/voice result can never replace
// the next recording or close the next player's network request.
class _VoiceTurn {
  _VoiceTurn(this.media);
  final DeepSeekMedia media;
  final interrupted = Completer<void>();
  AudioRecorder? recorder;
  AudioPlayer? player;
  Directory? folder;
  File? file;
  Timer? limit;
  bool recording = false;
  bool get cancelled => interrupted.isCompleted;
  Future<void>? opening;
  Future<void>? _stopping;
  Future<void>? _closing;
  Future<String?>? transcription;

  Future<void> stopRecording() => _stopping ??= () async {
    limit?.cancel();
    if (recording) {
      recording = false;
      await recorder!.stop();
    }
  }();

  Future<void> removeFolder() async {
    final dir = folder;
    if (dir != null) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        /* removed concurrently */
      }
    }
  }

  Future<void> close() => _closing ??= () async {
    interrupted.complete();
    limit?.cancel();
    media.close();
    try {
      if (player != null) await player!.stop();
    } catch (_) {
      /* a player can be interrupted before a source is ready */
    }
    try {
      await player?.dispose();
    } catch (_) {}
    try {
      await opening;
      await stopRecording();
    } catch (_) {}
    try {
      await recorder?.dispose();
    } catch (_) {}
    await removeFolder();
  }();
}

Future<String?> recordVoice(BuildContext context, ModelConfig config) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _VoiceSheet(config: config),
    );

Future<void> readAloud(BuildContext context, ModelConfig config, String text) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _VoiceSheet(config: config, text: text),
    );

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({required this.config, this.text});
  final ModelConfig config;
  final String? text;
  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  late final session = VoiceSession(requestPermission: true);
  @override
  void initState() {
    super.initState();
    start();
  }

  void start() {
    final text = widget.text;
    if (text == null) {
      unawaited(session.startListening(widget.config));
    } else {
      unawaited(session.speak(widget.config, text));
    }
  }

  Future<void> finish() async {
    final text = await session.releaseAndTranscribe();
    if (mounted && text != null) Navigator.pop(context, text);
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final voice = widget.text == null;
          final status = switch (session.phase) {
            VoicePhase.listening => '正在录音',
            VoicePhase.transcribing => '正在转写',
            VoicePhase.speaking => 'AI 语音朗读',
            VoicePhase.error => session.error ?? '请重试',
            VoicePhase.thinking => '正在生成',
            VoicePhase.idle => voice ? '没有听到语音' : '朗读结束',
          };
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              if (session.phase == VoicePhase.listening)
                FilledButton(onPressed: finish, child: const Text('完成录音'))
              else if (voice && session.phase == VoicePhase.idle)
                OutlinedButton(onPressed: start, child: const Text('再录一次'))
              else if (session.phase == VoicePhase.error)
                OutlinedButton(onPressed: start, child: const Text('重试')),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  voice
                      ? '取消'
                      : session.phase == VoicePhase.speaking
                      ? '停止朗读'
                      : '关闭',
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
