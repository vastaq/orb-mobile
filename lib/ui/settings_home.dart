import 'dart:io';

import 'package:flutter/material.dart';

import '../core/orb_controller.dart';
import 'assets.dart';
import 'skills.dart';
import 'tasks.dart';
import 'workspace.dart';
import 'mcp_connections.dart';
import 'usage.dart';
import 'history_transfer.dart';
import 'overlay_settings.dart';
import 'prompt_settings.dart';
import 'preferences.dart';

void openOrbSettings(BuildContext context, OrbController c) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => _Settings(c)));

class _Settings extends StatelessWidget {
  const _Settings(this.c);
  final OrbController c;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: ListenableBuilder(
      listenable: c,
      builder: (context, _) => ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('模型连接'),
            subtitle: Text(c.config.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openModelSettings(context, c),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_border),
            title: const Text('本地记忆'),
            subtitle: Text(c.autoMemoryEnabled ? '自动记忆已开启' : '自动记忆已关闭'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openMemories(context, c),
          ),
          ListTile(
            leading: const Icon(Icons.edit_note_outlined),
            title: const Text('个人指令与模板'),
            subtitle: Text(c.prompts.displayName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPromptSettings(context, c),
          ),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('技能'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SkillManagerPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('定时任务'),
            onTap: () => openOrbTasks(context, c),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('工作文件'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const WorkspacePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('MCP 工具连接'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const McpConnectionsPage(),
              ),
            ),
          ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.bubble_chart_outlined),
              title: const Text('应用外悬浮球'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const OverlaySettings(),
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.bar_chart_rounded),
            title: const Text('模型用量'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const UsageScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('本地资产'),
            subtitle: const Text('管理、导入和导出'),
            trailing: const Icon(Icons.chevron_right),
            onTap: c.busy
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => AssetLibrary(c)),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.move_to_inbox_outlined),
            title: const Text('导入 DeepSeek 对话'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openHistoryImport(context, c),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('数据与隐私'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _Privacy()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于 Orb'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Orb',
              applicationVersion: '0.3.0',
              children: [const Text('本地保存对话和记忆的手机助手。')],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Privacy extends StatelessWidget {
  const _Privacy();
  Widget section(String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: const TextStyle(height: 1.55, color: Color(0xffbdbdbd)),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('数据与隐私')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          section(
            '在这台设备上',
            '对话、记忆、所选附件与任务记录保存在应用私有目录。模型密钥由系统安全存储保存。你可以在对话菜单和记忆页分别删除记录。',
          ),
          section(
            '发送给模型的内容',
            '发送时，当前输入、所选附件、近期上下文和相关记忆会交给你选择的模型服务。开启自动记忆后，Orb 还会请该服务判断是否需要更新记忆。模型服务按自己的条款处理请求和计费。',
          ),
          section(
            '联网、文件与语音',
            '联网工具会让服务搜索或读取链接。DeepSeek 文档解析需要将原件上传到它的 Files API；清除本地对话不会删除供应商保存的远端文件。语音输入将录音交给所选语音服务转成文字，朗读会发送要播放的文字。',
          ),
          section(
            '手机权限',
            '相机、相册、麦克风由你使用相应功能时调用。Android 悬浮球需单独允许在应用上层显示；它处理自身手势，不读取下层应用内容。通知用于你设置的任务和正在运行的服务。',
          ),
          section('分享与回答', '点击系统分享后，由你选择接收方。模型生成的回答可能有误，重要信息请核实。'),
        ],
      ),
    ),
  );
}
