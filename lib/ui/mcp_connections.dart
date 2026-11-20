import 'package:flutter/material.dart';

import '../core/mcp_client.dart';

class McpConnectionsPage extends StatefulWidget {
  const McpConnectionsPage({super.key, this.connections});
  final McpConnections? connections;
  @override
  State<McpConnectionsPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpConnectionsPage> {
  McpConnections? store;
  String? error;
  bool busy = false;
  List<McpConnection> rows = [];
  @override
  void initState() {
    super.initState();
    _run(() async {
      store = widget.connections ?? await McpConnections.open();
    });
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
      rows = store?.list() ?? [];
    } on FormatException catch (e) {
      error = e.message;
    } catch (_) {
      error = '无法读取连接，请检查地址、网络或系统凭据后重试。';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _add() async {
    final info = await showDialog<(String, String, String)>(
      context: context,
      builder: (_) => const _AddConnection(),
    );
    if (info == null || !mounted) return;
    await _run(() async {
      final row = await store!.add(info.$1, info.$2, info.$3);
      if (mounted) await _details(row.id);
    });
  }

  Future<void> _details(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _Tools(id: id, store: store!),
      ),
    );
    if (mounted) setState(() => rows = store!.list());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MCP 工具')),
    body: SafeArea(
      child: ListView(
        children: [
          if (busy) const LinearProgressIndicator(),
          ListTile(
            leading: const Icon(Icons.add_link),
            title: const Text('添加工具服务'),
            onTap: busy || store == null ? null : _add,
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Divider(),
          if (!busy && rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('添加可信的 MCP 服务，选择聊天中可以使用的工具。更改数据前会逐次确认。'),
            ),
          for (final row in rows)
            ListTile(
              title: Text(row.name),
              subtitle: Text('${row.origin}\n已允许 ${row.allowed.length} 个工具'),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => _details(row.id),
            ),
        ],
      ),
    ),
  );
}

class _AddConnection extends StatefulWidget {
  const _AddConnection();
  @override
  State<_AddConnection> createState() => _AddState();
}

class _AddState extends State<_AddConnection> {
  final name = TextEditingController(),
      address = TextEditingController(),
      token = TextEditingController();
  String? error;
  @override
  void dispose() {
    name.dispose();
    address.dispose();
    token.dispose();
    super.dispose();
  }

  void submit() {
    try {
      if (name.text.trim().isEmpty) throw const FormatException('请输入名称。');
      mcpEndpoint(address.text);
      Navigator.pop(context, (name.text, address.text, token.text));
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加 MCP 服务'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          TextField(
            controller: address,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Streamable HTTP 地址',
              hintText: 'https://…/mcp',
            ),
          ),
          TextField(
            controller: token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Bearer 令牌（可选）'),
            onSubmitted: (_) => submit(),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('读取工具')),
    ],
  );
}

class _Tools extends StatefulWidget {
  const _Tools({required this.store, required this.id});
  final McpConnections store;
  final String id;
  @override
  State<_Tools> createState() => _ToolsState();
}

class _ToolsState extends State<_Tools> {
  bool busy = false;
  String? notice;
  Future<void> run(Future<void> Function() fn) async {
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await fn();
    } on FormatException catch (e) {
      notice = e.message;
    } catch (_) {
      notice = '操作未完成，请检查连接。';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除此服务和本机凭据？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.remove(widget.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.store.get(widget.id);
    if (row == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('连接已移除。')),
      );
    }
    final ordered = [...row.catalog]
      ..sort(
        (a, b) => b.readOnly == a.readOnly
            ? a.name.compareTo(b.name)
            : a.readOnly
            ? -1
            : 1,
      );
    return Scaffold(
      appBar: AppBar(title: Text(row.name)),
      body: SafeArea(
        child: ListView(
          children: [
            if (busy) const LinearProgressIndicator(),
            ListTile(
              title: SelectableText(row.origin),
              subtitle: const Text('勾选前请确认信任此服务。调用时会把工具参数发给服务，再将结果交给当前模型。'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('刷新清单'),
              onTap: busy
                  ? null
                  : () => run(() async {
                      await widget.store.refresh(widget.id);
                      notice = '工具清单已更新。';
                    }),
            ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(liveRegion: true, child: Text(notice!)),
              ),
            const Divider(),
            if (row.catalog.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('服务未提供工具。'),
              ),
            for (final t in ordered)
              SwitchListTile(
                title: Text(t.name),
                subtitle: Text(
                  t.readOnly
                      ? t.description
                      : '${t.description}\n可能更改数据，每次调用前由你确认。',
                ),
                value: row.allowed.contains(t.name),
                onChanged: busy
                    ? null
                    : (on) => run(() async {
                        widget.store.allow(
                          row.id,
                          t.name,
                          on,
                          permitWrites: !t.readOnly,
                        );
                      }),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('移除连接'),
              onTap: busy ? null : () => run(remove),
            ),
          ],
        ),
      ),
    );
  }
}
