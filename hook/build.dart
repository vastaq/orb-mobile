import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  const root = 'native/libfvad';
  final upstream = Directory.fromUri(input.packageRoot.resolve('$root/src/'));
  final sources = upstream
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.c'))
      .map(
        (file) => file.path.substring(input.packageRoot.toFilePath().length),
      );
  await CBuilder.library(
    name: 'orb_voice_activity',
    assetName: 'core/recorded_audio.dart',
    sources: ['native/voice_activity.c', ...sources],
    includes: ['$root/include'],
  ).run(input: input, output: output);
});
