import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import '../tasks/task_store.dart';
import 'models.dart';
import 'skill_packages.dart';
import 'workspace.dart';

typedef BundleThread = ({OrbThread thread, List<OrbMessage> messages});
typedef BundleMemory = ({String originalHash, String text});
typedef BundleChat = ({String digest, String title, List<OrbMessage> messages});
typedef AssetSnapshot = ({
  List<BundleThread> chats,
  List<OrbMemory> memories,
  List<OrbTask> tasks,
  PromptSettings? prompts,
});
typedef BundleSkill = ({
  SkillPackage package,
  Uri? source,
  bool enabled,
  String? originalRevision,
});

typedef BundleContents = ({
  List<WorkImport> workspace,
  List<BundleSkill> skills,
  List<String> warnings,
  List<BundleChat> chats,
  List<BundleMemory> memories,
  List<OrbTask> tasks,
  PromptSettings? prompts,
});

const maxBundleBytes = 128 * 1024 * 1024;
const _guide = '''# Orb 便携工作目录

先打开 [索引](INDEX.md)。对话、记忆、任务和个人指令均为 UTF-8 文本，附件保留原始字节。任意编辑器或桌面助手均可直接读取。

在 workspace/ 内按原路径编辑，或在其中新建 UTF-8 文件和子目录。工作文件正文就是回传内容。工作区每个文件最多 1 MiB。对话目录中的 INDEX.md 是阅读索引，修改消息请编辑它链接的正文。记忆和任务可以直接编辑对应 Markdown。

.agents/skills/<id>/ 是独立技能目录。SKILL.md 含技能说明，references/ 和 assets/ 存关联资料，skill.json 记录 Orb 扩展信息。修改带版本号的技能时递增 skill.json 中的 version。可在 .agents/skills/ 内加入新的标准技能目录。

回到手机时，将 orb.json 与这些目录一起压缩成 ZIP，从「设置 → 本地资产」导入并选择类别。仅恢复 Orb 自身的结构化记录需要 orb.json。工作文件若两端均已改动，手机保留两份。重新导入同一文件会跳过相同内容。编辑过的对话另存副本。导入的任务初始关闭。删除包内文件不会删除手机原件。密码保护采用 WinZip AES，加密内容，路径、文件名仍可见。
''';

String _link(String title, String path) {
  final label = title
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
  final target = path.split('/').map(Uri.encodeComponent).join('/');
  return '[$label](<$target>)';
}

bool _sensitiveUri(Uri? uri) =>
    uri != null && (uri.hasQuery || uri.userInfo.isNotEmpty || uri.hasFragment);

/// Update links may be signed download URLs. Detach those links at migration
/// and keep the skill itself usable as a local package on the destination.
SkillPackage _portableSkill(SkillPackage package, Uri? subscription) {
  final privateLinks = {
    for (final u in [package.updateUrl, subscription])
      if (_sensitiveUri(u)) u.toString(),
  };
  if (privateLinks.isEmpty) return package;
  String redact(String text) {
    for (final link in privateLinks) {
      text = text.replaceAll(link, '');
    }
    return text;
  }

  final data = package.toJson();
  (data['manifest'] as Map).remove('updateUrl');
  final lines = package.document.split('\n');
  final end = lines.indexWhere((s) => s.trimRight() == '---', 1);
  final front = Map<String, dynamic>.from(
    loadYaml(lines.sublist(1, end).join('\n')) as Map,
  );
  if (front['metadata'] case final Map original) {
    front['metadata'] = Map.from(original)..remove('update-url');
  }
  data['document'] = redact(
    '---\n${jsonEncode(front)}\n---\n${lines.skip(end + 1).join('\n')}',
  );
  data['references'] = {
    for (final e in package.references.entries) e.key: redact(e.value),
  };
  return SkillPackage.fromJson(data);
}

String textDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

Future<Uint8List> encodeAssetBundle(
  AssetSnapshot data, {
  String? password,
  Iterable<WorkFile> workspace = const [],
  Iterable<InstalledSkill> skills = const [],
}) async {
  final archive = Archive(),
      chats = <Object>[],
      notes = <Object>[],
      tasks = <Object>[];
  final seen = <String, String>{};
  final index = StringBuffer('# 资产索引\n\n');
  final chatIndex = StringBuffer('# 对话目录\n\n');
  var total = 0;
  void add(String path, List<int> bytes) {
    total += bytes.length;
    if (total > maxBundleBytes) {
      throw const OrbException('选中内容超过 128 MiB，请分批导出。');
    }
    if (archive.length >= 9999) throw const OrbException('选中文件过多，请分批导出。');
    archive.addFile(ArchiveFile.bytes(path, bytes));
  }

  String markdown(String path, String value) {
    add(path, utf8.encode(value));
    return path;
  }

  for (final (i, chat) in data.chats.indexed) {
    final rows = <Object>[];
    final transcript = StringBuffer(
      '# ${chat.thread.title.replaceAll('\n', ' ')}\n\n',
    );
    chatIndex.writeln('- ${_link(chat.thread.title, '${i + 1}/INDEX.md')}');

    for (final (j, m) in chat.messages.indexed) {
      final media = <Object>[];
      for (final (k, a) in m.attachments.indexed) {
        String? path;
        if (a.localPath != null || a.dataUrl.isNotEmpty) {
          if (a.localPath != null &&
              await File(a.localPath!).length() > maxBundleBytes) {
            throw const OrbException('所选附件超过 128 MiB。');
          }
          final bytes = await a.bytes(),
              hash = sha256.convert(bytes).toString();
          path = seen[hash];
          if (path == null) {
            final ext = RegExp(r'\.([A-Za-z0-9]{1,8})$')
                .firstMatch(a.name)
                ?.group(1);
            path =
                'attachments/${seen.length + 1}${ext == null ? '' : '.$ext'}';
            add(path, bytes);
            seen[hash] = path;
          }
        }
        media.add({
          'name': a.name,
          'mime': a.mime,
          'path': ?path,
          if (a.extractedText != null &&
              (path == null || !a.mime.startsWith('text/')))
            'textPath': markdown(
              'chats/${i + 1}/${j + 1}-${k + 1}-extract.md',
              a.extractedText!,
            ),
        });
      }
      final file = '${j + 1}-${m.role}.md';
      transcript.writeln(
        '- ${_link('${j + 1}. ${m.role == 'user' ? '用户' : '助手'}', file)}',
      );
      for (final a in media.cast<Map>()) {
        if (a['path'] case final String path) {
          transcript.writeln(
            '  - ${_link(a['name'] as String, '../../$path')}',
          );
        }
      }
      rows.add({
        'role': m.role,
        'status': m.status,
        'body': markdown('chats/${i + 1}/${j + 1}-${m.role}.md', m.text),
        'attachments': media,
        if (m.metadata['citations'] case final List refs) 'citations': refs,
      });
    }
    markdown('chats/${i + 1}/INDEX.md', transcript.toString());
    chats.add({'title': chat.thread.title, 'messages': rows});
  }
  if (chats.isNotEmpty) {
    markdown('chats/INDEX.md', chatIndex.toString());
    index.writeln('- ${_link('对话目录（${chats.length}）', 'chats/INDEX.md')}');
  }
  for (final (i, n) in data.memories.indexed) {
    index.writeln('- ${_link('记忆 ${i + 1}', 'memories/${i + 1}.md')}');
    notes.add({
      'body': markdown('memories/${i + 1}.md', n.text),
      'originalHash': textDigest(n.text),
    });
  }
  for (final (i, t) in data.tasks.indexed) {
    index.writeln(
      '- ${_link('任务 · ${t.title}', 'tasks/${i + 1}.md')} · ${t.frequency.name} · ${t.due.toIso8601String()}',
    );
    tasks.add({
      'title': t.title,
      'body': markdown('tasks/${i + 1}.md', t.body),
      'kind': t.kind.name,
      'frequency': t.frequency.name,
      'due': t.due.toUtc().toIso8601String(),
      'enabledAtExport': t.enabled,
    });
  }
  final prompts = data.prompts;
  final profile = prompts == null
      ? null
      : {
          'displayName': prompts.displayName,
          'instructions': markdown(
            'prompts/instructions.md',
            prompts.instructions,
          ),
          'templates': [
            for (final (i, t) in prompts.templates.indexed)
              {
                'id': t.id,
                'name': t.name,
                'body': markdown('prompts/template-${i + 1}.md', t.text),
              },
          ],
        };
  if (prompts != null) {
    index.writeln(
      '- ${_link('${prompts.displayName} · 个人指令', 'prompts/instructions.md')}',
    );
    for (final (i, t) in prompts.templates.indexed) {
      index.writeln(
        '- ${_link('模板 · ${t.name}', 'prompts/template-${i + 1}.md')}',
      );
    }
  }
  final workHashes = <String, String>{};
  for (final f in workspace) {
    final path = workspacePath(f.path);
    final bytes = utf8.encode(f.text);
    if (bytes.length > workspaceFileLimit) {
      throw const OrbException('每个工作文件最多 1 MiB。');
    }
    add('workspace/$path', bytes);
    workHashes[path] = f.hash;
    index.writeln('- ${_link(path, 'workspace/$path')}');
  }
  final skillSettings = <String, Object>{};
  for (final entry in skills) {
    final skill = _portableSkill(entry.current, entry.source),
        dir = '.agents/skills/${entry.current.id}';
    for (final f in ZipDecoder().decodeBytes(encodeSkillPackage(skill))) {
      if (f.isFile) add('$dir/${f.name}', f.content);
    }
    skillSettings[skill.id] = {
      if (!_sensitiveUri(entry.source) &&
          !_sensitiveUri(entry.current.updateUrl))
        'source': ?entry.source?.toString(),
      'enabled': entry.enabled,
      'revision': skill.revision,
    };
    index.writeln('- ${_link('技能 · ${skill.name}', '$dir/SKILL.md')}');
  }
  markdown('INDEX.md', index.toString());
  add(
    'orb.json',
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'orb-assets',
        'version': 2,
        'workspace': workHashes,
        'skills': skillSettings,
        'profile': ?profile,
        'chats': chats,
        'memories': notes,
        'tasks': tasks,
      }),
    ),
  );
  markdown('README.md', _guide);
  return ZipEncoder(password: password).encodeBytes(archive);
}

BundleContents decodeAssetBundle(Uint8List bytes, {String? password}) {
  if (bytes.length > maxBundleBytes + 2 * 1024 * 1024) {
    throw const FormatException('资产包超过 128 MiB，请分批导入。');
  }
  final archive = ZipDecoder().decodeBytes(
    bytes,
    password: password,
    throwOnError: true,
  );
  var files = <String, ArchiveFile>{};
  var total = 0;
  for (final f in archive.files.where((f) => f.isFile)) {
    if (f.name.startsWith('__MACOSX/') ||
        f.name.split('/').last == '.DS_Store') {
      continue;
    }
    total += f.size;
    if (total > maxBundleBytes || files.length >= 10000) {
      throw const FormatException('解压后内容超出限制。');
    }
    if (f.isSymbolicLink ||
        f.name.contains('\\') ||
        f.name.split('/').any((v) => v.isEmpty || v == '.' || v == '..') ||
        files.containsKey(f.name)) {
      throw const FormatException('资产包包含无效路径。');
    }
    files[f.name] = f;
  }
  // Finder and other system archivers wrap a selected directory in its own name.
  if (!files.containsKey('orb.json') && files.isNotEmpty) {
    final root = files.keys.first.split('/').first;
    final prefix = '$root/';
    if (root != 'workspace' &&
        root != '.agents' &&
        files.keys.every((k) => k.startsWith(prefix))) {
      files = {
        for (final e in files.entries) e.key.substring(prefix.length): e.value,
      };
    }
  }
  Uint8List get(Object? path) {
    final entry = files[path];
    if (entry == null) throw FormatException('资产包缺少文件 $path');
    return entry.content;
  }

  String body(Object? path) => utf8.decode(get(path));
  final dynamic manifest;
  if (files.containsKey('orb.json')) {
    manifest = jsonDecode(body('orb.json'));
  } else if (files.keys.any(
    (p) => p.startsWith('workspace/') || p.startsWith('.agents/skills/'),
  )) {
    manifest = {
      'format': 'orb-assets',
      'version': 2,
      'chats': [],
      'tasks': [],
      'memories': [],
    };
  } else {
    throw const FormatException(
      '未找到 orb.json、workspace/ 或 .agents/skills/ 目录。',
    );
  }
  if (manifest is! Map ||
      manifest['format'] != 'orb-assets' ||
      !const {1, 2}.contains(manifest['version'])) {
    throw const FormatException('此资产包版本不受支持。');
  }
  final chats = <BundleChat>[], notes = <BundleMemory>[], tasks = <OrbTask>[];
  for (final c in manifest['chats'] as List) {
    final title = c['title'] as String, messages = <OrbMessage>[];
    final signature = <Object>[title];
    for (final row in c['messages'] as List) {
      final role = row['role'], status = row['status'] ?? 'complete';
      if (!['user', 'assistant'].contains(role) ||
          !['complete', 'stopped', 'interrupted', 'partial'].contains(status)) {
        throw const FormatException('对话角色或状态无效。');
      }
      final text = body(row['body']),
          attachments = <OrbAttachment>[],
          keys = <Object>[];
      for (final a in row['attachments'] as List? ?? []) {
        final raw = a['path'] == null ? null : get(a['path']);
        final extract = a['textPath'] != null
            ? body(a['textPath'])
            : raw != null && (a['mime'] as String).startsWith('text/')
            ? utf8.decode(raw)
            : null;
        final name = a['name'] as String, mime = a['mime'] as String;
        if (!RegExp(r'^[\w.+-]+/[\w.+-]+$').hasMatch(mime)) {
          throw const FormatException('附件类型无效。');
        }
        attachments.add(
          OrbAttachment(
            name: name,
            mime: mime,
            extractedText: extract,
            dataUrl: raw == null
                ? ''
                : 'data:$mime;base64,${base64Encode(raw)}',
          ),
        );
        keys.add([
          name,
          mime,
          if (raw != null) sha256.convert(raw).toString(),
          if (extract != null) textDigest(extract),
        ]);
      }
      final refs = (row['citations'] as List? ?? [])
          .whereType<Map>()
          .where((r) => r['url'] is String)
          .map(
            (r) => {
              'url': r['url'] as String,
              'title': (r['title'] ?? r['url']).toString(),
            },
          )
          .toList();
      messages.add(
        OrbMessage(
          role as String,
          text,
          status: status as String,
          attachments: attachments,
          metadata: {if (refs.isNotEmpty) 'citations': refs},
        ),
      );
      signature.add([role, status, text, keys, refs]);
    }
    if (messages.isNotEmpty) {
      chats.add((
        digest: textDigest(jsonEncode(signature)),
        title: title,
        messages: messages,
      ));
    }
  }
  for (final n in manifest['memories'] as List) {
    final text = body(n['body']).trim();
    if (text.isEmpty || text.runes.length > OrbMemory.maxLength) {
      throw const FormatException('每条记忆需要 1 至 500 个字。');
    }
    notes.add((originalHash: n['originalHash'] as String? ?? '', text: text));
  }
  for (final t in manifest['tasks'] as List) {
    final title = t['title'] as String, text = body(t['body']);
    if (title.trim().isEmpty || text.trim().isEmpty) {
      throw const FormatException('任务名称和内容不能为空。');
    }
    tasks.add(
      OrbTask(
        title: title,
        body: text,
        kind: TaskKind.values.byName(t['kind']),
        frequency: TaskFrequency.values.byName(t['frequency']),
        due: DateTime.parse(t['due']).toLocal(),
        enabled: false,
      ),
    );
  }
  final p = manifest['profile'];
  final prompts = p is Map
      ? PromptSettings.fromJson({
          'displayName': p['displayName'],
          'instructions': body(p['instructions']),
          'templates': [
            for (final t in p['templates'] as List)
              {'id': t['id'], 'name': t['name'], 'text': body(t['body'])},
          ],
        })
      : null;
  final work = <WorkImport>[], skills = <BundleSkill>[], warnings = <String>[];
  final baselines = manifest['workspace'] as Map? ?? const {};
  final settings = manifest['skills'] as Map? ?? const {};
  final skillFolders = <String, Map<String, ArchiveFile>>{};
  final workNames = <String>{};
  for (final item in files.entries) {
    final entry = item.value, name = item.key;
    if (name.startsWith('workspace/')) {
      final path = name.substring('workspace/'.length);
      try {
        if (path != workspacePath(path)) {
          throw const FormatException('路径首尾有空白。');
        }
        if (entry.size > workspaceFileLimit) {
          throw const FormatException('超过 1 MiB。');
        }
        if (!workNames.add(path.toLowerCase())) {
          throw const FormatException('路径大小写冲突。');
        }
        final text = utf8.decode(entry.content);
        if (text.contains('\u0000')) throw const FormatException('不支持二进制工作文件。');
        work.add((
          file: WorkFile(path, text),
          originalHash: baselines[path] as String? ?? '',
        ));
      } on FormatException catch (e) {
        warnings.add('$path · ${e.message}');
      } on OrbException catch (e) {
        warnings.add('$path · ${e.message}');
      }
    } else if (name.startsWith('.agents/skills/')) {
      final parts = name.split('/');
      if (parts.length >= 4) {
        (skillFolders[parts[2]] ??= {})[parts.skip(3).join('/')] = entry;
      }
    }
  }
  for (final group in skillFolders.entries) {
    try {
      var size = 0;
      final bundle = Archive();
      for (final e in group.value.entries) {
        final file = e.value;
        size += file.size;
        if (size > maxSkillBytes || bundle.length >= 40) {
          throw const FormatException('技能过大或文件过多。');
        }
        bundle.addFile(ArchiveFile.bytes(e.key, file.content));
      }
      final package = decodeSkillPackage(ZipEncoder().encodeBytes(bundle));
      if (package.id != group.key) throw const FormatException('目录名与技能 ID 不同。');
      final state = settings[group.key] as Map? ?? const {};
      final source = state['source'] == null
          ? package.updateUrl
          : skillSource(state['source'] as String);
      final portable = _portableSkill(package, source);
      skills.add((
        package: portable,
        source: _sensitiveUri(source) || _sensitiveUri(package.updateUrl)
            ? null
            : source,
        enabled: state['enabled'] != false,
        originalRevision: state['revision'] as String?,
      ));
    } on FormatException catch (e) {
      warnings.add('技能 ${group.key} · ${e.message}');
    }
  }
  return (
    chats: chats,
    memories: notes,
    tasks: tasks,
    prompts: prompts,
    workspace: work,
    skills: skills,
    warnings: warnings,
  );
}

/// Existing switches remain under this device's control. The package's saved
/// enablement is restored only for newly installed skills; subscriptions stay off.
bool restoreBundleSkill(SkillLibrary library, BundleSkill entry) {
  final package = entry.package, old = library.get(entry.package.id);
  if (old != null && old.current.updateUrl != package.updateUrl) {
    throw const FormatException('技能清单的更新来源不同，已保留本机版本。');
  }
  if (old != null &&
      !package.versioned &&
      !old.current.versioned &&
      old.current.revision != package.revision &&
      old.source == entry.source &&
      old.current.revision != entry.originalRevision) {
    if (package.revision == entry.originalRevision) return false;
    throw const FormatException('两端的本地技能都已修改，已保留本机版本。');
  }
  final changed = library.install(package, source: entry.source);
  if (old == null && !entry.enabled) {
    library.configure(package.id, enabled: false);
  }
  return changed;
}

Future<String> localChatDigest(String title, List<OrbMessage> messages) async {
  final signature = <Object>[title];
  for (final m in messages) {
    final keys = <Object>[];
    for (final a in m.attachments) {
      final raw = a.localPath == null
          ? (a.dataUrl.isEmpty ? null : sha256.convert(await a.bytes()))
          : await sha256.bind(File(a.localPath!).openRead()).first;
      keys.add([
        a.name,
        a.mime,
        if (raw != null) raw.toString(),
        if (a.extractedText != null) textDigest(a.extractedText!),
      ]);
    }
    final refs = (m.metadata['citations'] as List? ?? [])
        .whereType<Map>()
        .where((r) => r['url'] is String)
        .map(
          (r) => {
            'url': r['url'],
            'title': (r['title'] ?? r['url']).toString(),
          },
        )
        .toList();
    signature.add([m.role, m.status, m.text, keys, refs]);
  }
  return textDigest(jsonEncode(signature));
}
