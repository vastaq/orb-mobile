import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'models.dart' show ModelService, ModelConfig;

/// Claude reports cache reads/writes outside base input. Other endpoints include cached input in the total.
class TokenCounter {
  int? input, output;
  int cached = 0, reasoning = 0;
  final claude = <String, int>{};
  void observe(ModelService service, Map event) {
    dynamic usage = event['usage'];
    if (service == ModelService.openAI && event['response'] is Map) {
      usage = event['response']['usage'];
    }
    if (service == ModelService.claude && event['message'] is Map) {
      usage = event['message']['usage'];
    }
    if (usage is! Map) return;
    int? count(dynamic v) => v is int && v >= 0 ? v : null;
    if (service == ModelService.claude) {
      for (final name in [
        'input_tokens',
        'cache_creation_input_tokens',
        'cache_read_input_tokens',
        'output_tokens',
      ]) {
        if (count(usage[name]) case final int amount) claude[name] = amount;
      }
      cached = claude['cache_read_input_tokens'] ?? 0;
      if (claude['input_tokens'] case final int base) {
        input = base + cached + (claude['cache_creation_input_tokens'] ?? 0);
      }
      output = claude['output_tokens'];
      return;
    }
    input = count(usage['input_tokens'] ?? usage['prompt_tokens']) ?? input;
    output =
        count(usage['output_tokens'] ?? usage['completion_tokens']) ?? output;
    final inDetails =
        usage['input_tokens_details'] ?? usage['prompt_tokens_details'];
    final outDetails =
        usage['output_tokens_details'] ?? usage['completion_tokens_details'];
    cached =
        count(usage['prompt_cache_hit_tokens']) ??
        (inDetails is Map ? count(inDetails['cached_tokens']) : null) ??
        cached;
    reasoning =
        (outDetails is Map ? count(outDetails['reasoning_tokens']) : null) ??
        reasoning;
  }

  Map<String, int>? get value => input == null || output == null
      ? null
      : {
          'input': input!,
          'output': output!,
          'cached': cached,
          'reasoning': reasoning,
        };
}

class UsageLog {
  static Future<Database> _open() async {
    final dir = Directory('${await getDatabasesPath()}/orb-local');
    await dir.create(recursive: true);
    return openDatabase(
      '${dir.path}/usage.db',
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE usage(id INTEGER PRIMARY KEY, at INTEGER NOT NULL, model TEXT NOT NULL, purpose TEXT NOT NULL, input INTEGER, output INTEGER, cached INTEGER, reasoning INTEGER)',
        );
      },
    );
  }

  static Future<void> record(
    ModelConfig c,
    String purpose,
    Map<String, int>? values,
  ) async {
    final db = await _open();
    await db.insert('usage', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'model': '${c.label == c.model ? "自定义" : c.label} · ${c.model}',
      'purpose': purpose,
      ...?values,
    });
  }

  static Future<List<Map<String, Object?>>> since(DateTime date) async =>
      (await _open()).query(
        'usage',
        where: 'at>=?',
        whereArgs: [date.millisecondsSinceEpoch],
        orderBy: 'at',
      );
  static Future<void> clear() async => (await _open()).delete('usage');
}
