import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'package:yaml/yaml.dart';

const maxSkillBytes = 1024 * 1024;
const skillHostVersion = 1;

final _idPattern = RegExp(
  r'^[\p{Ll}\p{Lo}\p{Lm}\p{Nd}]+(?:-[\p{Ll}\p{Lo}\p{Lm}\p{Nd}]+)*$',
  unicode: true,
);
final _versionPattern = RegExp(
  r'^(0|[1-9][0-9]{0,7})(\.(0|[1-9][0-9]{0,7})){0,2}$',
);

String _id(Object? raw) {
  if (raw is! String ||
      raw.isEmpty ||
      raw.runes.length > 64 ||
      !_idPattern.hasMatch(raw)) {
    throw const FormatException('技能 ID 可用小写字母、汉字、数字和连字符，最长 64 字符。');
  }
  return raw;
}

Uri skillSource(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('请使用指向技能文件的 HTTPS 地址。');
  }
  return uri;
}

String _text(Object? raw, String name, int limit) {
  if (raw is! String || raw.trim().isEmpty || raw.length > limit) {
    throw FormatException('技能的$name为空或超出了长度限制。');
  }
  return raw.trim();
}

int _compareVersions(String lhs, String rhs) {
  final a = lhs.split('.').map(int.parse).toList();
  final b = rhs.split('.').map(int.parse).toList();
  for (int i = 0; i < 3; i++) {
    final order = (a.elementAtOrNull(i) ?? 0).compareTo(
      b.elementAtOrNull(i) ?? 0,
    );
    if (order != 0) return order;
  }
  return 0;
}

class SkillPackage {
  const SkillPackage._(
    this.id,
    this.name,
    this.description,
    this.version,
    this.instructions,
    this.document,
    this.updateUrl,
    this.references,
    this.versioned,
  );

  final String id, name, description, version, instructions, document;
  final Uri? updateUrl;
  final Map<String, String> references;
  final bool versioned;

  String get revision =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
  String get versionLabel =>
      versioned ? version : '本地稿 · ${revision.substring(0, 7)}';

  Map<String, dynamic> get _manifest => {
    'format': 'orb-skill',
    'formatVersion': 1,
    'id': id,
    'name': name,
    if (versioned) 'version': version,
    'minHostVersion': 1,
    if (updateUrl != null) 'updateUrl': updateUrl.toString(),
  };
  Map<String, dynamic> toJson() => {
    'manifest': _manifest,
    'document': document,
    'references': {
      for (final k in references.keys.toList()..sort()) k: references[k],
    },
  };

  static SkillPackage fromJson(Map json) => _parse(
    json['document'] as String,
    json['manifest'] as Map,
    Map<String, String>.from(json['references'] as Map),
  );
}

SkillPackage _parse(String raw, Map manifest, Map<String, String> references) {
  if (manifest.isNotEmpty &&
      (manifest['format'] != 'orb-skill' || manifest['formatVersion'] != 1)) {
    throw const FormatException('此技能包的格式版本不受支持。');
  }
  final host = manifest['minHostVersion'] ?? 1;
  if (host is! int || host < 1 || host > skillHostVersion) {
    throw const FormatException('此技能需要更高版本的 Orb。');
  }
  final doc = raw.replaceFirst(RegExp('^\uFEFF'), '').replaceAll('\r\n', '\n');
  final lines = doc.split('\n');
  if (lines.first.trim() != '---') {
    throw const FormatException('SKILL.md 缺少 YAML 信息头（name 与 description）。');
  }
  final end = lines.indexWhere((l) => l.trimRight() == '---', 1);
  if (end < 1) throw const FormatException('SKILL.md 的 YAML 信息头缺少结束行。');
  dynamic front;
  try {
    front = loadYaml(lines.sublist(1, end).join('\n'));
  } on YamlException {
    throw const FormatException('SKILL.md 的 YAML 信息头无效。');
  }
  if (front is! Map) throw const FormatException('SKILL.md 的 YAML 信息头无效。');
  final metadata = front['metadata'] is Map
      ? front['metadata'] as Map
      : const {};
  final rawPermissions = manifest['permissions'];
  final allowedTools = front['allowed-tools'];
  if (rawPermissions != null &&
          !(rawPermissions is List && rawPermissions.isEmpty) ||
      allowedTools != null && allowedTools.toString().trim().isNotEmpty) {
    throw const FormatException('此技能申请了额外工具权限，当前手机宿主不支持安装该版本。');
  }
  final id = _id(manifest['id'] ?? front['name']);
  _text(front['name'], 'name', 64);
  final name = _text(
    manifest['name'] ?? metadata['display-name'] ?? front['name'],
    '名称',
    96,
  );
  final description = _text(front['description'], '说明', 1024);
  final value = manifest['version'] ?? metadata['version'];
  final version = value?.toString() ?? '0';
  if (!_versionPattern.hasMatch(version)) {
    throw const FormatException('版本应为 1、1.2 或 1.2.3 形式的数字。');
  }
  final source = manifest['updateUrl'] ?? metadata['update-url'];
  final body = _text(lines.sublist(end + 1).join('\n'), '正文', 96 * 1024);
  return SkillPackage._(
    id,
    name,
    description,
    version,
    body,
    doc,
    source == null ? null : skillSource(_text(source, '更新地址', 2048)),
    Map.unmodifiable(references),
    value != null,
  );
}

bool _documentPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  if (path.contains('/') &&
      (path.startsWith('references/') || path.startsWith('assets/'))) {
    return const {'md', 'txt', 'csv', 'json', 'yaml', 'yml'}.contains(ext);
  }
  return RegExp(
    r'^(README(\.md|\.txt)?|LICENSE(\.md|\.txt)?)$',
    caseSensitive: false,
  ).hasMatch(path);
}

SkillPackage decodeSkillPackage(Uint8List bytes) {
  if (bytes.length > maxSkillBytes) {
    throw const FormatException('技能文件超过 1 MiB。');
  }
  if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
    return _parse(utf8.decode(bytes), const {}, const {});
  }
  final archive = ZipDecoder().decodeBytes(bytes, throwOnError: true);
  final files = <String, ArchiveFile>{};
  int expanded = 0;
  for (final f in archive) {
    if (!f.isFile ||
        f.name.startsWith('__MACOSX/') ||
        f.name.split('/').last == '.DS_Store') {
      continue;
    }
    final path = f.name;
    expanded += f.size;
    if (f.isSymbolicLink ||
        files.containsKey(path) ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const FormatException('技能包内有无效文件路径。');
    }
    if (expanded > maxSkillBytes || files.length >= 40) {
      throw const FormatException('技能包解压后过大或文件过多。');
    }
    files[path] = f;
  }
  final entries = files.keys
      .where((k) => k.split('/').last == 'SKILL.md')
      .toList();
  if (entries.length != 1) {
    throw const FormatException('ZIP 中需要有且仅有一份 SKILL.md。');
  }
  final main = entries.single,
      prefix = main.substring(0, main.length - 'SKILL.md'.length);
  Map manifest = const {};
  final resources = <String, String>{};
  for (final e in files.entries) {
    if (!e.key.startsWith(prefix)) throw const FormatException('请只打包一个技能目录。');
    final path = e.key.substring(prefix.length);
    if (path == 'SKILL.md') continue;
    if (path == 'skill.json') {
      final decoded = jsonDecode(utf8.decode(e.value.content));
      if (decoded is! Map || decoded.isEmpty) {
        throw const FormatException('skill.json 的格式无效。');
      }
      manifest = decoded;
    } else if (_documentPath(path)) {
      resources[path] = utf8.decode(e.value.content);
    } else {
      throw FormatException('手机技能包暂不支持此文件：$path。可导入 Markdown 指令与文本参考资料。');
    }
  }
  return _parse(utf8.decode(files[main]!.content), manifest, resources);
}

Uint8List encodeSkillPackage(SkillPackage p) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('skill.json', jsonEncode(p._manifest)))
    ..addFile(ArchiveFile.string('SKILL.md', p.document));
  for (final e in p.references.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

typedef SkillDownloader = Future<Uint8List> Function(Uri url);

Future<Uint8List> _download(Uri url) async {
  final client = http.Client();
  final timeout = Timer(const Duration(seconds: 18), client.close);
  try {
    var address = url;
    for (int attempt = 0; attempt < 4; attempt++) {
      final response = await client.send(
        http.Request('GET', address)..followRedirects = false,
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) throw const FormatException('更新地址没有返回文件。');
        final target = skillSource(address.resolve(location).toString());
        if (target.origin != url.origin) {
          throw const FormatException('更新地址转向了其他来源，请单独导入新地址。');
        }
        await response.stream.listen(null).cancel();
        address = target;
        continue;
      }
      if (response.statusCode != 200) {
        throw FormatException('无法下载技能（HTTP ${response.statusCode}）。');
      }
      if ((response.contentLength ?? 0) > maxSkillBytes) {
        throw const FormatException('技能文件超过 1 MiB。');
      }
      final result = BytesBuilder();
      await for (final chunk in response.stream) {
        if (result.length + chunk.length > maxSkillBytes) {
          throw const FormatException('技能文件超过 1 MiB。');
        }
        result.add(chunk);
      }
      return result.takeBytes();
    }
    throw const FormatException('更新地址重定向次数过多。');
  } finally {
    timeout.cancel();
    client.close();
  }
}

class InstalledSkill {
  const InstalledSkill({
    required this.current,
    this.previous,
    this.previousSource,
    this.source,
    this.enabled = true,
    this.autoUpdate = false,
    this.lastChecked,
  });
  final SkillPackage current;
  final SkillPackage? previous;
  final Uri? source, previousSource;
  final bool enabled, autoUpdate;
  final DateTime? lastChecked;

  Map<String, dynamic> toJson() => {
    'current': current.toJson(),
    if (previous != null) 'previous': previous!.toJson(),
    if (source != null) 'source': source.toString(),
    if (previousSource != null) 'previousSource': previousSource.toString(),
    'enabled': enabled,
    'autoUpdate': autoUpdate,
    'lastChecked': lastChecked?.millisecondsSinceEpoch,
  };
  factory InstalledSkill.fromJson(Map data) => InstalledSkill(
    current: SkillPackage.fromJson(data['current'] as Map),
    previous: data['previous'] == null
        ? null
        : SkillPackage.fromJson(data['previous'] as Map),
    previousSource: data['previousSource'] == null
        ? null
        : skillSource(data['previousSource'] as String),
    source: data['source'] == null
        ? null
        : skillSource(data['source'] as String),
    enabled: data['enabled'] as bool,
    autoUpdate: data['autoUpdate'] as bool,
    lastChecked: data['lastChecked'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(data['lastChecked'] as int),
  );
}

class SkillLibrary {
  SkillLibrary(this.directory, {SkillDownloader? download})
    : _fetch = download ?? _download;
  final Directory directory;
  final SkillDownloader _fetch;
  static Future<SkillLibrary> open() async {
    final root = await getDatabasesPath();
    return SkillLibrary(Directory('$root/orb-local/skills-v1'));
  }

  File _file(String id) {
    final bytes = utf8.encode(_id(id));
    final name = bytes.length <= 240 ? id : '_${sha256.convert(bytes)}';
    return File('${directory.path}/$name.json');
  }

  InstalledSkill? get(String id) {
    final file = _file(id);
    return file.existsSync()
        ? InstalledSkill.fromJson(jsonDecode(file.readAsStringSync()) as Map)
        : null;
  }

  List<InstalledSkill> list() {
    if (!directory.existsSync()) return [];
    final result = <InstalledSkill>[];
    for (final f in directory.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.json')) {
        result.add(
          InstalledSkill.fromJson(jsonDecode(f.readAsStringSync()) as Map),
        );
      }
    }
    return result..sort((a, b) => a.current.name.compareTo(b.current.name));
  }

  SkillPackage? enabled(String id) {
    final entry = get(id);
    return entry?.enabled == true ? entry!.current : null;
  }

  void _write(InstalledSkill skill) {
    directory.createSync(recursive: true);
    final file = _file(skill.current.id);
    final temp = File('${file.path}.next');
    temp.writeAsStringSync(jsonEncode(skill.toJson()), flush: true);
    temp.renameSync(file.path);
  }

  Future<SkillPackage> fetch(Uri url) async => decodeSkillPackage(
    await _fetch(skillSource(url.toString()))
        .timeout(const Duration(seconds: 18)),
  );

  /// Manual imports may authorize a source change after showing both URLs.
  bool install(
    SkillPackage package, {
    Uri? source,
    bool replaceSource = false,
  }) {
    final old = get(package.id);
    final from = source ?? package.updateUrl;
    if (from != null) skillSource(from.toString());
    if (old != null) {
      if (from != old.source && !replaceSource) {
        throw const FormatException('同名技能的更新来源不同，请先确认是否更换来源。');
      }
      if (package.versioned && old.current.versioned) {
        final order = _compareVersions(package.version, old.current.version);
        if (order < 0) throw const FormatException('已安装更新的版本。可以在详情中回退到上一版。');
        if (order == 0 && package.revision != old.current.revision) {
          throw const FormatException('相同版本的技能内容不同，请作者递增版本号。');
        }
      } else if (old.current.versioned && !package.versioned) {
        throw const FormatException('带版本号的技能需要使用带版本号的文件更新。');
      }
      if (old.current.revision == package.revision && old.source == from) {
        return false;
      }
    }
    _write(
      InstalledSkill(
        current: package,
        previous: old?.current,
        previousSource: old?.source,
        lastChecked: old?.source == from ? old?.lastChecked : null,
        enabled: old?.enabled ?? true,
        source: from,
        autoUpdate: old?.source == from && (old?.autoUpdate ?? false),
      ),
    );
    return true;
  }

  void configure(String id, {bool? enabled, bool? autoUpdate}) {
    final old = get(id);
    if (old == null) throw const FormatException('技能已被移除。');
    if (autoUpdate == true && (old.source == null || !old.current.versioned)) {
      throw const FormatException('自动更新需要有版本号和 HTTPS 更新地址。');
    }
    _write(
      InstalledSkill(
        current: old.current,
        previous: old.previous,
        previousSource: old.previousSource,
        source: old.source,
        enabled: enabled ?? old.enabled,
        autoUpdate: autoUpdate ?? old.autoUpdate,
        lastChecked: old.lastChecked,
      ),
    );
  }

  void remove(String id) {
    final f = _file(id);
    if (f.existsSync()) f.deleteSync();
  }

  void rollback(String id) {
    final old = get(id);
    if (old == null || old.previous == null) {
      throw const FormatException('没有可回退的版本。');
    }
    _write(
      InstalledSkill(
        current: old.previous!,
        source: old.previousSource,
        enabled: old.enabled,
      ),
    );
  }

  Future<bool> update(String id, {bool automatic = false}) async {
    final old = get(id);
    if (old == null || old.source == null) {
      throw const FormatException('此技能没有更新地址。');
    }
    if (automatic && !old.autoUpdate) return false;
    _write(
      InstalledSkill(
        current: old.current,
        previous: old.previous,
        previousSource: old.previousSource,
        source: old.source,
        enabled: old.enabled,
        autoUpdate: old.autoUpdate,
        lastChecked: DateTime.now(),
      ),
    );
    final next = await fetch(old.source!);
    if (next.id != id) throw const FormatException('下载包的技能 ID 与已安装技能不一致。');
    if (next.updateUrl != old.current.updateUrl) {
      throw const FormatException('新版更改了更新来源，请从文件或新地址手动导入确认。');
    }
    final now = get(id);
    if (now == null ||
        now.current.revision != old.current.revision ||
        now.source != old.source ||
        automatic && (!now.autoUpdate || !now.enabled)) {
      return false;
    }
    return install(next, source: old.source);
  }

  Future<void> refreshSubscriptions() async {
    for (final item in list()) {
      if (!item.autoUpdate ||
          !item.enabled ||
          item.lastChecked != null &&
              DateTime.now().difference(item.lastChecked!) <
                  const Duration(hours: 12)) {
        continue;
      }
      try {
        await update(item.current.id, automatic: true);
      } catch (_) {
        // A manual update reports the error. The last working package remains active.
      }
    }
  }
}
