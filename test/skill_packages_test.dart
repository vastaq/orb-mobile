import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/skill_packages.dart';
import 'package:orb_mobile/ui/skills.dart';

String doc(String text, {String name = 'reading-note'}) =>
    '---\nname: $name\ndescription: >\n  整理读书摘录，\n  保留原始引文。\n---\n$text\n';

Uint8List package(
  String version, {
  String body = '整理摘录',
  String? url,
  String id = 'reading-note',
  int host = 1,
  List<String> permissions = const [],
  Map<String, String> resources = const {'references/form.md': '# 引文格式'},
}) {
  final a = Archive()
    ..addFile(ArchiveFile.string('reading/SKILL.md', doc(body, name: id)))
    ..addFile(
      ArchiveFile.string(
        'reading/skill.json',
        jsonEncode({
          'format': 'orb-skill',
          'formatVersion': 1,
          'id': id,
          'name': '读书笔记',
          'version': version,
          'minHostVersion': host,
          'permissions': permissions,
          'updateUrl': ?url,
        }),
      ),
    );
  for (final e in resources.entries) {
    a.addFile(ArchiveFile.string('reading/${e.key}', e.value));
  }
  return ZipEncoder().encodeBytes(a);
}

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('orb-skill-'));
  tearDown(() => directory.deleteSync(recursive: true));
  test(
    'imports a standard SKILL.md, preserves frontmatter and desktop edits',
    () {
      final first = decodeSkillPackage(utf8.encode(doc('原文')));
      final next = decodeSkillPackage(utf8.encode(doc('新指令')));
      final lib = SkillLibrary(directory);
      expect(lib.install(first), isTrue);
      expect(lib.install(first), isFalse);
      expect(lib.install(next), isTrue);
      expect(SkillLibrary(directory).enabled(first.id)!.instructions, '新指令');
      final p = decodeSkillPackage(
        package('1.2', url: 'https://example.test/reading.zip'),
      );
      final copy = decodeSkillPackage(encodeSkillPackage(p));
      expect(copy.revision, p.revision);
      expect(copy.references['references/form.md'], '# 引文格式');
      expect(copy.document, p.document);
      final chinese = decodeSkillPackage(
        utf8.encode(doc('记录意象', name: '诗歌-2')),
      );
      expect(lib.install(chinese), isTrue);
      expect(lib.enabled('诗歌-2')!.instructions, '记录意象');
    },
  );
  test(
    'unattended updates require opt-in and preserve old data on failures',
    () async {
      const url = 'https://example.test/reading.zip';
      var count = 0;
      Uint8List? reply;
      final lib = SkillLibrary(
        directory,
        download: (u) async {
          expect(u.toString(), url);
          count++;
          if (reply == null) throw const SocketException('offline');
          return reply;
        },
      );
      lib.install(decodeSkillPackage(package('1.2', url: url)));
      await lib.refreshSubscriptions();
      expect(count, 0);
      lib.configure('reading-note', autoUpdate: true);
      reply = package('1.10', body: '使用新格式', url: url);
      await lib.refreshSubscriptions();
      expect(lib.enabled('reading-note')!.version, '1.10');
      await lib.refreshSubscriptions();
      expect(count, 1);
      reply = null;
      await expectLater(
        lib.update('reading-note'),
        throwsA(isA<SocketException>()),
      );
      expect(lib.get('reading-note')!.previous!.version, '1.2');
      reply = package('2', url: 'https://other.test/reading.zip');
      await expectLater(lib.update('reading-note'), throwsFormatException);
      reply = package('2', url: url, permissions: ['shell']);
      await expectLater(lib.update('reading-note'), throwsFormatException);
      lib.rollback('reading-note');
      final back = SkillLibrary(directory).get('reading-note')!;
      expect(back.current.version, '1.2');
      expect(back.autoUpdate, isFalse);
      expect(back.source.toString(), url);
      lib.configure('reading-note', enabled: false);
      expect(lib.enabled('reading-note'), isNull);
      lib.remove('reading-note');
      expect(lib.list(), isEmpty);
    },
  );
  test('detects forks, changed source and older versions before writing', () {
    final lib = SkillLibrary(directory),
        url = Uri.parse('https://a.test/skill.zip');
    final first = decodeSkillPackage(package('2'));
    lib.install(first, source: url);
    final newUrl = Uri.parse('https://b.test/skill.zip');
    final second = decodeSkillPackage(package('3'));
    expect(() => lib.install(second, source: newUrl), throwsFormatException);
    expect(
      () => lib.install(
        decodeSkillPackage(package('2', body: '替换文本')),
        source: url,
      ),
      throwsFormatException,
    );
    expect(
      () => lib.install(decodeSkillPackage(package('1')), source: url),
      throwsFormatException,
    );
    expect(
      () => decodeSkillPackage(package('9', host: 2)),
      throwsFormatException,
    );
    expect(
      () => decodeSkillPackage(
        package('1', resources: {'scripts/work.sh': 'echo'}),
      ),
      throwsFormatException,
    );
    expect(lib.get(first.id)!.current.revision, first.revision);
    lib.install(second, source: newUrl, replaceSource: true);
    lib.rollback(first.id);
    expect(lib.get(first.id)!.source, url);
  });
  test('deleting an installed skill during a fetch keeps it removed', () async {
    final ready = Completer<Uint8List>();
    const url = 'https://example.test/skill.zip';
    final lib = SkillLibrary(directory, download: (_) => ready.future);
    lib.install(decodeSkillPackage(package('1', url: url)));
    final pending = lib.update('reading-note');
    lib.remove('reading-note');
    ready.complete(package('2', url: url));
    expect(await pending, isFalse);
    expect(lib.list(), isEmpty);
  });
  testWidgets(
    'skill details expose instructions and persist enable and rollback',
    (tester) async {
      final lib = SkillLibrary(directory)
        ..install(decodeSkillPackage(package('1')))
        ..install(decodeSkillPackage(package('2', body: '新版整理要求')));
      await tester.pumpWidget(
        MaterialApp(home: SkillManagerPage(library: lib)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('读书笔记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('技能指令'));
      await tester.pumpAndSettle();
      expect(find.text('新版整理要求'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(lib.enabled('reading-note'), isNull);
      await tester.ensureVisible(find.text('回退到上一版'));
      await tester.tap(find.text('回退到上一版'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('回退'));
      await tester.pumpAndSettle();
      expect(lib.get('reading-note')!.current.version, '1');
    },
  );
}
