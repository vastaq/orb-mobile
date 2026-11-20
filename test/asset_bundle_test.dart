import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/asset_bundle.dart';
import 'package:orb_mobile/core/models.dart';
import 'package:orb_mobile/core/skill_packages.dart';
import 'package:orb_mobile/core/workspace.dart';
import 'package:orb_mobile/tasks/task_store.dart';

void main() {
  final file = OrbAttachment(
    name: '参考.txt',
    mime: 'text/plain',
    dataUrl: 'data:text/plain;base64,${base64Encode(utf8.encode('原件'))}',
    extractedText: '原件',
    fileId: 'private-provider-id',
  );
  final input = (
    chats: <BundleThread>[
      (
        thread: const OrbThread('1', '写作'),
        messages: [
          OrbMessage('user', '看一下', attachments: [file]),
          const OrbMessage('assistant', '已读'),
        ],
      ),
    ],
    memories: [const OrbMemory('1', '喜欢短句')],
    tasks: [
      OrbTask(
        title: '阅读',
        body: '整理摘录',
        kind: TaskKind.prompt,
        frequency: TaskFrequency.daily,
        due: DateTime.utc(2030, 1),
      ),
    ],
    prompts: const PromptSettings(
      displayName: '枝',
      instructions: '使用短句',
      templates: [PromptTemplate(id: 'rev', name: '复核', text: '请复核以下内容。')],
    ),
  );
  test('desktop edits portable Markdown and unchanged chat has the local fingerprint', () async {
    final raw = await encodeAssetBundle(input);
    final archive = ZipDecoder().decodeBytes(raw);
    final manifest = utf8.decode(archive.findFile('orb.json')!.content);
    expect(manifest, isNot(contains('private-provider-id')));
    expect(
      decodeAssetBundle(raw).chats.single.digest,
      await localChatDigest('写作', input.chats.single.messages),
    );
    final changed = Archive();
    for (final f in archive) {
      changed.addFile(
        f.name == 'memories/1.md' ? ArchiveFile.string(f.name, '偏爱短篇') : f,
      );
    }
    final imported = decodeAssetBundle(ZipEncoder().encodeBytes(changed));
    expect(imported.memories.single, (
      text: '偏爱短篇',
      originalHash: textDigest('喜欢短句'),
    ));
    expect(imported.tasks.single.enabled, isFalse);
    expect(imported.prompts!.templates.single.text, '请复核以下内容。');
    expect(
      utf8.decode(
        await imported.chats.single.messages.first.attachments.first.bytes(),
      ),
      '原件',
    );
  });
  test('password is required for encrypted bundles', () async {
    final raw = await encodeAssetBundle(
      input,
      password: 'public-test-password',
    );
    expect(
      () => decodeAssetBundle(raw),
      throwsA(isA<ArchivePasswordException>()),
    );
    expect(
      () => decodeAssetBundle(raw, password: 'wrong'),
      throwsA(isA<ArchivePasswordException>()),
    );
    expect(
      decodeAssetBundle(
        raw,
        password: 'public-test-password',
      ).memories.single.text,
      '喜欢短句',
    );
  });
  test('reads a v1 ZIP authored without the v2 encoder', () {
    final old = Archive()
      ..addFile(
        ArchiveFile.string(
          'orb.json',
          jsonEncode({
            'version': 1,
            'format': 'orb-assets',
            'chats': [],
            'tasks': [],
            'memories': [
              {'body': 'memories/1.md', 'originalHash': 'before'},
            ],
          }),
        ),
      )
      ..addFile(ArchiveFile.string('memories/1.md', '旧手机的笔记'));
    final content = decodeAssetBundle(ZipEncoder().encodeBytes(old));
    expect(content.memories.single, (originalHash: 'before', text: '旧手机的笔记'));
    expect(content.workspace, isEmpty);
    expect(content.skills, isEmpty);
  });

  const skillDoc = '---\nname: reading-note\ndescription: 整理摘录\n---\n按引文与想法组织。';
  SkillPackage skill(String version, {String? source, String doc = skillDoc}) {
    final archive = Archive()
      ..addFile(ArchiveFile.string('SKILL.md', doc))
      ..addFile(
        ArchiveFile.string(
          'skill.json',
          jsonEncode({
            'format': 'orb-skill',
            'formatVersion': 1,
            'name': '读书笔记',
            'id': 'reading-note',
            'version': version,
            'updateUrl': ?source,
          }),
        ),
      )
      ..addFile(ArchiveFile.string('references/example.md', '# 引文'))
      ..addFile(ArchiveFile.string('assets/template.txt', '引文：'));
    return decodeSkillPackage(ZipEncoder().encodeBytes(archive));
  }

  test('exports desktop-readable indexes, editable nested files, and standalone Agent Skills', () async {
    const path = '读书/周五.md', url = 'https://reader.example/skill.zip';
    final installed = InstalledSkill(
      current: skill('1.2', source: url),
      source: Uri.parse(url),
      enabled: false,
      autoUpdate: true,
    );
    final encoded = await encodeAssetBundle(
      input,
      workspace: [const WorkFile(path, '原文')],
      skills: [installed],
    );
    final zip = ZipDecoder().decodeBytes(encoded);
    String text(String name) => utf8.decode(zip.findFile(name)!.content);
    expect(text('INDEX.md'), contains('chats/INDEX.md'));
    expect(text('chats/1/INDEX.md'), contains('1-user.md'));
    expect(text('chats/1/INDEX.md'), contains('../../attachments/1.txt'));
    expect(
      text('.agents/skills/reading-note/SKILL.md'),
      contains('name: reading-note'),
    );
    expect(text('.agents/skills/reading-note/references/example.md'), '# 引文');
    expect(text('.agents/skills/reading-note/assets/template.txt'), '引文：');
    final desktop = Archive();
    for (final f in zip) {
      desktop.addFile(
        ArchiveFile.bytes(
          '我的资料/${f.name}',
          f.name == 'workspace/$path' ? utf8.encode('桌面改稿') : f.content,
        ),
      );
    }
    desktop.addFile(ArchiveFile.string('我的资料/workspace/读书/下次.md', '新建'));
    final imported = decodeAssetBundle(ZipEncoder().encodeBytes(desktop));
    expect(imported.workspace.first.originalHash, textDigest('原文'));
    expect(imported.workspace.first.file.text, '桌面改稿');
    expect(imported.workspace.last.originalHash, '');
    expect(imported.workspace.last.file.path, '读书/下次.md');
    expect(imported.skills.single.package.revision, installed.current.revision);
    final dir = Directory.systemTemp.createTempSync('orb-migrate-skill');
    addTearDown(() => dir.deleteSync(recursive: true));
    final library = SkillLibrary(dir), pack = imported.skills.single;
    expect(restoreBundleSkill(library, pack), true);
    expect(library.get('reading-note')!.enabled, false);
    expect(library.get('reading-note')!.autoUpdate, false);
    expect(restoreBundleSkill(library, pack), false);
    final next = skill('2.0', source: url);
    library.install(next);
    expect(() => restoreBundleSkill(library, pack), throwsFormatException);
    expect(library.get('reading-note')!.current.version, '2.0');
    final other = (
      package: skill('3.0', source: 'https://other.example/s.zip'),
      source: Uri.parse('https://other.example/s.zip'),
      enabled: true,
      originalRevision: null as String?,
    );
    expect(() => restoreBundleSkill(library, other), throwsFormatException);
    expect(library.get('reading-note')!.source, Uri.parse(url));
  });

  test('detaches signed subscription URLs in the standalone manifest and skill frontmatter', () async {
    const link = 'https://reader.example/bundle?signature=never-export-this',
        second = 'https://other.example/s?token=private-subscription';
    final doc =
        '---\nname: reading-note\ndescription: 整理摘录\nmetadata:\n  update-url: $link\n---\n资料整理。';
    final installed = InstalledSkill(
      current: skill('1.2', source: link, doc: doc),
      source: Uri.parse(second),
    );
    final raw = await encodeAssetBundle(input, skills: [installed]);
    final zip = ZipDecoder().decodeBytes(raw);
    final files = zip
        .where((f) => f.isFile)
        .map((f) => utf8.decode(f.content))
        .join('\n');
    expect(files, isNot(contains('never-export-this')));
    expect(files, isNot(contains('private-subscription')));
    final copy = decodeAssetBundle(raw).skills.single;
    expect(copy.source, isNull);
    expect(copy.package.updateUrl, isNull);
    expect(copy.package.instructions, '资料整理。');
  });

  test('discovers files and skills from an ordinary desktop zip without Orb metadata', () {
    final a = Archive()
      ..addFile(ArchiveFile.string('project/workspace/new.txt', '新增'))
      ..addFile(
        ArchiveFile.string(
          'project/.agents/skills/reading-note/SKILL.md',
          skillDoc,
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'project/.agents/skills/damaged/SKILL.md',
          'no frontmatter',
        ),
      )
      ..addFile(ArchiveFile.bytes('project/workspace/binary.bin', [0, 200]));
    final content = decodeAssetBundle(ZipEncoder().encodeBytes(a));
    expect(content.workspace.single.file.path, 'new.txt');
    expect(content.skills.single.package.id, 'reading-note');
    expect(content.warnings, hasLength(2));
  });
  test('rejects unsupported format before importing', () {
    final a = Archive()
      ..addFile(
        ArchiveFile.string('orb.json', '{"format":"orb-assets","version":99}'),
      );
    expect(
      () => decodeAssetBundle(Uint8List.fromList(ZipEncoder().encodeBytes(a))),
      throwsFormatException,
    );
  });
}
