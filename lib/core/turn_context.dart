import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_provider.dart';
import 'models.dart';
import 'prompt_context.dart' show planContext;

Future<OrbAttachment> prepareDocument(
  ModelConfig config,
  OrbAttachment file,
  http.Client client,
) async {
  if (config.service != ModelService.deepSeek ||
      file.isImage ||
      file.extractedText != null ||
      file.fileId != null && file.fileOrigin == config.baseUrl ||
      !file.available) {
    return file;
  }
  final request = http.MultipartRequest(
    'POST',
    Uri.parse(config.baseUrl).replace(path: '/files'),
  );
  request.followRedirects = false;
  request.headers['Authorization'] = 'Bearer ${config.apiKey}';
  request.fields['purpose'] = file.purpose;
  request.files.add(
    http.MultipartFile.fromBytes(
      'file',
      await file.bytes(),
      filename: file.name,
    ),
  );
  final result = await client.send(request).timeout(const Duration(minutes: 4));
  if (result.statusCode < 200 || result.statusCode >= 300) {
    await result.stream.drain();
    throw OrbException('文档解析失败（HTTP ${result.statusCode}），可以重新发送。');
  }
  final object = jsonDecode(await result.stream.bytesToString());
  if (object is! Map || object['id'] is! String) {
    throw const OrbException('文件服务没有返回文档编号。');
  }
  return OrbAttachment(
    name: file.name,
    mime: file.mime,
    localPath: file.localPath,
    dataUrl: file.dataUrl,
    fileId: object['id'],
    fileOrigin: config.baseUrl,
    purpose: file.purpose,
  );
}

Future<List<ChatMessage>> richContext(
  ModelConfig config,
  List<OrbMessage> history,
  List<OrbMemory> memories,
  OrbMessage user, {
  PromptSettings prompts = const PromptSettings(),
  void Function(ContextSnapshot)? onSnapshot,
}) async {
  final plan = planContext(history, memories, user, prompts: prompts);
  onSnapshot?.call(plan.snapshot);
  final result = <ChatMessage>[
    if (plan.system.isNotEmpty) {'role': 'system', 'content': plan.system},
  ];
  for (final original in plan.messages) {
    final current = identical(original, user);
    final text = current ? plan.currentText : original.text;
    final simple = {'role': original.role, 'content': text};
    if (original.role == 'assistant') {
      final same = original.metadata['provider'] == config.service.name;
      result.add({
        ...simple,
        if (original.metadata['localTools'] case final List tools
            when tools.isNotEmpty)
          'content': '$text\n[Orb 本机此前的执行记录] ${jsonEncode(tools)}',
        if (same && original.metadata['native'] is Map)
          ...Map<String, dynamic>.from(original.metadata['native'] as Map),
      });
      continue;
    }
    final blocks = <Map<String, dynamic>>[];
    if (text.isNotEmpty) {
      blocks.add({'type': 'text', 'text': text});
    }
    for (final a in original.attachments) {
      if (a.extractedText != null) {
        blocks.add({
          'type': 'text',
          'text': '文件《${a.name}》\n${plan.fileText(a)}',
        });
      } else if (a.fileId != null && a.fileOrigin == config.baseUrl) {
        blocks.add({
          'type': 'file',
          'file': {'file_id': a.fileId},
        });
      } else if (a.dataUrl.isEmpty && a.localPath == null) {
        blocks.add({'type': 'text', 'text': '[附件：${a.name}，原件不可用]'});
      } else if (a.isImage) {
        blocks.add({
          'type': 'image_url',
          'image_url': {'url': await a.asDataUrl()},
        });
      } else if (config.service == ModelService.deepSeek) {
        // A file uploaded under another provider is never treated as a DeepSeek file ID.
        if (current) throw const OrbException('请重新发送文档以便交给当前模型解析。');
        blocks.add({'type': 'text', 'text': '[之前在其他服务使用的文件：${a.name}]'});
      } else {
        blocks.add({
          'type': 'file',
          'file': {'filename': a.name, 'file_data': await a.asDataUrl()},
        });
      }
    }
    result.add(
      original.attachments.isEmpty
          ? simple
          : {'role': 'user', 'content': blocks},
    );
  }
  return result;
}
