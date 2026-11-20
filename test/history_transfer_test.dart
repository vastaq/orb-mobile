import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/history_transfer.dart';
import 'package:orb_mobile/core/models.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('orb-history-test-'));
  tearDown(() => dir.deleteSync(recursive: true));
  const bmp =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/w8AAwMCAOy1Z5sAAAAASUVORK5CYII=';
  final files = [
    {
      'id': 'p',
      'file_name': 'sky.png',
      'is_image': true,
      'export_path': 'chat_sessions/demo_files/p_sky.png',
    },
    {
      'id': 'd',
      'file_name': 'notes.pdf',
      'is_image': false,
      'export_path': null,
    },
  ];
  final modern = {
    'id': 'demo',
    'title': '迁移验收',
    'current_message_id': 3,
    'messages': [
      {
        'id': 1,
        'parent_id': null,
        'role': 'USER',
        'fragments': [
          {'type': 'REQUEST', 'content': '天空是什么颜色？'},
          {'type': 'FILE', 'files': files},
        ],
      },
      {
        'id': 2,
        'parent_id': 1,
        'role': 'ASSISTANT',
        'fragments': [
          {'type': 'RESPONSE', 'content': '旧答案'},
        ],
      },
      {
        'id': 3,
        'parent_id': 1,
        'role': 'ASSISTANT',
        'fragments': [
          {'type': 'THINK', 'content': '注记'},
          {'type': 'RESPONSE', 'content': '蓝色。'},
        ],
      },
    ],
  };
  File zip({bool missingSession = false}) {
    final ar = Archive()
      ..add(
        ArchiveFile.string(
          'archive/manifest.json',
          '{"export_format_version":3}',
        ),
      )
      ..add(
        ArchiveFile.string(
          'archive/chat_session_index.json',
          jsonEncode([
            {'id': 'demo', 'title': '迁移验收', 'message_count': 3},
          ]),
        ),
      )
      ..add(
        ArchiveFile.string('archive/user.json', '{"apiKey":"fixture-secret"}'),
      )
      ..add(
        ArchiveFile.bytes(
          'archive/chat_sessions/demo_files/p_sky.png',
          base64Decode(bmp),
        ),
      );
    if (!missingSession) {
      ar.add(
        ArchiveFile.string(
          'archive/chat_sessions/demo.json',
          jsonEncode(modern),
        ),
      );
    }
    return File('${dir.path}/export.zip')
      ..writeAsBytesSync(ZipEncoder().encode(ar));
  }

  test('v3 ZIP restores selected branch, images and missing-file labels; Markdown contains no settings', () async {
    final path = zip().path;
    final preview = await previewDeepSeekHistory(path);
    expect(preview.single.sourceId, 'deepseek:demo');
    expect(preview.single.messageCount, 3);
    expect(await loadDeepSeekHistory(path, {}), isEmpty);
    final thread = (await loadDeepSeekHistory(path, {'deepseek:demo'})).single;
    expect(thread.otherNodes, 1);
    expect(thread.missingFiles, 1);
    expect(thread.messages.map((m) => m.text), ['天空是什么颜色？', '蓝色。']);
    expect(thread.messages.last.metadata['native']['reasoning_content'], '注记');
    expect(
      thread.messages.first.attachments.first.dataUrl,
      'data:image/png;base64,$bmp',
    );
    expect(thread.messages.first.attachments.last.dataUrl, isEmpty);
    final markdown = await threadMarkdown(thread.title, thread.messages);
    expect(markdown, contains('![sky.png](data:image/png;base64,'));
    expect(markdown, contains('notes.pdf'));
    expect(markdown, contains('蓝色。'));
    expect(markdown, isNot(contains('fixture-secret')));
    expect(markdown, isNot(contains('旧答案')));
  });

  test('legacy mappings follow the ordered main branch; explicit active leaves take precedence', () async {
    final legacy = {
      'id': 'demo',
      'title': '旧对话',
      'mapping': {
        'root': {
          'parent': null,
          'children': ['1'],
          'message': null,
        },
        '1': {
          'parent': 'root',
          'children': ['2', '3'],
          'message': {
            'fragments': [
              {'type': 'REQUEST', 'content': '问题'},
            ],
          },
        },
        '2': {
          'parent': '1',
          'children': [],
          'message': {
            'fragments': [
              {'type': 'RESPONSE', 'content': '甲'},
            ],
          },
        },
        '3': {
          'parent': '1',
          'children': [],
          'message': {
            'fragments': [
              {'type': 'RESPONSE', 'content': '乙'},
            ],
          },
        },
      },
    };
    final file = File('${dir.path}/conversations.json')
      ..writeAsStringSync(jsonEncode([legacy]));
    final notes = await previewDeepSeekHistory(file.path);
    expect(notes.single.messageCount, 3);
    Future<ImportedThread> load() async =>
        (await loadDeepSeekHistory(file.path, {'deepseek:demo'})).single;
    expect((await load()).messages.last.text, '甲');
    legacy['current_node'] = '3';
    file.writeAsStringSync(jsonEncode([legacy]));
    final chosen = await load();
    expect(chosen.messages.last.text, '乙');
    expect(chosen.otherNodes, 1);
  });

  test(
    'share reads persisted image bytes without disclosing private paths',
    () async {
      final image = File('${dir.path}/private.png')
        ..writeAsBytesSync(base64Decode(bmp));
      final text = await threadMarkdown('图', [
        OrbMessage(
          'user',
          '查看',
          attachments: [
            OrbAttachment(
              name: 'sky.png',
              mime: 'image/png',
              localPath: image.path,
            ),
          ],
        ),
      ]);
      expect(text, contains('data:image/png;base64,$bmp'));
      expect(text, isNot(contains(image.path)));
    },
  );

  test('index referencing an absent session fails before import', () async {
    await expectLater(
      previewDeepSeekHistory(zip(missingSession: true).path),
      throwsFormatException,
    );
  });
}
