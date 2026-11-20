import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orb_mobile/core/orb_controller.dart';
import 'package:orb_mobile/ui/chat.dart';

void main() {
  testWidgets('empty chat fits small phone and exposes its primary actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = OrbController()..ready = true;
    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(controller: controller)),
    );
    expect(find.text('有什么\n想聊的？'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('composer')), '你好');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('large system type with keyboard keeps input and header usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: ChatScreen(controller: OrbController()..ready = true),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('composer')), '长辈模式');
    await tester.pump();
    expect(find.byTooltip('模型连接'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
