import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as zones;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import '../core/chat_provider.dart';
import '../core/mobile_harness.dart';
import '../core/models.dart';
import '../core/orb_store.dart';
import '../core/turn_context.dart';
import 'task_store.dart';

const _appleIdentifier = 'studio.orb.tasks.process';
const _details = NotificationDetails(
  android: AndroidNotificationDetails(
    'orb_tasks',
    '定时任务',
    importance: Importance.high,
    priority: Priority.high,
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
);
final _notifications = FlutterLocalNotificationsPlugin();
void Function(int)? _openTask;
Future<void>? _foregroundInit;

@pragma('vm:entry-point')
void orbTaskDispatcher() {
  Workmanager().executeTask((name, data) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    await _initNotifications();
    final service = await TaskService.open();
    if (Platform.isIOS) {
      await service.processAppleDue();
    } else if (name == 'orb.task' && data != null) {
      await service.execute(
        data['id'] as int,
        revision: data['revision'] as int,
        due: data['due'] as int,
      );
    }
    return true;
  });
}

Future<void> _initNotifications() async {
  if (Platform.isIOS) {
    zones.initializeTimeZones();
    tz.setLocalLocation(
      tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier),
    );
  }
  await _notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_orb_task'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ),
    onDidReceiveNotificationResponse: (n) => _receiveTap(n.payload),
  );
}

void _receiveTap(String? payload) {
  final fields = payload?.split(':');
  if (fields == null || fields.length != 2 || fields.first != 'task') return;
  final id = int.tryParse(fields.last);
  if (id != null) _openTask?.call(id);
}

Future<void> initializeOrbTasks({required void Function(int taskId) onOpen}) {
  _openTask = onOpen;
  return _foregroundInit ??= _startForeground();
}

Future<void> _startForeground() async {
  await Workmanager().initialize(orbTaskDispatcher);
  await _initNotifications();
  final launch = await _notifications.getNotificationAppLaunchDetails();
  final service = await TaskService.open();
  // Reconcile after an OS restart or interruption between a database write
  // and scheduling the next occurrence.
  for (final task in await service.store.all()) {
    if (task.enabled) await service._schedule(task);
  }
  if (Platform.isIOS) await service._scheduleAppleProcessing();
  if (launch?.didNotificationLaunchApp == true) {
    _receiveTap(launch?.notificationResponse?.payload);
  }
}

class TaskService {
  TaskService(this.store);
  final TaskStore store;
  static Future<TaskService> open() async =>
      TaskService(await TaskStore.open());

  Future<bool> requestNotifications() async {
    if (Platform.isAndroid) {
      return await _notifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          true;
    }
    return await _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
  }

  Future<bool?> notificationsEnabled() async {
    if (Platform.isAndroid) {
      return _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
    }
    if (Platform.isIOS) {
      final state = await _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return state?.isEnabled;
    }
    return null;
  }

  /// Only an interactive foreground reminder may open the OS permission dialog.
  Future<bool?> reminderNotificationPermission({required bool mayAsk}) async {
    try {
      final granted = await notificationsEnabled();
      if (granted == true ||
          !mayAsk ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return granted;
      }
      return await requestNotifications();
    } on PlatformException {
      return null;
    }
  }

  Future<OrbTask> save(OrbTask draft, {String? createSource}) async {
    if (createSource != null) {
      final existing = await store.createdFrom(createSource);
      if (existing != null) return existing;
    }
    if (draft.title.trim().isEmpty || draft.body.trim().isEmpty) {
      throw const OrbException('请填写任务名称和内容。');
    }
    if (draft.enabled && !draft.due.isAfter(DateTime.now())) {
      throw const OrbException('请选择将来的时间。');
    }
    final previous = draft.id == 0 ? null : await store.find(draft.id);
    final result = await store.save(draft, createSource: createSource);
    try {
      if (previous != null) await _cancel(previous);
      if (result.enabled) await _schedule(result);
      if (Platform.isIOS) await _scheduleAppleProcessing();
    } catch (_) {
      // Persist a disabled record rather than promising an OS delivery that failed.
      await store.save(
        OrbTask(
          id: result.id,
          revision: result.revision,
          title: result.title,
          body: result.body,
          kind: result.kind,
          frequency: result.frequency,
          due: result.due,
          enabled: false,
        ),
      );
      throw const OrbException('系统未能安排任务，已保存为关闭。请重新开启。');
    }
    return result;
  }

  Future<void> remove(OrbTask task) async {
    await store.delete(task.id, revision: task.revision);
    await _cancel(task);
    if (Platform.isIOS) await _scheduleAppleProcessing();
  }

  Future<void> _cancel(OrbTask task) async {
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName(task.workName);
    }
    await _notifications.cancel(id: task.id * 2);
    await _notifications.cancel(id: task.id * 2 + 1);
  }

  Future<void> _schedule(OrbTask task) async {
    final delay = task.due.difference(DateTime.now());
    if (Platform.isAndroid) {
      await Workmanager().registerOneOffTask(
        task.workName,
        'orb.task',
        existingWorkPolicy: ExistingWorkPolicy.keep,
        // Workmanager sends integer seconds to Android. Round up so the OS
        // cannot wake early and miss an unclaimed occurrence.
        initialDelay: _wholeSeconds(delay),
        inputData: {
          'id': task.id,
          'revision': task.revision,
          'due': task.due.millisecondsSinceEpoch,
        },
      );
    } else if (Platform.isIOS && delay > Duration.zero) {
      await _notifications.zonedSchedule(
        id: task.id * 2,
        title: task.title,
        body: task.kind == TaskKind.reminder ? task.body : '点按查看或执行提示词。',
        scheduledDate: tz.TZDateTime.from(task.due, tz.local),
        notificationDetails: _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: switch (task.frequency) {
          TaskFrequency.once => null,
          TaskFrequency.daily => DateTimeComponents.time,
          TaskFrequency.weekly => DateTimeComponents.dayOfWeekAndTime,
        },
        payload: 'task:${task.id}',
      );
    }
  }

  Future<void> _scheduleAppleProcessing() async {
    final tasks = (await store.all()).where((t) => t.enabled);
    try {
      await Workmanager().cancelByUniqueName(_appleIdentifier);
      if (tasks.isEmpty) return;
      final earliest = tasks
          .map((t) => t.due)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      await Workmanager().registerProcessingTask(
        _appleIdentifier,
        _appleIdentifier,
        initialDelay: _wholeSeconds(earliest.difference(DateTime.now())),
      );
    } on PlatformException {
      // iOS may deny discretionary processing. The local notification already
      // scheduled for this task can still open it and run it at the user's tap.
    }
  }

  Future<void> processAppleDue({int? only}) async {
    for (final task in await store.all()) {
      if ((only == null || task.id == only) &&
          task.enabled &&
          !task.due.isAfter(DateTime.now())) {
        await execute(
          task.id,
          revision: task.revision,
          due: task.due.millisecondsSinceEpoch,
        );
      }
    }
    await _scheduleAppleProcessing();
  }

  Future<void> runNow(OrbTask task) => execute(
    task.id,
    revision: task.revision,
    due: task.due.millisecondsSinceEpoch,
    manual: true,
  );

  Future<void> execute(
    int id, {
    required int revision,
    required int due,
    bool manual = false,
  }) async {
    final now = DateTime.now();
    final claim = await store.claim(
      id,
      revision: revision,
      due: due,
      manual: manual,
      now: now,
    );
    if (claim == null) return;
    final task = claim.task;
    final next = await store.find(id);
    if (next?.revision != revision) {
      await store.finish(
        claim.runId,
        status: 'cancelled',
        result: '设置已改变，跳过此次执行。',
      );
      return;
    }
    final scheduled = !manual || task.enabled && !task.due.isAfter(now);
    if (scheduled && next!.enabled) {
      try {
        await _schedule(next);
      } on PlatformException {
        // The next occurrence is persisted and reconciled on app launch. The
        // current occurrence still needs to deliver its reminder or answer.
      }
    }
    String? threadId;
    var result = task.body, status = 'done';
    try {
      if (task.kind == TaskKind.prompt) {
        final chat = OrbStore();
        await chat.open();
        final config = await chat.loadConfig();
        final invalid = config.validationError;
        if (invalid != null) throw OrbException(invalid);
        final user = OrbMessage('user', task.body);
        final input = await richContext(
          config,
          [],
          await chat.memories(),
          user,
          prompts: await loadPromptSettings(chat),
        );
        // Task prompts may work with their own files and skills. Scheduling
        // other tasks is reserved for an interactive user turn.
        final harness = await MobileHarness.forTurn(
          turnKey: 'task:${task.id}:${claim.runId}',
          scheduling: false,
        );
        harness.addInstructions(input);
        final options = ChatOptions(
          tools: harness.tools,
          onTool: harness.run,
          thinking: await chat.preference('thinking') == '1',
          search: await chat.preference('search') != '0',
          readLinks: await chat.preference('read_links') != '0',
          region: await chat.preference('region'),
        );
        final provider = StreamingChatProvider(usagePurpose: '定时任务');
        final reply = StringBuffer(), thought = StringBuffer();
        Map<String, dynamic> metadata = {};
        try {
          await for (final event in provider.replyRich(
            config,
            input,
            options,
          )) {
            reply.write(event.text);
            thought.write(event.thinking);
            if (event.metadata != null) metadata = event.metadata!;
          }
        } finally {
          provider.stop();
        }
        result = reply.toString();
        if (harness.receipts.isNotEmpty) {
          metadata = {...metadata, 'localTools': harness.receipts};
        }
        if (thought.isNotEmpty) {
          metadata = {...metadata, 'thinking': thought.toString()};
        }
        if ((await store.find(id))?.revision != revision) {
          await store.finish(
            claim.runId,
            status: 'cancelled',
            result: '任务设置已改变。',
          );
          return;
        }
        await chat.importThread(claim.source, task.title, [
          user,
          OrbMessage('assistant', result, metadata: metadata),
        ]);
        threadId = await chat.threadIdForSource(claim.source);
      }
    } on OrbException catch (e) {
      result = e.message;
      status = 'failed';
    } catch (_) {
      result = '执行未完成，请检查连接并重试。';
      status = 'failed';
    }
    await store.finish(
      claim.runId,
      status: status,
      result: result,
      threadId: threadId,
    );
    final active = await store.find(id);
    if (active?.revision != revision) return;
    if (Platform.isIOS && !manual && task.kind == TaskKind.reminder) return;
    await _notifications.show(
      id: id * 2 + 1,
      title: task.title,
      body: status == 'failed'
          ? '执行失败：$result'
          : String.fromCharCodes(result.runes.take(140)),
      notificationDetails: _details,
      payload: 'task:$id',
    );
  }
}

Duration _wholeSeconds(Duration delay) => delay.isNegative
    ? Duration.zero
    : Duration(
        seconds: (delay.inMicroseconds / Duration.microsecondsPerSecond).ceil(),
      );
