import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// User-selected content. Persisted attachments hold a private file path;
/// base64 is only materialized for import, export, or a model request.
class OrbAttachment {
  const OrbAttachment({
    required this.name,
    required this.mime,
    this.dataUrl = '',
    this.localPath,
    this.extractedText,
    this.fileId,
    this.fileOrigin,
    this.purpose = 'rich_layout_recognition',
  });
  final String name, mime, dataUrl, purpose;
  final String? localPath, extractedText, fileId, fileOrigin;
  bool get isImage => mime.startsWith('image/');
  bool get available =>
      dataUrl.isNotEmpty ||
      localPath != null ||
      extractedText != null ||
      fileId != null;
  Future<Uint8List> bytes() async {
    if (dataUrl.isNotEmpty) return UriData.parse(dataUrl).contentAsBytes();
    return File(localPath!).readAsBytes();
  }

  Future<String> asDataUrl() async => dataUrl.isNotEmpty
      ? dataUrl
      : 'data:$mime;base64,${base64Encode(await bytes())}';

  OrbAttachment onDisk(String path) => OrbAttachment(
    name: name,
    mime: mime,
    localPath: path,
    extractedText: extractedText,
    fileId: fileId,
    fileOrigin: fileOrigin,
    purpose: purpose,
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'mime': mime,
    if (localPath != null) 'path': localPath,
    if (extractedText != null) 'text': extractedText,
    if (fileId != null) 'id': fileId,
    if (fileOrigin != null) 'origin': fileOrigin,
    'purpose': purpose,
  };
  factory OrbAttachment.fromJson(Map<String, dynamic> j, {String? filePath}) =>
      OrbAttachment(
        name: j['name'] as String,
        mime: j['mime'] as String,
        localPath: filePath ?? j['path'] as String?,
        extractedText: j['text'] as String?,
        fileId: j['id'] as String?,
        fileOrigin: j['origin'] as String?,
        purpose: j['purpose'] as String? ?? 'rich_layout_recognition',
      );
}
