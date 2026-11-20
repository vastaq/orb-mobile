import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/tasks/schedule_tools.dart';
import 'package:orb_mobile/tasks/task_service.dart';
import 'package:orb_mobile/tasks/task_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'scheduled tools persist, guard revisions, and retry without duplicating',
    (_) async {
      await initializeOrbTasks(onOpen: (_) {});
      final service = await TaskService.open();
      final now = DateTime.now();
      final turn = 'schedule-test-${now.microsecondsSinceEpoch}';
      final args = <String, dynamic>{
        'title': turn,
        'body': 'review notes',
        'kind': 'prompt',
        'frequency': 'weekly',
        'due': '${now.year + 1}-05-12T20:00',
      };
      ScheduleTools handler() =>
          ScheduleTools(turnKey: turn, open: () async => service);
      final host = handler();
      final result = await host.execute('schedule_create', args);
      expect(result['ok'], isTrue, reason: '$result');
      final task = result['task'] as Map;
      final id = task['id'] as int;
      addTearDown(() async {
        for (final leftover in (await service.store.all()).where(
          (t) => t.title == turn,
        )) {
          await service.remove(leftover);
        }
      });
      expect((await host.execute('schedule_create', args))['task']['id'], id);
      expect(
        (await handler().execute('schedule_create', {
          ...args,
          'title': 'retry: $turn',
        }))['task']['id'],
        id,
      );
      final list = await host.execute('schedule_list', {'query': turn});
      expect(list['tasks'], hasLength(1));
      expect(list['tasks'][0].containsKey('body'), isFalse);
      final viewed = await host.execute('schedule_view', {'id': id});
      expect(viewed['task']['body'], 'review notes');
      Future<Map<String, dynamic>> edit(
        int revision,
        String action, [
        Map<String, dynamic> extra = const {},
      ]) => host.execute('schedule_edit', {
        'id': id,
        'revision': revision,
        'action': action,
        ...extra,
      });
      final paused = await edit(1, 'pause');
      expect(paused['task']['enabled'], isFalse);
      expect(paused['task']['next_occurrence'], isNull);
      expect((await edit(1, 'delete'))['ok'], isFalse);
      final updated = await edit(2, 'update', {
        'body': 'updated notes',
        'frequency': 'daily',
        'due': '${now.year + 1}-05-13T21:00',
      });
      expect(updated['task']['body'], 'updated notes');
      final resumed = await edit(3, 'resume');
      expect(resumed['task']['enabled'], isTrue);
      expect(resumed['task']['frequency'], 'daily');
      expect(
        resumed['task']['next_occurrence'],
        startsWith('${now.year + 1}-05-13T21:00'),
      );
      expect((await edit(4, 'delete'))['deleted_id'], id);
      expect(await service.store.find(id), isNull);
      expect((await handler().execute('schedule_create', args))['ok'], isFalse);
      for (final malformed in [
        {...args, 'due': '${now.year + 1}-02-30T12:00'},
        {...args, 'frequency': 'hourly'},
        {...args, 'due': '2000-01-01T00:00'},
      ]) {
        expect(
          (await handler().execute('schedule_create', malformed))['ok'],
          isFalse,
        );
      }
      expect(
        (await service.store.all()).where((OrbTask t) => t.title == turn),
        isEmpty,
      );
    },
  );
}
