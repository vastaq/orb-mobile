import 'dart:convert';

import 'models.dart';
import 'program_runtime.dart';
import 'tool_types.dart';
import 'workspace.dart';

const workspaceProgramTool = ChatTool(
  name: 'workspace_run',
  description:
      'Compile a saved C entry file to WebAssembly on the phone and run it. '
      'Paths are workspace-relative. The program sees only listed input_paths '
      'within the entry directory, under names relative to that directory. '
      'Use a separate folder per project, e.g. tools/sum/main.c. '
      'Supports integer C programs with main, printf and getchar (EOF=-1); '
      'use stdin_path for a local UTF-8 file without copying its contents into chat. '
      'Inspect phase, exit_code, stdout and stderr; fix the source and rerun on failure. '
      'To keep stdout as a file on success, set output_path. To replace different '
      'existing output, first read its sha256 and supply expected_output_hash. '
      'Each returned stream has at most 8000 code points; saved output contains the full stream.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
      'stdin': {'type': 'string'},
      'stdin_path': {'type': 'string'},
      'input_paths': {
        'type': 'array',
        'items': {'type': 'string'},
        'maxItems': 32,
      },
      'output_path': {'type': 'string'},
      'expected_output_hash': {'type': 'string'},
    },
    'required': ['path'],
    'additionalProperties': false,
  },
);

Future<Map<String, dynamic>> runStoredProgram(
  Workspace workspace,
  Map<String, dynamic> arguments, {
  ProgramRunControl? control,
}) async {
  String pathArgument(Object? value) {
    if (value is! String) throw const OrbException('请指定工作区内的相对路径。');
    return workspacePath(value);
  }

  Future<WorkFile> readRequired(String path) async =>
      await workspace.read(path) ?? (throw OrbException('找不到工作文件：$path'));

  final source = await readRequired(pathArgument(arguments['path']));
  if (!source.path.toLowerCase().endsWith('.c')) {
    throw const OrbException('当前可以运行 C 源码，请选择 .c 入口文件。');
  }
  final split = source.path.lastIndexOf('/') + 1;
  final folder = source.path.substring(0, split);
  final entry = source.path.substring(split);

  String projectPath(Object? value) {
    final path = pathArgument(value);
    if (folder.isEmpty ? path.contains('/') : !path.startsWith(folder)) {
      throw const OrbException('输入和输出文件需要位于入口文件所在的项目目录中。');
    }
    return path;
  }

  final inputs = arguments['input_paths'] ?? const [];
  final literal = arguments['stdin'];
  final stdinPath = arguments['stdin_path'];
  if (inputs is! List || inputs.length > 32) {
    throw const OrbException('每次运行最多可以指定 32 个输入文件。');
  }
  if (literal != null && (literal is! String || stdinPath != null)) {
    throw const OrbException('请在 stdin 文本和 stdin_path 输入文件之间选择一项。');
  }
  final inputPath = stdinPath == null ? null : projectPath(stdinPath);
  final stdin = inputPath == null
      ? literal as String? ?? ''
      : (await readRequired(inputPath)).text;
  final output = arguments['output_path'];
  final outputPath = output == null ? null : projectPath(output);
  final previous = arguments['expected_output_hash'];
  if (previous != null && (previous is! String || outputPath == null)) {
    throw const OrbException('覆盖已有输出时需要指定输出路径和原文件哈希。');
  }
  final files = <String, String>{};
  var inputBytes = 0;
  void includeText(String text) {
    final bytes = utf8.encode(text).length;
    if (bytes >= 256 * 1024) {
      throw const OrbException('单份源码、输入文件或标准输入需要小于 256 KiB。');
    }
    inputBytes += bytes;
    if (inputBytes > workspaceFileLimit) {
      throw const OrbException('源码、标准输入和输入文件合计最多 1 MiB。');
    }
  }

  includeText(source.text);
  includeText(stdin);
  for (final value in inputs) {
    final path = projectPath(value);
    final relative = path.substring(split);
    if (relative == entry || files.containsKey(relative)) continue;
    final input = await readRequired(path);
    includeText(input.text);
    files[relative] = input.text;
  }
  if (outputPath != null &&
      [
        source.path,
        ?inputPath,
        ...files.keys.map((name) => '$folder$name'),
      ].any((path) => path.toLowerCase() == outputPath.toLowerCase())) {
    throw const OrbException('请把输出保存到与源码和输入不同的文件。');
  }
  final result = await runWorkspaceProgram(
    source: source.text,
    entry: entry,
    files: files,
    stdin: stdin,
    control: control,
  );
  if (control?.cancelled == true) throw const OrbException('程序运行已停止。');
  final reply = {'path': source.path, ...result};
  if (outputPath != null &&
      result['phase'] == 'run' &&
      result['exit_code'] == 0) {
    final outputFile = WorkFile(outputPath, result['stdout'] as String);
    try {
      await workspace.save(outputFile, previous: previous as String?);
      reply['output_path'] = outputPath;
      reply['output_sha256'] = outputFile.hash;
    } on OrbException catch (error) {
      reply['output_error'] = error.message;
    }
  }
  for (final key in ['stdout', 'stderr']) {
    final text = result[key] as String;
    if (text.length <= 8000) continue;
    final prefix = text.runes.take(8001).toList();
    if (prefix.length > 8000) {
      reply[key] = String.fromCharCodes(prefix.take(8000));
      reply['${key}_truncated'] = true;
    }
  }
  return reply;
}
