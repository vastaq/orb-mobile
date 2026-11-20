import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/mobile_tools.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/ui/compose_tools.dart';

void main() {
  test('document preparation preserves requested parsing, actual local text and source image type', () async {
    final temp = await Directory.systemTemp.createTemp('orb-selected-file-');
    addTearDown(() => temp.delete(recursive: true));
    final doc = await File('${temp.path}/report.pdf')
        .writeAsString('document data');
    final attach = await pickedAttachment(
      doc,
      'report.pdf',
      ModelConfig.deepSeek,
      purpose: 'rich_layout_recognition',
    );
    expect(attach.purpose, 'rich_layout_recognition');
    expect(attach.localPath, doc.path);
    expect(
      (await pickedAttachment(
        doc,
        'slides.PPTX',
        ModelConfig.deepSeek,
      )).purpose,
      'rich_layout_recognition',
    );
    expect(
      (await pickedAttachment(doc, 'report.pdf', ModelConfig.deepSeek)).purpose,
      'text_recognition',
    );
    final csv = await File('${temp.path}/notes.csv')
        .writeAsString('日期,记录\n周二,晴');
    expect(
      (await pickedAttachment(
        csv,
        'notes.csv',
        ModelConfig.deepSeek,
      )).extractedText,
      contains('周二,晴'),
    );
    final image = await File('${temp.path}/camera')
        .writeAsBytes([0x89, 0x50, 0x4e, 0x47, 0x1a, 0x0a]);
    expect(
      (await pickedAttachment(
        image,
        'camera',
        ModelConfig.deepSeek,
        image: true,
      )).mime,
      'image/png',
    );
    expect(
      (await pickedAttachment(doc, 'book.epub', ModelConfig.deepSeek)).purpose,
      'user_data',
    );
  });
  test('slash command matching leaves unrelated draft text untouched', () {
    expect(MobileCommand.parse('/new'), MobileCommand.newChat);
    expect(MobileCommand.parse('/memory 喜欢简短回答'), MobileCommand.memory);
    expect(MobileCommand.parse('/new 这只是文件名'), isNull);
    expect(MobileCommand.parse('/tmp/file'), isNull);
    expect(
      localTimeText(DateTime.utc(2026, 11, 20, 12, 31)),
      contains('星期五 12:31 UTC+00:00'),
    );
  });
  testWidgets(
    'tool sheet inserts a time locally; custom provider hides DeepSeek-only actions',
    (t) async {
      final controller = OrbController()
        ..config = const ModelConfig(
          baseUrl: 'http://127.0.0.1:18318/v1',
          model: 'local',
        );
      addTearDown(controller.dispose);
      ComposerResult? returned;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    returned = await openComposeTools(context, controller);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      for (final label in ['照片', '拍照', '文件', '更多输入']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('提示模板'), findsNothing);
      await t.tap(find.text('更多输入'));
      await t.pumpAndSettle();
      expect(find.text('从文件或网页插入'), findsNothing);
      await t.tap(find.text('快捷指令'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('插入当前时间'));
      await t.tap(find.text('插入当前时间'));
      await t.pumpAndSettle();
      expect(returned?.text, contains('UTC'));
      expect(controller.messages, isEmpty);
    },
  );
}
