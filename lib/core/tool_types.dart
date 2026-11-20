/// A local capability exposed to the model for this user turn.
class ChatTool {
  const ChatTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

class ChatToolCall {
  const ChatToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

typedef RunChatTool = Future<Map<String, dynamic>> Function(ChatToolCall call);

typedef ReviewAction = Future<bool> Function(
  String title,
  String details,
  String confirmLabel,
);
