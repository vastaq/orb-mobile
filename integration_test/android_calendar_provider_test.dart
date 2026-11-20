import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('studio.orb/personal-calendar');
const _enabled = bool.fromEnvironment('ORB_CALENDAR_NATIVE_UAT');

// Start tool/calendar_benchmark.py observe on the same fresh, seeded emulator.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android Calendar Provider grants, protected events and CRUD',
    (_) async {
      final cache = await getTemporaryDirectory();
      final step = File('${cache.path}/orb-calendar-uat-step');
      final ack = File('${cache.path}/orb-calendar-uat-ack');
      if (ack.existsSync()) ack.deleteSync();
      addTearDown(() {
        if (step.existsSync()) step.deleteSync();
        if (ack.existsSync()) ack.deleteSync();
      });
      Future<void> checked(String name) async {
        await step.writeAsString(name, flush: true);
        final elapsed = Stopwatch()..start();
        while (!ack.existsSync() || ack.readAsStringSync().trim() != name) {
          if (elapsed.elapsed > const Duration(seconds: 75)) {
            fail('Missing independent check: $name');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }

      Future<dynamic> call(String name, [Map<String, Object?>? arguments]) =>
          _channel.invokeMethod<dynamic>(name, arguments);
      Matcher error(String code) =>
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code));
      expect(await call('available'), true);
      expect(await call('permission'), 'undetermined');
      await expectLater(call('calendars'), error('permission_denied'));
      await step.writeAsString('deny_permission', flush: true);
      expect(await call('requestAccess'), 'denied');
      expect(await call('permission'), 'denied');
      await expectLater(
        call('create', {'calendarId': '1'}),
        error('permission_denied'),
      );
      await checked('denied');
      await step.writeAsString('allow_permission', flush: true);
      expect(await call('requestAccess'), 'granted');
      expect(await call('permission'), 'granted');
      final calendars = (await call('calendars') as List).whereType<Map>();
      final lab = calendars.singleWhere(
        (c) => c['title'] == 'Orb Calendar Lab',
      );
      final guard = calendars.singleWhere(
        (c) => c['title'] == 'Orb Calendar Guard',
      );
      expect(lab['writable'], true);
      final start = DateTime.utc(2032, 6, 12, 10).millisecondsSinceEpoch;
      const hour = 3600000;
      final range = {
        'calendarId': lab['id'],
        'fromMs': start - 11 * hour,
        'toMs': start + 72 * hour,
        'limit': 50,
      };
      final initial = (await call('events', range) as List).whereType<Map>();
      final repeat = initial
          .where((e) => e['title'] == 'Daily sample')
          .toList();
      expect(repeat, hasLength(3));
      expect(repeat.every((e) => e['editable'] == false), true);
      expect(repeat[1]['startMs'] - repeat[0]['startMs'], 24 * hour);
      final day = initial.singleWhere((e) => e['allDay'] == true);
      expect(day['editable'], false);
      final group = initial.singleWhere(
        (e) => e['title'] == 'Local group sample',
      );
      final solo = initial.singleWhere(
        (e) => e['title'] == 'Only organizer sample',
      );
      expect(group['editable'], false);
      expect(solo['editable'], true);
      final grouped = {'calendarId': lab['id'], 'id': group['id']};
      await expectLater(
        call('update', {...grouped, 'location': 'X'}),
        error('read_only'),
      );
      await expectLater(call('delete', grouped), error('read_only'));
      await expectLater(
        call('update', {
          'calendarId': lab['id'],
          'id': repeat.first['id'],
          'title': 'x',
        }),
        error('read_only'),
      );
      await expectLater(
        call('delete', {'calendarId': lab['id'], 'id': day['id']}),
        error('read_only'),
      );
      final added = await call('create', {
        'calendarId': lab['id'],
        'title': 'Exhibit pickup',
        'startMs': start,
        'endMs': start + hour,
        'location': 'Studio A',
      }) as Map;
      final target = {'id': added['id'], 'calendarId': lab['id']};
      expect(added['editable'], true);
      expect((await call('get', target))['startMs'], start);
      final other = {'id': added['id'], 'calendarId': guard['id']};
      await expectLater(call('get', other), error('not_found'));
      await expectLater(
        call('update', {...other, 'title': 'x'}),
        error('not_found'),
      );
      await expectLater(call('delete', other), error('not_found'));
      final overlap = await call('events', {
        'calendarId': lab['id'],
        'fromMs': start + 1,
        'toMs': start + hour,
        'limit': 50,
      }) as List;
      expect(overlap.where((e) => e['id'] == added['id']), hasLength(1));
      await checked('created');
      final changed = await call('update', {
        ...target,
        'title': 'Exhibit pickup revised',
        'location': 'Studio B',
        'startMs': start + hour,
        'endMs': start + 2 * hour,
      });
      expect(changed['id'], added['id']);
      await checked('updated');
      expect((await call('delete', target))['deleted'], true);
      await expectLater(call('get', target), error('not_found'));
      await checked('deleted');
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 7)),
  );
  testWidgets(
    'opens the specified saved event in the system calendar',
    (_) async {
      expect(await _channel.invokeMethod<String>('permission'), 'granted');
      final calendars = (await _channel.invokeListMethod<dynamic>('calendars'))!
          .whereType<Map>();
      final guard = calendars.singleWhere(
        (c) => c['title'] == 'Orb Calendar Guard',
      );
      final lab = calendars.singleWhere(
        (c) => c['title'] == 'Orb Calendar Lab',
      );
      final start = DateTime.utc(2032, 6, 12, 10).millisecondsSinceEpoch;
      final events = (await _channel.invokeListMethod<dynamic>('events', {
        'calendarId': guard['id'],
        'fromMs': start,
        'toMs': start + 3600000,
        'limit': 50,
      }))!.whereType<Map>();
      final e = events.singleWhere((v) => v['title'] == 'Keep this booking');
      await expectLater(
        _channel.invokeMethod<bool>('open', {
          'calendarId': lab['id'],
          'id': e['id'],
        }),
        throwsA(
          isA<PlatformException>().having((v) => v.code, 'code', 'not_found'),
        ),
      );
      final cache = await getTemporaryDirectory();
      final ack = File('${cache.path}/orb-calendar-open-ack');
      if (ack.existsSync()) ack.deleteSync();
      addTearDown(() {
        if (ack.existsSync()) ack.deleteSync();
      });
      expect(
        await _channel.invokeMethod<bool>('open', {
          'calendarId': guard['id'],
          'id': e['id'],
        }),
        true,
      );
      final elapsed = Stopwatch()..start();
      while (!ack.existsSync()) {
        if (elapsed.elapsed > const Duration(seconds: 120)) {
          fail('Missing independent Calendar activity check.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    },
    skip: !const bool.fromEnvironment('ORB_CALENDAR_OPEN_UAT'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
