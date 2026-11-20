import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const overlayChannel = MethodChannel('studio.orb/overlay');

class OverlaySettings extends StatefulWidget {
  const OverlaySettings({super.key});
  @override
  State<OverlaySettings> createState() => _OverlaySettingsState();
}

class _OverlaySettingsState extends State<OverlaySettings>
    with WidgetsBindingObserver {
  Map<String, dynamic>? prefs;
  bool working = false;
  String? error;
  static const defaults = {
    'size': 48.0,
    'opacity': .92,
    'snap': true,
    'tap': 'panel',
    'doubleTap': 'open',
    'hold': 'voice',
  };
  static const taps = {
    'panel': '展开最近回复',
    'open': '打开 Orb',
    'read': '朗读最近回复',
    'stop': '停止播报',
    'none': '无操作',
  };
  static const holds = {
    'voice': '在当前对话说话',
    'newVoice': '在新对话说话',
    'none': '无操作',
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !working) refresh();
  }

  Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final p = await overlayChannel.invokeMapMethod<String, dynamic>(
        'getSettings',
      );
      if (mounted) setState(() => prefs = {...defaults, ...?p});
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> enable(bool value) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      if (value) {
        if (await overlayChannel.invokeMethod<bool>('requestOverlay') != true) {
          throw const FormatException('需在系统设置中允许 Orb 显示在其他应用上层。');
        }
        if (prefs?['hold'] != 'none' &&
            await overlayChannel.invokeMethod<bool>('requestMic') != true) {
          throw const FormatException('长按说话需要麦克风权限，请在系统权限中允许。');
        }
      }
      await overlayChannel.invokeMethod('setEnabled', value);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PlatformException
              ? e.message
              : e.toString().replaceFirst('FormatException: ', ''),
        );
      }
    } finally {
      await refresh();
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> save(Map<String, dynamic> patch) async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      if (prefs?['enabled'] == true &&
          prefs?['hold'] == 'none' &&
          patch['hold'] != null &&
          patch['hold'] != 'none' &&
          await overlayChannel.invokeMethod<bool>('requestMic') != true) {
        if (mounted) setState(() => error = '启用长按说话需要麦克风权限。');
        return;
      }
      final p = await overlayChannel.invokeMapMethod<String, dynamic>(
        'saveSettings',
        {...prefs!, ...patch},
      );
      if (mounted) setState(() => prefs = {...prefs!, ...?p});
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Widget gesture(String title, String key, Map<String, String> actions) {
    final current = prefs![key];
    return ListTile(
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            actions[current] ?? '无操作',
            style: const TextStyle(color: Colors.grey),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: working
          ? null
          : () async {
              final action = await showModalBottomSheet<String>(
                context: context,
                showDragHandle: true,
                builder: (ctx) => SafeArea(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          title,
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                      ),
                      for (final e in actions.entries)
                        ListTile(
                          title: Text(e.value),
                          selected: e.key == current,
                          trailing: e.key == current
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () => Navigator.pop(ctx, e.key),
                        ),
                    ],
                  ),
                ),
              );
              if (action != null && mounted) await save({key: action});
            },
    );
  }

  Widget slider(
    String title,
    String key,
    double min,
    double max,
    String formatted,
  ) => Column(
    children: [
      ListTile(title: Text(title), trailing: Text(formatted)),
      Slider(
        value: (prefs![key] as num).toDouble().clamp(min, max),
        min: min,
        max: max,
        onChanged: (v) => setState(() => prefs![key] = v),
        onChangeEnd: (v) => save({key: v}),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('应用外悬浮球')),
    body: SafeArea(
      child: !Platform.isAndroid
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text('应用外悬浮球适用于 Android。iPhone 可以在 Orb 输入框中使用语音。'),
            )
          : prefs == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Text(error!),
            )
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('在其他应用上显示'),
                  subtitle: Text(
                    prefs!['hold'] == 'none'
                        ? '回到 Orb 时自动收起。'
                        : '回到 Orb 时自动收起。长按说话，松开发送，再次长按可打断朗读。',
                  ),
                  value: prefs!['enabled'] == true,
                  onChanged: working ? null : enable,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Color(0xffffabab)),
                    ),
                  ),
                const Divider(),
                gesture('单击', 'tap', taps),
                gesture('双击', 'doubleTap', taps),
                gesture('长按', 'hold', holds),
                SwitchListTile(
                  title: const Text('拖动后贴边'),
                  value: prefs!['snap'] == true,
                  onChanged: (v) => save({'snap': v}),
                ),
                slider(
                  '展开直径',
                  'size',
                  44,
                  80,
                  '${(prefs!['size'] as num).round()} dp',
                ),
                slider(
                  '不透明度',
                  'opacity',
                  .35,
                  1,
                  '${((prefs!['opacity'] as num) * 100).round()}%',
                ),
                Center(
                  child: TextButton(
                    onPressed: () => save(defaults),
                    child: const Text('恢复默认手势与外观'),
                  ),
                ),
              ],
            ),
    ),
  );
}
