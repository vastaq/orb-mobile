import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/core/orb_store.dart';
import 'package:orb_mobile/main.dart';

const _base = String.fromEnvironment('ORB_TEST_BASE_URL');
const _model = String.fromEnvironment('ORB_TEST_MODEL');
const _vision = String.fromEnvironment('ORB_TEST_VISION_URL');
const _visionModel = String.fromEnvironment('ORB_TEST_VISION_MODEL');
const _screenshots = bool.fromEnvironment('ORB_TEST_SCREENSHOTS');

/// Replaces only the OS selection dialog; Orb reads real files and sends them
/// over HTTP to the explicitly selected local model.
class _Selection extends FilePickerPlatform {
  late File next;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _Picked(next);
}

final class _Picked extends PlatformFile {
  _Picked(this.file);
  final File file;
  @override
  String get name => file.uri.pathSegments.last;
  @override
  Uri get uri => file.uri;
  @override
  XFile get xFile => XFile(file.path);
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['memory and continuation', 'document and image']) {
    testWidgets(
      'real model: $scenario',
      (tester) async {
        final store = OrbStore();
        final orb = OrbController(store: store);
        Future<void> until(bool Function() check, String what) async {
          final clock = Stopwatch()..start();
          while (!check() && clock.elapsed < const Duration(seconds: 90)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(check(), isTrue, reason: '$what ${orb.error ?? ''}');
        }

        Future<void> tap(Finder target) async {
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        Future<void> capture(String name) async {
          if (!_screenshots) return;
          final bytes = await binding.takeScreenshot(name);
          await File('${Directory.systemTemp.path}/orb-uat-$name.png')
              .writeAsBytes(bytes);
        }

        Future<void> newThread() async {
          await tap(find.byTooltip('新对话'));
          await until(
            () => orb.activeId == null && orb.messages.isEmpty,
            '新对话已切换',
          );
          await tester.pump(const Duration(milliseconds: 100));
        }

        final field = find.byKey(const ValueKey('composer'));
        Future<void> send(String text) async {
          await tester.tap(field);
          await tester.pump(const Duration(milliseconds: 320));
          await tester.showKeyboard(field);
          await tester.enterText(field, text);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.text,
            text,
            reason: '输入内容已留在当前草稿',
          );
          final send = find.byKey(const ValueKey('send'));
          await tester.ensureVisible(send);
          final oldCount = orb.messages.length;
          expect(
            tester.widget<IconButton>(send).onPressed,
            isNotNull,
            reason: '草稿已就绪',
          );
          await tester.tap(send);
          await until(
            () =>
                orb.error != null ||
                !orb.busy && orb.messages.length >= oldCount + 2,
            '模型完成回复',
          );
          expect(orb.error, isNull);
          expect(orb.messages.last.status, 'complete');
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(OrbApp(controller: orb));
        await until(() => orb.ready, '初始化本地数据库');
        final original = orb.config;
        await orb.saveConfig(const ModelConfig(baseUrl: _base, model: _model));
        final oldAuto = orb.autoMemoryEnabled;
        await orb.setAutoMemoryEnabled(true);
        const earlierFixtures = {
          '习惯周末去北岸蓝梭书屋看书。',
          '我周末习惯去北岸蓝桥书屋看书。',
          '我周末习惯去北岸蓝桥书屋看书',
          '我每天早上都喝无糖咖啡。',
          '我每天早上都喝无糖咖啡',
        };
        for (final m in [...orb.memories]) {
          if (scenario == 'memory and continuation' &&
              m.isAutomatic &&
              earlierFixtures.contains(m.text)) {
            await orb.removeMemory(m.id);
          }
        }
        final dir = await Directory.systemTemp.createTemp('orb-rich-');
        final nativePicker = FilePickerPlatform.instance,
            selection = _Selection();
        FilePickerPlatform.instance = selection;
        addTearDown(() async {
          FilePickerPlatform.instance = nativePicker;
          await dir.delete(recursive: true);
          // A fresh installation may have an intentionally unconfigured profile.
          await store.saveConfig(original);
          await orb.setAutoMemoryEnabled(oldAuto);
        });
        Future<void> select(File file) async {
          selection.next = file;
          final before = orb.messages.length;
          await tap(find.byTooltip('添加工具或附件'));
          await tap(find.text('文件'));
          await until(
            () => find.text(file.uri.pathSegments.last).evaluate().isNotEmpty,
            '附件草稿出现',
          );
          expect(orb.messages.length, before);
        }

        if (scenario == 'memory and continuation') {
          await newThread();
          await send('我每天早上都喝无糖咖啡。');
          await until(() => !orb.remembering, '自动记忆完成');
          expect(
            orb.memories.any((m) => m.isAutomatic && m.text.contains('无糖咖啡')),
            isTrue,
          );
          await newThread();
          await send('我每天早上习惯喝什么？只回答饮品名。');
          expect(orb.messages.last.text, contains('无糖咖啡'));
          final songIds = orb.memories
              .where((m) => m.text.contains('晚风来信'))
              .map((m) => m.id);
          final snapshot = orb.messages.last.metadata['context'] as Map;
          expect(
            (snapshot['memoryIds'] as List).where(songIds.contains),
            isEmpty,
          );
          await capture('auto-recall');
          final before = orb.messages.last.text;
          await tap(find.byTooltip('回复操作').last);
          await tester.tap(find.text('继续写'));
          await until(
            () =>
                orb.error != null ||
                !orb.busy && orb.messages.last.text.length > before.length,
            '续写追加输出',
          );
          expect(orb.error, isNull);
          expect(orb.messages.length, 2);
          expect(orb.messages.last.text, startsWith(before));
          await tester.pumpAndSettle();
          await capture('continuation');
          return;
        }
        await newThread();
        final note = await File('${dir.path}/note.txt')
            .writeAsString('记事册：今晚工坊的暗号是七号松塔。');
        await select(note);
        await send('文件里写的工坊暗号是什么？只给出暗号。');
        expect(orb.messages.last.text, contains('七号松塔'));
        expect(
          orb.messages.first.attachments.single.extractedText,
          contains('七号松塔'),
        );
        await capture('document');
        await until(() => !orb.remembering, '等待附加任务完成');
        await orb.saveConfig(
          const ModelConfig(baseUrl: _vision, model: _visionModel),
        );
        await newThread();
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)
          ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
        canvas.drawCircle(
          const ui.Offset(90, 90),
          55,
          ui.Paint()..color = const ui.Color(0xff003cff),
        );
        final pic = recorder.endRecording(), img = await pic.toImage(180, 180);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        final file = await File('${dir.path}/shape.png').writeAsBytes(
          png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
        img.dispose();
        pic.dispose();
        await select(file);
        await capture('image-draft');
        await send('图中间是什么颜色、什么形状？只回答颜色和形状。');
        expect(orb.messages.last.text, allOf(contains('蓝'), contains('圆')));
        expect(orb.messages.first.attachments.single.isImage, isTrue);
        await capture('vision');
      },
      skip: [
        _base,
        _model,
        if (scenario == 'document and image') ...[_vision, _visionModel],
      ].any((s) => s.isEmpty),
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
}
