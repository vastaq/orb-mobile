# 在手机和电脑之间携带技能

一个技能可以只有一份 UTF-8 的 `SKILL.md`。文件顶部的 YAML 指定稳定的名称和描述，下面的 Markdown 写模型应遵循的指令。例如把下列内容保存为 `SKILL.md`，在 Orb 的「设置 → 技能 → 导入技能文件」中选择它。

```markdown
---
name: reading-note
description: 将用户提供的书摘整理成一条读书笔记。
metadata:
  display-name: 读书笔记
  version: "1.0"
---
保留用户给出的原文与页码，另起一段写一条阅读感想。缺少页码时留空。
```

启用后，技能会出现在聊天的工具里。可以在详情里查看原始指令、停用技能、导出 ZIP。普通的 Markdown 编辑器可以打开导出的文件。作者写了新版本时，递增版本号，重新导入即可。只含标准 `name`、`description` 的本地文稿也可导入，手动导入的修改保留上一稿。

## 带参考资料的 ZIP

将 `SKILL.md`、可选的 `skill.json` 和相对路径下的文本资源一起压缩。也支持 ZIP 外面多一层技能目录。模型可按所需路径读取包内文档，例如 `references/format.md`。在 `references/` 或 `assets/` 内可带 Markdown、纯文本、CSV、JSON、YAML。根目录中的 README 和 LICENSE 可随包导出。ZIP 与解压后的内容各限 1 MiB，最多 40 个文件。

```json
{
  "format": "orb-skill",
  "formatVersion": 1,
  "id": "reading-note",
  "name": "读书笔记",
  "version": "1.1",
  "minHostVersion": 1
}
```

`id` 由小写字母、汉字、数字和连字符组成。版本由一至三段非负整数组成。新宿主要求、依赖桌面脚本、申请额外权限的技能会在安装时提示。技能可组合的设备操作由本版 Orb 提供，另一个应用的文件或系统权限不会随包迁移。

## 更新与回退

在「从链接导入」输入一个直接返回 ZIP 或 SKILL.md 的 HTTPS 地址，可先查看名称、说明、来源和指令再安装。本地作者也可在 `skill.json` 声明 `updateUrl`，或在 SKILL.md 的 `metadata` 声明 `update-url`。地址应当持续指向同一 ID 的当前版本。

在技能详情里选择「检查更新」，或者主动开启「自动更新」。自动更新在打开应用时检查，每个已启用技能至多每 12 小时检查一次。下载、兼容检查、同 ID 和版本检查全部通过后，手机才切换版本。网络失败时可以继续使用已有版本；新来源需要手动导入确认。需要撤销时点「回退到上一版」，同时关闭自动更新。移除技能会同时移除手机上的当前版和前一版。

[Agent Skills 文件格式](https://agentskills.io/specification)
