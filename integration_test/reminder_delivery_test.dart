import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orb_mobile/tasks/schedule_tools.dart';
import 'package:orb_mobile/tasks/task_service.dart';

/// On a fresh Android 13+ test install, deny the first OS notification prompt,
/// then allow the second. On a fresh iOS simulator, allow the first prompt. Press
/// Home at READY_TO_BACKGROUND and reopen after the reminder's delivery time.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('chat reminder asks permission and delivers after leaving Orb', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    await initializeOrbTasks(onOpen: (_) {});
    final service = await TaskService.open();
    if (Platform.isAndroid) {
      expect(await service.notificationsEnabled(), isFalse);
    }
    final name = 'Orb reminder UAT ${DateTime.now().millisecondsSinceEpoch}';
    const body = 'Return the library book';
    Future<Map<String, dynamic>> create(String turn) {
      final due = DateTime.now().add(
        Duration(seconds: Platform.isIOS ? 60 : 35),
      );
      return ScheduleTools(turnKey: '$name/$turn').execute('schedule_create', {
        'title': name,
        'body': body,
        'due': due.toIso8601String().split('.').first,
      });
    }

    if (Platform.isAndroid) {
      final denied = await create('denied');
      expect(denied['ok'], isFalse, reason: '$denied');
      expect(denied['notifications_enabled'], isFalse);
      expect(
        (await service.store.all()).where((t) => t.title == name),
        isEmpty,
      );
      final foregroundDeadline = DateTime.now().add(
        const Duration(seconds: 10),
      );
      while (WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed &&
          DateTime.now().isBefore(foregroundDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final allowed = await create('allowed');
    expect(allowed['ok'], isTrue, reason: '$allowed');
    expect(allowed['notifications_enabled'], isTrue);
    final id = allowed['task']['id'] as int;
    addTearDown(() async {
      final task = await service.store.find(id);
      if (task != null) await service.remove(task);
    });
    final notifications = FlutterLocalNotificationsPlugin();
    if (Platform.isIOS) {
      final pending = await notifications.pendingNotificationRequests();
      expect(pending.any((n) => n.title == name && n.body == body), isTrue);
    }
    var wasInBackground = false;
    final reopened = Completer<void>();
    final lifecycle = AppLifecycleListener(
      onPause: () => wasInBackground = true,
      onResume: () {
        if (wasInBackground && !reopened.isCompleted) reopened.complete();
      },
    );
    addTearDown(lifecycle.dispose);
    debugPrint(
      'READY_TO_BACKGROUND id=$id title=$name due=${allowed['task']['due']}',
    );
    // The iOS process is suspended on Home. Query Notification Center after
    // reopening, even if the simulator's host slept during the delivery window.
    if (Platform.isIOS) {
      await reopened.future.timeout(const Duration(minutes: 5));
    }
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < const Duration(minutes: 2)) {
      wasInBackground |=
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;
      final runs = await service.store.runs(id);
      final notices = await notifications.getActiveNotifications();
      // iOS delivers the registered local notification independently of the
      // discretionary processing callback used for model tasks and run history.
      final recorded =
          Platform.isIOS ||
          runs.any((r) => r.status == 'done' && r.result == body);
      if (recorded && notices.any((n) => n.title == name && n.body == body)) {
        expect(wasInBackground, isTrue);
        debugPrint('DELIVERED_IN_BACKGROUND id=$id title=$name');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    fail('No matching native delivery for $name');
  }, skip: !const bool.fromEnvironment('ORB_NOTIFICATION_UAT'));
}
