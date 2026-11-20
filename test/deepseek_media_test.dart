import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orb_mobile/core/deepseek_media.dart';
import 'package:orb_mobile/core/models.dart';
import 'package:orb_mobile/core/recorded_audio.dart';
import 'package:orb_mobile/ui/voice.dart';
import 'package:record/record.dart';

const ds = ModelConfig(apiKey: 'test');
const open = ModelConfig(
  baseUrl: 'https://api.openai.com/v1',
  model: 'test',
  apiKey: 'test',
);
const local = ModelConfig(baseUrl: 'http://127.0.0.1:4432/v1', model: 'local');

Uint8List wavFixture({int samples = 8, int amplitude = 0}) {
  final wav = Uint8List(44 + samples * 2);
  final h = ByteData.sublistView(wav);
  wav.setRange(0, 4, ascii.encode('RIFF'));
  h.setUint32(4, wav.length - 8, Endian.little);
  wav.setRange(8, 16, ascii.encode('WAVEfmt '));
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, 16000, Endian.little);
  h.setUint32(28, 32000, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  wav.setRange(36, 40, ascii.encode('data'));
  h.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    h.setInt16(44 + i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return wav;
}

void main() {
  test('fan noise and an isolated bump stay silent, quiet speech over noise passes', () {
    const count = 64000;
    final room = wavFixture(samples: count);
    final samples = ByteData.sublistView(room);
    final random = Random(10);
    var filtered = 0.0;
    for (int i = 0; i < count; i++) {
      filtered = .79 * filtered + .21 * (random.nextDouble() * 2 - 1);
      final gain = 450 + 350 * sin(2 * pi * i / 10400);
      samples.setInt16(44 + i * 2, (filtered * gain).round(), Endian.little);
    }
    for (var i = 0; i < count; i++) {
      final time = i / 16000;
      final motor =
          (250 + 120 * sin(2 * pi * .7 * time)) *
          (sin(2 * pi * 100 * time) +
              .45 * sin(2 * pi * 200 * time) +
              .22 * sin(2 * pi * 300 * time));
      final offset = 44 + i * 2;
      samples.setInt16(
        offset,
        samples.getInt16(offset, Endian.little) + motor.round(),
        Endian.little,
      );
    }
    samples.setInt16(44 + 20000, 12000, Endian.little);
    expect(hasRecordedSignal(room), false);
    final voice = ByteData.sublistView(
      File('test/fixtures/voice/quiet-speech.wav').readAsBytesSync(),
    );
    for (int i = 44; i + 1 < voice.lengthInBytes; i += 2) {
      samples.setInt16(
        i,
        samples.getInt16(i, Endian.little) + voice.getInt16(i, Endian.little),
        Endian.little,
      );
    }
    expect(hasRecordedSignal(room), true);
  });

  test(
    'ASR silence scores suppress unsupported text and keep supported speech',
    () async {
      final file = File('test/fixtures/voice/quiet-speech.wav');
      final responses = [
        {'text': 'spurious', 'confidence': .02},
        {
          'text': 'spurious',
          'segments': [
            {'text': 'spurious', 'no_speech_prob': .93, 'avg_logprob': -1.9},
          ],
        },
        {
          'text': 'legitimate phrase',
          'segments': [
            {
              'text': 'legitimate phrase',
              'no_speech_prob': .78,
              'avg_logprob': -.18,
            },
          ],
        },
        {
          'text': 'legitimate appended',
          'segments': [
            {'text': 'legitimate', 'confidence': .91},
            {'text': ' appended', 'confidence': .02},
          ],
        },
      ];
      final media = DeepSeekMedia(
        local,
        client: MockClient(
          (r) async => http.Response(jsonEncode(responses.removeAt(0)), 200),
        ),
      );
      addTearDown(media.close);
      for (final wanted in ['', '', 'legitimate phrase', 'legitimate']) {
        expect(await media.transcribe(file), wanted);
      }
    },
  );

  test('rejects a truncated WAV even with HTTP 200', () async {
    final media = DeepSeekMedia(
      ds,
      client: MockClient(
        (_) async => http.Response.bytes(wavFixture().sublist(0, 52), 200),
      ),
    );
    addTearDown(media.close);
    await expectLater(media.synthesize('test'), throwsA(isA<OrbException>()));
  });
  test('DeepSeek ASR, TTS, both OCR modes and standalone search/fetch use documented routes', () async {
    final temp = await Directory.systemTemp.createTemp('orb-media-test-');
    addTearDown(() => temp.delete(recursive: true));
    final file = await File('${temp.path}/sample.wav')
        .writeAsBytes(wavFixture());
    final mimePurposes = <String>[];
    final client = MockClient((r) async {
      expect(r.headers['authorization'], 'Bearer test');
      expect(r.followRedirects, isFalse);
      switch (r.url.path) {
        case '/v1/tools/asr':
          expect(
            latin1.decode(r.bodyBytes),
            contains('name="file"; filename="sample.wav"'),
          );
          expect(latin1.decode(r.bodyBytes), isNot(contains('name="model"')));
          return http.Response(
            jsonEncode({'text': '你好', 'duration_ms': 1000}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        case '/v1/tools/tts':
          expect(jsonDecode(r.body), {
            'text': '测试',
            'format': 'wav',
            'filter_markdown': true,
            'voice_id': 'stella',
          });
          return http.Response.bytes(wavFixture(), 200);
        case '/v1/tools/ocr':
          expect(
            latin1.decode(r.bodyBytes).indexOf('name="purpose"'),
            lessThan(latin1.decode(r.bodyBytes).indexOf('name="file"')),
          );
          mimePurposes.add(
            latin1.decode(r.bodyBytes).contains('rich_layout_recognition')
                ? 'rich'
                : 'text',
          );
          return http.Response(
            jsonEncode({
              'pages': [
                {'text': '第一行', 'finish_reason': 'stop'},
                {'text': '第二页', 'finish_reason': 'length'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        case '/v1/tools/search':
          expect(jsonDecode(r.body)['query'], '测试');
          return http.Response(
            '{"results":[{"title":"Match","url":"https://example.test","snippet":"found"}]}',
            200,
          );
        case '/v1/tools/fetch':
          expect(jsonDecode(r.body)['url'], 'https://example.test');
          return http.Response('{"title":"Page","content":"body"}', 200);
        default:
          fail('wrong endpoint');
      }
    });
    final service = DeepSeekMedia(ds, client: client);
    addTearDown(service.close);
    expect(await service.transcribe(file), '你好');
    expect(await service.synthesize('测试'), wavFixture());
    expect(await service.ocr(file), contains('第二页'));
    expect(await service.ocr(file, rich: true), contains('长度上限'));
    expect(mimePurposes, ['text', 'rich']);
    expect(await service.search('测试'), contains('https://example.test'));
    expect(await service.fetch('https://example.test'), contains('body'));
  });

  test(
    'custom LAN ASR and TTS use the configured origin and no bearer',
    () async {
      final temp = await Directory.systemTemp.createTemp('orb-custom-audio-');
      addTearDown(() => temp.delete(recursive: true));
      final file = await File('${temp.path}/record.wav')
          .writeAsBytes(wavFixture());
      final client = MockClient((r) async {
        expect(r.headers['authorization'], isNull);
        expect(r.url.host, '127.0.0.1');
        expect(r.url.port, 4432);
        if (r.url.path == '/v1/audio/transcriptions') {
          expect(latin1.decode(r.bodyBytes), contains('whisper-1'));
          return http.Response('{"text":"ok"}', 200);
        }
        expect(r.url.path, '/v1/audio/speech');
        expect(jsonDecode(r.body)['response_format'], 'wav');
        return http.Response.bytes(wavFixture(), 200);
      });
      final s = DeepSeekMedia(local, client: client);
      addTearDown(s.close);
      expect(await s.transcribe(file), 'ok');
      expect(await s.synthesize('hi'), wavFixture());
      await expectLater(s.ocr(file), throwsA(isA<OrbException>()));
    },
  );

  test('OpenAI realtime PCM events yield mono 24 kHz WAV; transcription uses the current model', () async {
    final temp = await Directory.systemTemp.createTemp('orb-audio-');
    addTearDown(() => temp.delete(recursive: true));
    final file = await File('${temp.path}/record.wav')
        .writeAsBytes(wavFixture());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final pcm = Uint8List.fromList([1, 0, 2, 0]);
    server.listen((r) async {
      final ws = await WebSocketTransformer.upgrade(r);
      ws.listen((raw) {
        final event = jsonDecode(raw as String);
        expect(event['type'], 'response.create');
        expect(event['response']['audio']['output']['format']['rate'], 24000);
        expect(event['response']['input'][0]['content'][0]['text'], 'hello');
        ws.add(
          jsonEncode({
            'type': 'response.output_audio.delta',
            'delta': base64Encode(pcm),
          }),
        );
        ws.add('{"type":"response.done","response":{"status":"completed"}}');
      });
    });
    final s = DeepSeekMedia(
      open,
      client: MockClient((req) async {
        expect(req.url.path, '/v1/audio/transcriptions');
        expect(latin1.decode(req.bodyBytes), contains('gpt-transcribe'));
        return http.Response('{"text":"ok"}', 200);
      }),
      connect: (uri, headers) {
        expect(uri.host, 'api.openai.com');
        expect(uri.queryParameters['model'], 'gpt-realtime-2.1-mini');
        return WebSocket.connect('ws://127.0.0.1:${server.port}');
      },
    );
    addTearDown(s.close);
    expect(await s.transcribe(file), 'ok');
    final wav = await s.synthesize('hello');
    expect(wav.sublist(44), pcm);
    expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 24000);
  });

  test('pressing while speech plays stops the player, records next turn and removes transient audio', () async {
    final temp = await Directory.systemTemp.createTemp('orb-interrupt-');
    addTearDown(() => temp.delete(recursive: true));
    final p = _Player();
    final r = _Recorder();
    final session = VoiceSession(
      createRecorder: () => r,
      createPlayer: () => p,
      temporaryDirectory: () async => temp,
      createMedia: (config) => DeepSeekMedia(
        config,
        client: MockClient(
          (req) async => req.url.path.endsWith('speech')
              ? http.Response.bytes(wavFixture(), 200)
              : http.Response('{"text":"next turn"}', 200),
        ),
      ),
    );
    addTearDown(session.dispose);
    final speaking = session.speak(local, 'hello');
    await p.began.future;
    expect(session.phase, VoicePhase.speaking);
    await session.startListening(local);
    await speaking;
    expect(p.stopped, isTrue);
    expect(r.started, isTrue);
    expect(session.phase, VoicePhase.listening);
    expect(await session.releaseAndTranscribe(), 'next turn');
    expect(session.phase, VoicePhase.idle);
    expect(await temp.list().toList(), isEmpty);
  });

  test(
    'empty input stays idle before ASR and a quiet retry keeps its transcript',
    () async {
      final temp = await Directory.systemTemp.createTemp('orb-quiet-retry-');
      addTearDown(() => temp.delete(recursive: true));
      final quiet = File('test/fixtures/voice/quiet-speech.wav')
          .readAsBytesSync();
      final samples = [
        <int>[],
        wavFixture(samples: 0),
        wavFixture(samples: 16000),
        wavFixture(samples: 3200, amplitude: 2),
        quiet,
        quiet,
        quiet,
      ];
      final replies = ['   ', '[BLANK_AUDIO]', '  很轻的声音  '];
      var calls = 0;
      final session = VoiceSession(
        createRecorder: () => _Recorder(data: samples.removeAt(0)),
        temporaryDirectory: () async => temp,
        createMedia: (c) => DeepSeekMedia(
          c,
          client: MockClient((r) async {
            calls++;
            return http.Response.bytes(
              utf8.encode(jsonEncode({'text': replies.removeAt(0)})),
              200,
            );
          }),
        ),
      );
      addTearDown(session.dispose);
      for (var attempt = 0; attempt < 7; attempt++) {
        await session.startListening(local);
        expect(
          await session.releaseAndTranscribe(),
          attempt == 6 ? '很轻的声音' : null,
        );
        expect(session.phase, VoicePhase.idle);
        expect(session.error, isNull);
        expect(calls, attempt < 4 ? 0 : attempt - 3);
        expect(await temp.list().isEmpty, isTrue);
      }
    },
  );

  test('a cancelled recording ignores late transcriptions', () async {
    final temp = await Directory.systemTemp.createTemp('orb-late-asr-');
    addTearDown(() => temp.delete(recursive: true));
    final sent = Completer<void>();
    final response = Completer<http.Response>();
    final session = VoiceSession(
      createRecorder: () => _Recorder(),
      temporaryDirectory: () async => temp,
      createMedia: (c) => DeepSeekMedia(
        c,
        client: MockClient((req) {
          sent.complete();
          return response.future;
        }),
      ),
    );
    addTearDown(session.dispose);
    await session.startListening(local);
    final pending = session.releaseAndTranscribe();
    await sent.future;
    await session.interrupt();
    response.complete(http.Response('{"text":"stale"}', 200));
    expect(await pending, isNull);
    expect(session.phase, VoicePhase.idle);
  });
}

class _Recorder extends Fake implements AudioRecorder {
  _Recorder({this.data});
  final List<int>? data;
  bool started = false;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    expect(config.encoder, AudioEncoder.wav);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    await File(path).writeAsBytes(
      data ?? File('test/fixtures/voice/quiet-speech.wav').readAsBytesSync(),
    );
    started = true;
  }

  @override
  Future<String?> stop() async => null;
  @override
  Future<void> dispose() async {}
}

class _Player extends Fake implements AudioPlayer {
  final began = Completer<void>();
  bool stopped = false;
  final events = StreamController<void>.broadcast();
  @override
  Stream<void> get onPlayerComplete => events.stream;
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    expect(source, isA<DeviceFileSource>());
    began.complete();
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() => events.close();
}
