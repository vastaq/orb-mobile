import 'dart:convert';

import 'models.dart';
import 'program_runtime.dart';
import 'tool_types.dart';
import 'workspace.dart';

const workspaceProgramTool = ChatTool(
  name: 'workspace_run',
  description:
      'Run a saved JavaScript (.js, QuickJS) or C (.c) entry on the phone. '
      'For tabular, JSON, text or arithmetic tasks, use JavaScript to compute and verify the result. '
      'When processing existing data, save the entry alongside those inputs, or in their common parent directory. '
      'In JavaScript readText accepts the selected input’s workspace path ("project/data.tsv") '
      'or its path relative to the entry ("./data.tsv"). Use readStdin() '
      'for the supplied stdin or stdin_path, and console.log(text) for stdout. '
      "For a newline-terminated table use console.log(rows.join('\\n')) once; "
      'console.log appends the final newline, so omit a trailing newline or extra blank log. '
      'No Node, browser, imports, or network. '
      'The entry path is workspace-relative. For a header such as #include "include/config.h", '
      'pass input_paths: ["./include/config.h"]. All ./ paths resolve under the entry folder. '
      'Use source_paths for any additional .c files to compile and link; use '
      'input_paths for headers and read-only data. C opens selected files '
      'by names relative to the entry directory. '
      'Use standard C headers and main. Read stdin with getchar or fgets, write '
      'stdout with printf, and use fopen in read mode for listed project files. '
      'The bundled C library has limited scanf-family parsing and does not provide ferror; '
      'for tokenized text use fgets with strtol, strchr or explicit character parsing. '
      'Use stdin_path for a local UTF-8 file without copying its contents into chat. '
      'On a compile error, edit the source using the returned sha256 before rerunning. '
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
      'source_paths': {
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
  final js = source.path.toLowerCase().endsWith('.js');
  if (!js && !source.path.toLowerCase().endsWith('.c')) {
    throw const OrbException('请选择 JavaScript (.js) 或 C (.c) 入口文件。');
  }
  final split = source.path.lastIndexOf('/') + 1;
  final folder = source.path.substring(0, split);
  final entry = source.path.substring(split);

  String projectPath(Object? value) {
    if (value is String && value.startsWith('./')) {
      return '$folder${workspacePath(value.substring(2))}';
    }
    final path = pathArgument(value);
    if (!path.contains('/')) return '$folder$path';
    if (folder.isEmpty || !path.startsWith(folder)) {
      throw OrbException(
        '路径 $path 需要位于入口文件 ${source.path} 的项目目录中。处理已有数据时，把入口保存在这些输入的同一目录或共同父目录。目录内可用 ./ 相对路径或完整工作区路径。',
      );
    }
    return path;
  }

  Future<String> readProjectPath(Object? value) async {
    if (value is String && folder.isNotEmpty && !value.startsWith('./')) {
      final name = pathArgument(value);
      if (name.contains('/') && !name.startsWith(folder)) {
        final local = '$folder$name';
        if (await workspace.read(local) != null) return local;
      }
    }
    return projectPath(value);
  }

  final inputs = arguments['input_paths'] ?? const [];
  final sources = arguments['source_paths'] ?? const [];
  final literal = arguments['stdin'];
  final stdinPath = arguments['stdin_path'];
  if (inputs is! List ||
      sources is! List ||
      inputs.length > 32 ||
      sources.length > 32) {
    throw const OrbException('每次运行最多可以指定 32 个额外源码、头文件和输入文件。');
  }
  if (js && sources.isNotEmpty) {
    throw const OrbException(
      'JavaScript 的数据文件请列入 input_paths。source_paths 用于 C 源码。',
    );
  }
  final units = {for (final path in sources) await readProjectPath(path)}
    ..remove(source.path);
  if (units.any((path) => !path.endsWith('.c'))) {
    throw const OrbException('额外编译的源文件必须是 .c 文件。');
  }
  final selected = {
    for (final path in inputs) await readProjectPath(path),
    ...units,
  }..remove(source.path);
  if (selected.length > 32) throw const OrbException('每次运行最多可以指定 32 个项目文件。');
  if (literal != null && (literal is! String || stdinPath != null)) {
    throw const OrbException('请在 stdin 文本和 stdin_path 输入文件之间选择一项。');
  }
  final inputPath = stdinPath == null ? null : await readProjectPath(stdinPath);
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
  for (final path in selected) {
    final relative = path.substring(split);
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
    projectPrefix: folder,
    units: [for (final path in units) path.substring(split)],
    files: files,
    stdin: stdin,
    control: control,
  );
  if (control?.cancelled == true) throw const OrbException('程序运行已停止。');
  final reply = {
    'path': source.path,
    ...result,
    if (result['phase'] == 'compile' && result['exit_code'] != 0) ...{
      'sha256': source.hash,
      'next_action': js
          ? 'Use workspace_edit with this path and sha256 as expected_hash to fix the JavaScript syntax error.'
          : 'Use workspace_edit with this path and sha256 as expected_hash '
                'to correct the compilation diagnostic, or supply a missing header in input_paths. '
                'Rerunning unchanged source with a different stdin or output path cannot fix a compiler error.',
    },
  };
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
