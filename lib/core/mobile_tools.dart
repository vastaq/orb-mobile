import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'models.dart';

enum MobileCommand {
  newChat('/new', '新对话'),
  memory('/memory', '本地记忆'),
  time('/time', '插入当前时间'),
  tools('/tools', '打开工具');

  const MobileCommand(this.name, this.label);
  final String name, label;
  static MobileCommand? parse(String input) {
    final name = input.trim().split(RegExp(r'\s+')).first.toLowerCase();
    for (final command in values) {
      if (command.name == name &&
          (command == memory || input.trim().toLowerCase() == name)) {
        return command;
      }
    }
    return null;
  }
}

String localTimeText(DateTime now) {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  String n(int value) => value.toString().padLeft(2, '0');
  final zone = now.timeZoneOffset.inMinutes;
  return '${now.year}-${n(now.month)}-${n(now.day)} 星期${weekdays[now.weekday - 1]} '
      '${n(now.hour)}:${n(now.minute)} UTC${zone >= 0 ? '+' : '−'}${n(zone.abs() ~/ 60)}:${n(zone.abs() % 60)}';
}

const textExtensions = {
  'txt',
  'md',
  'csv',
  'tsv',
  'json',
  'yaml',
  'yml',
  'log',
  'html',
  'xml',
  'dart',
  'js',
  'ts',
  'py',
  'sql',
  'toml',
  'css',
};
const documentMime = {
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'epub': 'application/epub+zip',
  'mobi': 'application/x-mobipocket-ebook',
};
const imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
  'tif',
  'tiff',
  'heic',
  'heif',
};

Future<OrbAttachment> pickedAttachment(
  File file,
  String name,
  ModelConfig config, {
  String? purpose,
  bool image = false,
}) async {
  final ext = name.split('.').last.toLowerCase();
  final size = await file.length();
  if (size == 0) throw const OrbException('所选文件为空。');
  if (image || imageExtensions.contains(ext)) {
    if (config.service == ModelService.deepSeek &&
        !config.supportsDeepSeekTools) {
      throw const OrbException('图像理解需要选择 DeepSeek Flash。');
    }
    if (size > 32 * 1024 * 1024) {
      throw const OrbException('图片超过 32 MiB，请选择较小的图片。');
    }
    final head = await file
        .openRead(0, size < 16 ? size : 16)
        .expand((bytes) => bytes)
        .toList();
    bool prefix(List<int> value) =>
        head.length >= value.length &&
        List.generate(
          value.length,
          (i) => head[i] == value[i],
        ).every((same) => same);
    final mime = prefix([0x89, 0x50, 0x4e, 0x47])
        ? 'image/png'
        : prefix([0xff, 0xd8, 0xff])
        ? 'image/jpeg'
        : prefix(ascii.encode('GIF8'))
        ? 'image/gif'
        : head.length >= 12 &&
              ascii.decode(head.sublist(8, 12), allowInvalid: true) == 'WEBP'
        ? 'image/webp'
        : null;
    if (mime != null) {
      return OrbAttachment(name: name, mime: mime, localPath: file.path);
    }
    // Some phone galleries return HEIC. Ask the native image decoder to convert
    // just these unsupported formats, preserving the original user's file.
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.Codec? codec;
    ui.Image? frame;
    try {
      codec = await ui.instantiateImageCodecFromBuffer(
        buffer,
        targetWidth: 2048,
        allowUpscaling: false,
      );
      frame = (await codec.getNextFrame()).image;
      final data = await frame.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const OrbException('请改用 JPG、PNG 或 WebP 图片。');
      return OrbAttachment(
        name: '${name.replaceFirst(RegExp(r'\.[^.]+$'), '')}.png',
        mime: 'image/png',
        dataUrl:
            'data:image/png;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}',
      );
    } catch (_) {
      throw const OrbException('这张图片无法读取，请改用 JPG、PNG 或 WebP。');
    } finally {
      frame?.dispose();
      codec?.dispose();
    }
  }
  if (textExtensions.contains(ext)) {
    if (size > 8 * 1024 * 1024) throw const OrbException('文本超过 8 MiB，请先拆分。');
    try {
      return OrbAttachment(
        name: name,
        mime: 'text/plain',
        localPath: file.path,
        extractedText: await file.readAsString(),
      );
    } on FormatException {
      throw const OrbException('请把文本文件保存为 UTF-8 后再选择。');
    }
  }
  final mime = documentMime[ext];
  if (mime == null) throw const OrbException('当前不支持该文件格式。');
  if (config.service == ModelService.deepSeek &&
      !config.supportsDeepSeekTools) {
    throw const OrbException('文档解析需要选择 DeepSeek Flash。');
  }
  if (config.service == ModelService.claude && ext != 'pdf') {
    throw const OrbException('此连接请使用 PDF 或文本文件。');
  }
  final userData = {'xls', 'xlsx', 'epub', 'mobi'}.contains(ext);
  final max = config.service == ModelService.deepSeek && !userData ? 100 : 32;
  if (size > max * 1024 * 1024) throw OrbException('文件超过 $max MiB，请选择较小的文件。');
  final presentation =
      config.supportsDeepSeekTools && {'ppt', 'pptx'}.contains(ext);
  final parsePurpose =
      purpose ??
      (presentation ? 'rich_layout_recognition' : 'text_recognition');
  return OrbAttachment(
    name: name,
    mime: mime,
    localPath: file.path,
    purpose: userData ? 'user_data' : parsePurpose,
  );
}
