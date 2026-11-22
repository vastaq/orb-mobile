import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/orb_controller.dart';
import 'ui/chat.dart';
import 'core/skill_packages.dart';
import 'core/overlay_engine.dart';
import 'tasks/task_service.dart';
import 'ui/tasks.dart';

@pragma('vm:entry-point')
void orbOverlayMain() => runOrbOverlay();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OrbApp());
}

class OrbApp extends StatefulWidget {
  const OrbApp({super.key, this.controller});
  final OrbController? controller;
  @override
  State<OrbApp> createState() => _OrbAppState();
}

class _OrbAppState extends State<OrbApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  late final OrbController controller = widget.controller ?? OrbController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.reviewAction = reviewAction;
    unawaited(start());
  }

  Future<bool> reviewAction(
    String title,
    String details,
    String confirmLabel,
  ) async {
    final page = navigator.currentState?.overlay?.context;
    if (!mounted ||
        page == null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return false;
    }
    final approved = await showDialog<bool>(
      context: page,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(details),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return mounted &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        approved == true;
  }

  Future<void> start() async {
    await controller.initialize();
    if (!mounted || widget.controller != null) return;
    unawaited(checkSkillUpdates());
    try {
      await initializeOrbTasks(
        onOpen: (id) {
          final page = navigator.currentState?.overlay?.context;
          if (page != null) openOrbTasks(page, controller, taskId: id);
        },
      );
    } on Exception catch (e) {
      debugPrint('Orb task initialization: ${e.runtimeType}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        controller.ready &&
        widget.controller == null) {
      unawaited(checkSkillUpdates());
    }
    if (state == AppLifecycleState.resumed &&
        Platform.isAndroid &&
        controller.ready) {
      unawaited(refreshExternal());
    }
  }

  Future<void> checkSkillUpdates() async {
    try {
      await (await SkillLibrary.open()).refreshSubscriptions();
    } on Exception {
      /* Offline operation keeps the installed skills. */
    }
  }

  Future<void> refreshExternal() async {
    try {
      if (await const MethodChannel('studio.orb/overlay')
                  .invokeMethod<bool>('consumeConversationChanged') ==
              true &&
          mounted) {
        await controller.refresh();
      }
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.reviewAction = null;
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ui = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xff101110),
      systemNavigationBarIconBrightness: Brightness.light,
    );
    return MaterialApp(
      navigatorKey: navigator,
      title: 'Orb',
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xffe6e8dc),
          onPrimary: Colors.black,
          secondary: Color(0xffadbca6),
          surface: Color(0xff181917),
          onSurface: Color(0xffeeece5),
          surfaceContainer: Color(0xff20211f),
          outline: Color(0xff484848),
          error: Color(0xffffa6a6),
        ),
        scaffoldBackgroundColor: const Color(0xff101110),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff101110),
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: ui,
        ),
        dividerColor: const Color(0xff292929),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xff20211f),
        ),
        dialogTheme: const DialogThemeData(backgroundColor: Color(0xff242520)),
      ),
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        value: ui,
        child: ChatScreen(controller: controller),
      ),
    );
  }
}
