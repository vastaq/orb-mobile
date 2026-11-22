# 在手机连接 MCP 工具

在「设置 → MCP 工具连接 → 添加工具服务」里输入服务名称、Streamable HTTP 地址及可选的 Bearer 令牌。连接时 Orb 会读取工具目录。勾选需要的工具后，当前模型可以在相关请求中使用它。例如给笔记服务的查阅工具授权，再在聊天里说「读一下 reading 这篇笔记，告诉我里面的校验码」。

连接默认没有已允许工具。服务在 MCP annotations 中声明 `readOnlyHint: true` 且未声明破坏性时，Orb 将其视为读取操作。其他工具只在用户启用后出现在前台聊天中，每次调用都会显示服务、工具名和全部参数，点「允许这次操作」才会发送。后台任务只能调用已启用的只读工具。声明由服务作者提供，选择自己信任的工具源。必须允许的工具才会出现在模型的本轮目录；调用前会再次核对远端声明。如果说明、输入结构或读写性质发生变化，需要在设置中刷新清单并重新选择。工具的参数送到相应服务，结果随该轮请求交给当前模型。

支持 HTTPS。开发时也可以使用手机本地的 HTTP 回环地址，例如通过 USB 显式转发一个本机服务端口。支持 MCP 的 Streamable HTTP 请求、JSON/SSE 响应、分页工具目录和会话协商。文本、结构化结果和文本资源可传回模型；目前未接入媒体型结果、stdio 子进程、OAuth 自动登录。手机不会启动服务端代码。

完整地址和 Bearer 令牌由设备安全存储保存。迁移聊天、工作文件或技能时，工具连接及授权保留在原设备。可在连接详情中随时取消勾选、刷新或移除连接。修改凭据时移除旧连接再添加。

[Model Context Protocol · Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) · [工具协议](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
