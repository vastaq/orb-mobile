import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/tasks/task_store.dart';

void main() {
  OrbTask sample(DateTime due, TaskFrequency repeat) => OrbTask(
    title: '任务',
    body: '内容',
    kind: TaskKind.reminder,
    frequency: repeat,
    due: due,
  );

  test('one-time occurrence retires; a missed daily run advances to the next local wall time', () {
    final due = DateTime(2028, 2, 28, 7, 45);
    expect(sample(due, TaskFrequency.once).nextAfter(due), isNull);
    final daily = sample(due, TaskFrequency.daily);
    expect(
      daily.nextAfter(DateTime(2028, 2, 29, 8)),
      DateTime(2028, 3, 1, 7, 45),
    );
    expect(
      daily.nextAfter(DateTime(2028, 3, 1, 7)),
      DateTime(2028, 3, 1, 7, 45),
    );
  });

  test(
    'weekly occurrences retain weekday and local hour after a missed week',
    () {
      final monday = DateTime(2026, 11, 23, 18, 20);
      final weekly = sample(monday, TaskFrequency.weekly);
      expect(
        weekly.nextAfter(DateTime(2026, 12, 4, 18, 21)),
        DateTime(2026, 12, 7, 18, 20),
      );
      expect(
        weekly.nextAfter(DateTime(2026, 12, 7, 18, 20)),
        DateTime(2026, 12, 14, 18, 20),
      );
    },
  );
}
