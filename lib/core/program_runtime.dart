import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';

const _channel = MethodChannel('studio.orb/workspace-program');
final _available = _checkAvailability();
final _compiler = _assetBase64('compiler.wasm');
final _worker = _assetBase64('worker.js');
int _nextRun = 0;

class ProgramRunControl {
  bool _cancelled = false;
  final _requests = <int>{};

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final id in _requests) {
      unawaited(_cancelNative(id));
    }
  }

  Future<void> _cancelNative(int id) async {
    try {
      await _channel.invokeMethod<void>('cancel', id);
    } on PlatformException {
      // An engine that is already closing also disposes its active WebView.
    } on MissingPluginException {
      // The run may have ended while its engine was detaching.
    }
  }

  void _check() {
    if (_cancelled) throw const OrbException('程序运行已停止。');
  }
}

/// Each Flutter engine has its own isolate and native plugin registration.
Future<bool> workspaceProgramAvailable() => _available;

Future<bool> _checkAvailability() async {
  try {
    return await _channel.invokeMethod<bool>('available') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

Future<String> _assetBase64(String file) async {
  final data = await rootBundle.load('assets/program_runner/$file');
  return base64Encode(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

Future<Map<String, dynamic>> runWorkspaceProgram({
  required String source,
  required String entry,
  required Map<String, String> files,
  required String stdin,
  ProgramRunControl? control,
}) async {
  control?._check();
  if (!await workspaceProgramAvailable()) {
    throw const OrbException('当前设备或运行环境不支持本地编译。');
  }
  final input = base64Encode(
    utf8.encode(
      jsonEncode({
        'source': source,
        'entry': entry,
        'files': files,
        'stdin': stdin,
      }),
    ),
  );
  // All interpolated values are base64 data. Only bundled code becomes script.
  final html =
      '''<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-orb' 'wasm-unsafe-eval' 'unsafe-eval'; worker-src blob:; child-src blob:; connect-src 'none'">
<script nonce="orb">
(() => {
  const bytes = data => Uint8Array.from(atob(data), ch => ch.charCodeAt(0));
  let worker, url, timer, phase = 'compile';
  const finish = result => {
    clearTimeout(timer);
    if (worker) worker.terminate();
    if (url) URL.revokeObjectURL(url);
    window.orbProgramResult = JSON.stringify(result);
  };
  const failure = (code, message) => finish({phase, exit_code:code, stdout:'', stderr:message});
  window.orbTerminate = () => failure(130, '程序运行已停止。');
  const startTimer = () => {
    clearTimeout(timer);
    timer = setTimeout(() => failure(124, '程序超时，已终止。'), 8000);
  };
  try {
    url = URL.createObjectURL(new Blob([bytes('${await _worker}')], {type:'text/javascript'}));
    worker = new Worker(url);
    worker.onmessage = event => {
      if (event.data.started === 'run') { phase = 'run'; startTimer(); }
      else finish(event.data);
    };
    worker.onerror = event => failure(1, event.message || '无法启动编译执行环境。');
    const compiler = bytes('${await _compiler}');
    const request = JSON.parse(new TextDecoder().decode(bytes('$input')));
    startTimer();
    worker.postMessage({...request, compiler}, [compiler.buffer]);
  } catch (error) { failure(1, String(error)); }
})();
</script>''';
  control?._check();
  final id = ++_nextRun;
  control?._requests.add(id);
  try {
    final result = await _channel
        .invokeMethod<String>('run', {'id': id, 'html': html})
        .timeout(const Duration(seconds: 40));
    control?._check();
    if (result != null) return jsonDecode(result) as Map<String, dynamic>;
    throw const OrbException('本地编译环境未返回结果。');
  } on PlatformException catch (error) {
    control?._check();
    throw OrbException(error.message ?? '无法启动本地编译环境。');
  } on TimeoutException {
    control?._check();
    throw const OrbException('本地编译环境超时，请重试。');
  } finally {
    control?._requests.remove(id);
  }
}
