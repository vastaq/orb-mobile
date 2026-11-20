import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/deepseek_media.dart';
import 'package:orb_mobile/core/models.dart';
import 'package:orb_mobile/ui/voice.dart';
import 'package:record/record.dart';

/// Runs only on an explicitly selected test device with mic permission.
/// The native player plays silence. Audio captured for the file-format check
/// stays on the simulator, is never uploaded and is removed by VoiceSession.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native audio playback is interrupted by native WAV recording',
    (tester) async {
      final player = AudioPlayer();
      final began = Completer<void>();
      final subscription = player.onPlayerStateChanged.listen((state) {
        if (state == PlayerState.playing && !began.isCompleted) {
          began.complete();
        }
      });
      addTearDown(subscription.cancel);
      final media = _LocalAudioFixture();
      final session = VoiceSession(
        createMedia: (_) => media,
        createPlayer: () => player,
        createRecorder: () => _ObservedRecorder(media.inspectRecording),
      );
      addTearDown(session.dispose);
      const config = ModelConfig(
        baseUrl: 'http://127.0.0.1:18318/v1',
        model: 'fixture',
      );
      final reading = session.speak(config, '测试朗读');
      await began.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw StateError('native playback did not start: ${session.error}');
        },
      );
      await session.startListening(config);
      await reading;
      expect(session.phase, VoicePhase.listening, reason: session.error);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final text = await session.releaseAndTranscribe();
      if (const bool.fromEnvironment('ORB_TEST_SILENT_MIC')) {
        expect(text, isNull);
        expect(media.asrCalls, 0);
      } else {
        expect(text, media.asrCalls == 0 ? null : '本地音频文件已确认');
      }
      expect(session.phase, VoicePhase.idle);
      expect(media.recordedBytes, greaterThan(3200));
      expect(media.recordedRate, 16000);
      expect(media.recordedChannels, 1);
      expect(media.sampleBits, 16);
      expect(await File(media.recordedPath!).exists(), isFalse);
    },
    skip: !const bool.fromEnvironment('ORB_TEST_NATIVE_AUDIO'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _LocalAudioFixture extends DeepSeekMedia {
  _LocalAudioFixture() : super(const ModelConfig());
  int recordedBytes = 0, recordedRate = 0, recordedChannels = 0, sampleBits = 0;
  String? recordedPath;
  int asrCalls = 0;
  @override
  void close() {}
  @override
  Future<Uint8List> synthesize(String text) async {
    const n = 24000 * 2 * 5;
    final bytes = Uint8List(44 + n);
    final h = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, ascii.encode('RIFF'));
    h.setUint32(4, n + 36, Endian.little);
    bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, 24000, Endian.little);
    h.setUint32(28, 48000, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    bytes.setRange(36, 40, ascii.encode('data'));
    h.setUint32(40, n, Endian.little);
    return bytes;
  }

  @override
  Future<String> transcribe(File file) async {
    asrCalls++;
    return '本地音频文件已确认';
  }

  Future<void> inspectRecording(File file) async {
    recordedPath = file.path;
    recordedBytes = await file.length();
    final reader = await file.open();
    try {
      // Read only the container metadata. Apple WAV files may have filler chunks.
      final header = await reader.read(12);
      expect(ascii.decode(header.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(header.sublist(8, 12)), 'WAVE');
      while (await reader.position() + 8 <= recordedBytes) {
        final block = await reader.read(8);
        final name = ascii.decode(block.sublist(0, 4));
        final size = ByteData.sublistView(block).getUint32(4, Endian.little);
        if (name == 'fmt ') {
          final format = ByteData.sublistView(await reader.read(16));
          recordedChannels = format.getUint16(2, Endian.little);
          recordedRate = format.getUint32(4, Endian.little);
          sampleBits = format.getUint16(14, Endian.little);
          break;
        }
        await reader.setPosition(await reader.position() + size + (size % 2));
      }
    } finally {
      await reader.close();
    }
  }
}

class _ObservedRecorder extends AudioRecorder {
  _ObservedRecorder(this.inspect);
  final Future<void> Function(File) inspect;
  @override
  Future<String?> stop() async {
    final path = await super.stop();
    if (path != null) await inspect(File(path));
    return path;
  }
}
