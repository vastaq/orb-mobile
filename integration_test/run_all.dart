import 'package:flutter_test/flutter_test.dart';

import 'chat_flow_test.dart' as chat;
import 'queued_chat_test.dart' as queued;
import 'voice_tools_test.dart' as voice;
import 'rich_chat_test.dart' as rich;
import 'schedule_tools_test.dart' as scheduling;
import 'harness_flow_test.dart' as harness;
import 'workspace_program_test.dart' as program;

void main() {
  group('chat_flow', chat.main);
  group('queued_chat', queued.main);
  group('voice_tools', voice.main);
  group('rich_chat', rich.main);
  group('schedule_tools', scheduling.main);
  group('harness_flow', harness.main);
  group('workspace_program', program.main);
}
