import 'dart:io';

import 'attachment.dart';
export 'attachment.dart';
export 'prompt_context.dart'
    show
        buildContext,
        ContextSnapshot,
        PromptSettings,
        PromptTemplate,
        loadPromptSettings,
        persistPromptSettings;

class OrbException implements Exception {
  const OrbException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModelConfig {
  static const deepSeek = ModelConfig();
  static const openAI = ModelConfig(
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-6-luna',
  );
  static const claude = ModelConfig(
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-haiku-5-5',
  );

  const ModelConfig({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.model = 'deepseek-flash',
    this.apiKey = '',
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  ModelService get service => switch (Uri.tryParse(baseUrl.trim())?.host) {
    'api.deepseek.com' => ModelService.deepSeek,
    'api.openai.com' => ModelService.openAI,
    'api.anthropic.com' => ModelService.claude,
    _ => ModelService.custom,
  };

  String? get settingsError {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !{'http', 'https'}.contains(uri.scheme)) {
      return '请输入完整的 HTTPS 接口地址。';
    }
    if (uri.scheme == 'http') {
      if (!_isLocal(uri.host)) return 'HTTP 仅适用于本机或局域网 IP 地址。';
      if (apiKey.trim().isNotEmpty) return '携带 API Key 时需要使用 HTTPS。';
    }
    if (model.trim().isEmpty) return '请填写模型名称。';
    return null;
  }

  String? get validationError {
    final invalid = settingsError;
    if (invalid != null) return invalid;
    if (service != ModelService.custom && apiKey.trim().isEmpty) {
      return '请先填写 $label API Key。';
    }
    return null;
  }

  static bool _isLocal(String host) {
    if (host == 'localhost') return true;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final b = ip.rawAddress;
    if (b.length == 16) return (b[0] & 0xfe) == 0xfc;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  bool get usable => validationError == null;
  bool get supportsDeepSeekTools =>
      service == ModelService.deepSeek &&
      const {
        'deepseek-flash',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp',
      }.contains(model.trim());
  String get label => switch (service) {
    ModelService.deepSeek => 'DeepSeek',
    ModelService.openAI => 'OpenAI',
    ModelService.claude => 'Claude',
    ModelService.custom => model.trim(),
  };
  Uri get endpoint {
    final uri = Uri.parse(baseUrl.trim());
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    final route = switch (service) {
      ModelService.claude => '/messages',
      ModelService.openAI => '/responses',
      _ => '/chat/completions',
    };
    if (service == ModelService.claude || service == ModelService.openAI) {
      // Earlier app versions allowed a full Chat Completions URL as a custom base.
      if (path.endsWith('/chat/completions')) {
        path = path.substring(0, path.length - '/chat/completions'.length);
      }
      if (path.isEmpty) path = '/v1';
    }
    if (!path.endsWith(route)) path += route;
    return uri.replace(path: path);
  }
}

enum ModelService { deepSeek, openAI, claude, custom }

class OrbThread {
  const OrbThread(this.id, this.title, {this.updatedAt});
  final DateTime? updatedAt;
  final String id;
  final String title;
}

class OrbMessage {
  const OrbMessage(
    this.role,
    this.text, {
    this.status = 'complete',
    this.attachments = const [],
    this.metadata = const {},
    this.receipt,
  });
  final String role;
  final String text;
  final String status;
  final List<OrbAttachment> attachments;
  final Map<String, dynamic> metadata;
  final String? receipt;
}

class OrbMemory {
  const OrbMemory(this.id, this.text, {this.isAutomatic = false});
  final bool isAutomatic;
  static const maxLength = 500;
  final String id;
  final String text;
}
