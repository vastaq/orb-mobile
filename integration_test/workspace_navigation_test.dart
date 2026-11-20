import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/core/tool_types.dart';
import 'package:orb_mobile/core/workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('search, line reads and exact edits agree on the saved file', (
    _,
  ) async {
    final workspace = await Workspace.open();
    final path =
        'navigation-${DateTime.now().microsecondsSinceEpoch}/notes.txt';
    final longLine = '${'🌿' * 260}检查点=42${'木' * 60}';
    final original = WorkFile(path, '页首\r\n$longLine\r\n重复\r\n重复\r\n');
    await workspace.save(original);
    addTearDown(() => workspace.remove(path));

    Future<Map<String, dynamic>> call(String name, Map<String, dynamic> args) =>
        workspace.run(ChatToolCall(id: 'local', name: name, arguments: args));

    final found = await call('workspace_search', {
      'query': '检查点',
      'prefix': path,
    });
    final hit = (found['matches'] as List).single;
    expect(hit['line'], 2);
    expect(hit['text'], contains('检查点=42'));
    expect((hit['text'] as String).runes.length, lessThanOrEqualTo(200));
    expect(original.text, contains(hit['text'] as String));
    final hash = found['file_hashes'][path];
    expect(hash, original.hash);

    final page = await call('workspace_read', {
      'path': path,
      'start_line': 2,
      'line_count': 2,
    });
    expect(page['text'], '$longLine\r\n重复\r\n');
    expect(page['sha256'], hash);
    // Existing clients start their next page at a Unicode code-point offset.
    final legacy = await call('workspace_read', {'path': path, 'offset': 5});
    expect(legacy['text'], String.fromCharCodes(original.text.runes.skip(5)));

    Future<Map<String, dynamic>> edit(String oldText, String newText) =>
        call('workspace_edit', {
          'path': path,
          'old_text': oldText,
          'new_text': newText,
          'expected_hash': hash,
        });
    await expectLater(
      edit('重复', '改'),
      throwsA(
        predicate((e) {
          final message = e.toString();
          return message.contains('3') && message.contains('4');
        }),
      ),
    );
    expect((await workspace.read(path))?.hash, hash);
    await edit('检查点=42', '检查点=43');
    // A second edit using the old search result must still detect the conflict.
    await expectLater(edit('检查点=43', '检查点=44'), throwsA(anything));
    expect(
      (await workspace.read(path))?.text,
      original.text.replaceFirst('=42', '=43'),
    );

    final huge = WorkFile(path, '第一行🌿\n${'🌿' * 8050}\n尾行\n');
    await workspace.save(huge, previous: (await workspace.read(path))!.hash);
    final clipped = await call('workspace_read', {
      'path': path,
      'start_line': 2,
    });
    expect((clipped['text'] as String).runes.length, 8000);
    final rest = await call('workspace_read', {
      'path': path,
      'offset': clipped['next_offset'],
    });
    expect(
      '${clipped['text']}${rest['text']}',
      huge.text.substring(huge.text.indexOf('\n') + 1),
    );
  });
}
