# 手机 Orb 的能力边界与扩展方式

## 产品与游戏的关系

手机端的独立价值是每天可用的聊天、可带走的记忆和一个能随时开口的入口。可以先小范围发行，观察用户是否在限流缓解以后还回来，是否主动整理记忆、复用模板。游戏运行时仍在演进，这个版本只依赖模型 HTTP 接口、本地存储和手机系统能力。游戏日后需要继承哪些偏好，可以由玩家挑选资产导入。游戏的规则、事实和进度继续归游戏所有。

## 一次回复的路径

输入来自手机草稿、Android 悬浮球或定时模型任务。前两者复用 OrbController 的发送、落盘和停止逻辑。任务服务单独领取到期任务，以独立对话保存结果，后台执行不会抢走前台正在看的对话。

| 所在位置 | 今天的职责 | 添加能力时改哪里 |
| --- | --- | --- |
| `core/prompt_context.dart`、`turn_context.dart` | 组装个人指令、相关记忆、历史摘录、近期问答和本轮附件 | 调整预算或排序可以复用同一个上下文快照 |
| `core/chat_protocol.dart`、`chat_provider.dart` | 把中立消息转到 DeepSeek、OpenAI Responses、Claude Messages 或兼容协议，处理流、结束原因、引用和多轮工具调用 | 接新协议时只改请求编码和事件解析，保留原生输出块和停止语义 |
| `core/memory_harness.dart`、`orb_store.dart` | 根据用户原话规划新增、更新或遗忘，在 SQLite 事务中应用并留下回执 | 更新已有记忆要匹配读取时的原文，允许用户随后手动修改 |
| `core/mobile_tools.dart`、`ui/compose_tools.dart` | 手机命令与附件选择，产出可编辑文本或附件 | 一个新模板只是一段数据；新原生输入实现相同的草稿返回值 |
| `core/mobile_harness.dart`、`tool_types.dart` | 向已选模型提供本轮工具，执行调用并把结果回送模型，保存回执 | 权限、调度、技能和工作文件在手机端独立校验 |
| `core/workspace.dart`、`skill_packages.dart`、`mcp_client.dart` | 本地工作文件、用户安装的技能包与逐项授权的远端工具 | 工作文件可用内容哈希更新，技能按版本安装，MCP 服务走 Streamable HTTP |
| `core/calendar_tools.dart`、Android Calendar Provider、iOS EventKit | 查询系统日历并在用户确认后更改单次日程 | 原生层检查权限、日历归属与可编辑性，前台展示时间、地点及改动 |
| `core/workspace_program.dart`、`program_runtime.dart`、`assets/program_runner/` | 使用 xcc 编译并运行 C，或在 QuickJS WebAssembly 中执行 JavaScript | 工作区负责限定输入和保存输出，共享 Worker 负责编译、执行和资源上限。Android 与 iOS 仅托管一次执行会话 |
| `core/overlay_engine.dart`、Android 原生服务 | 在其他应用的上层处理手势、录音与播放，经同一聊天控制器保存结果 | 系统窗口与手势留给 Android，共享对话和模型配置 |
| `tasks/` | 聊天与任务页共用一次、每日、每周调度，记录执行和通知 | 同一到期时间只允许一个执行记录。iOS 后台模型执行时间由系统决定 |
| `core/asset_bundle.dart` | 本机资产与普通目录的双向映射 | 新类别增加可读条目和导入预览，破坏兼容的变更升级版本号 |
| `core/token_usage.dart` | 保存服务回报的请求级输入、输出和明细 | 新提供商落实它的计数口径，无法取得完整回报时保留未知 |

Orb 借鉴了桌面 Harness 的工作方式。模型可以先查某个文件、按原文做一次替换，再用工具核实结果。手动启用的技能可以带说明和参考文件。需要访问另一项服务时，用户可通过 MCP 连接选择授权工具。前台聊天逐次展示可写工具的服务和参数，后台仅能调用已授权的只读工具。Android 和 iOS 都在应用沙盒里执行这些操作。当前发版未提供通用终端、任意插件进程或桌面级后台常驻服务。[DeepSeek Harness](https://www.deepseek.com/zh/harness/) · [Agent Skills](https://agentskills.io/specification) · [Android 应用沙盒](https://source.android.com/docs/security/app-sandbox)

## 手机工作区程序

支持执行的 Flutter 引擎会向本轮模型提供 `workspace_run`。Orb 沿用现有工作文件、工具循环和聊天回执。入口可以是已保存的 `.c` 或 `.js` 文件。`stdin_path` 和 `input_paths` 由宿主在入口目录中解析，只有显式选中的文件会交给程序。程序可用随包的标准头文件和 C 库，例如通过 `fgets` 读取一行、通过 `printf` 输出文本、通过 `fopen` 读取已选文件。同一项目的额外 C 翻译单元可以通过 `source_paths` 指定。JavaScript 使用随包的 QuickJS Wasm 解释器，`readText` 可用入口相对名或完整工作区名读取同一个显式选定的文件，`readStdin` 读取标准输入，`console.log` 生成标准输出。编译器和链接器只在临时内存文件系统中工作，运行阶段另建文件系统。支持范围见 [xcc 的 WebAssembly 工具链](https://github.com/tyfkda/xcc#webassembly)。

两端从 App 内置资源启动同一个编译器和 Worker。每个模块最多使用 64 MiB 线性内存，编译和运行各有 8 秒时限。点击聊天的停止按钮会终止当前运行。标准输出和标准错误各限 64 KiB；标准输出和错误预览随工具结果发送至本轮选择的模型，每项最多 8,000 个字符，历史回执各保留最多 1,000 个字符。成功退出后可将完整标准输出保存为工作文件，覆盖已有内容沿用工作区的哈希检查。源码和文本产物可随原有资产包导出。

## 指令、记忆与长对话

头栏名称、个人指令、模板由用户编辑。个人指令持续生效；模板仅在用户选中时进入输入框。自动记忆在回答完成后审阅用户本轮原话，编辑器验证证据，过滤敏感信息，用户可关闭、审阅和删除。手机内保留完整原始记录。

请求按字符预算保留近期完整问答、与问题相关的记忆和本轮附件。长文保留首尾，超出预算的旧对话选取原文节选；这种确定性压缩可以查看，也不需要额外模型调用。字符预算与供应商的 tokenizer 不同。用户可以在回复菜单中查看该轮压缩和取用情况。实际使用量从服务回报单独记账，输入缓存命中是输入的子集。Claude 的基础输入数还要加上缓存读写才能与其他服务的总输入口径比较。[OpenAI 用量字段](https://developers.openai.com/api/reference/python/resources/responses/methods/create) · [Claude 流事件](https://platform.claude.com/docs/en/build-with-claude/streaming) · [DeepSeek 缓存计量](https://api-docs.deepseek.com/guides/kv_cache/)

## 给桌面助手的资产包

`orb.json` 带 `format: orb-assets` 和数字版本。消息体、每条记忆、任务提示和模板分别存为 UTF-8 Markdown；附件保留原始字节和清单中的原名。相同附件在包中只保存一份。普通工作区工具可直接按相对路径读写。无需知道 SQLite 表结构，也无需运行手机端服务。包内 README 是格式说明。

典型往返是勾选一段对话与两条记忆，保存 ZIP，在电脑上解压，按清单定位 `memories/1.md` 修改内容，再把清单与内容放回 ZIP 根目录。回到手机先审阅导入范围。相同对话跳过，发生修改的对话另存副本。记忆用原文哈希匹配，同一原文仍存在时更新；未唯一匹配时保留现有内容并新增。导入任务初始关闭。用户可在资产页选择并删除对话、记忆和任务，或只从对话中移除一个附件。手机保留仍被其他对话引用的原件。

工作文件保存其相对路径，技能以标准 Markdown 和参考资源打包。电脑可以直接编辑和增加文件。带回手机时，工作文件会比对导出时及两端的内容哈希，双端有修改则保留两份。包里去掉某个文件不会删除手机原件。个人配置可以单独选择，模型和工具连接的凭据留在设备上。

可选 WinZip AES 保护文件内容。持有 ZIP 的人仍能看到目录和文件名，包括工作文件的真实相对路径。移动设备与桌面之间通过显式导出和导入交接。格式与冲突规则见[资产迁移](portable-assets.md)。
