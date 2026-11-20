# Orb 手机个人助手对照

Orb 已能在手机工作区写程序、运行并保存结果。在三款开源通用助手都能完成的跨会话记忆、外部笔记、离开交互后执行任务上，Orb 的 Android 模拟器也都交付了可核实的结果。iOS 已验证到点通知。工作区六道共同题用两家模型各完成五道。下文记录每项验收的产物、首次失败和修复后的成绩；这组样本仅覆盖所列功能与环境。

## 同类产品的公开能力

| 产品 | 值得对照的体验 | 使用条件及官方资料 |
| --- | --- | --- |
| ChatGPT | 用户可管理记忆、断开应用，为应用读写设不同确认策略；计划任务可在用户离线时执行并通知 | 具体连接与权限取决于账号、应用及工作区。[记忆](https://help.openai.com/en/articles/8590148-memory-faq) · [应用权限](https://help.openai.com/en/articles/20001495-managing-app-permissions-in-chatgpt) · [任务](https://help.openai.com/en/articles/10291617-tasks-in-chatgpt) |
| Gemini | 在会话中使用偏好，查改所选日历，管理定时动作 | 连接日历涉及账户、活动记录及具体供应商；记忆与定时动作也受地区、账户和版本影响。[个性化](https://support.google.com/gemini/answer/16598625?hl=en) · [日历](https://support.google.com/gemini/answer/15305236?hl=en) · [定时动作](https://support.google.com/gemini/answer/16316416?hl=en) |
| Apple Siri 与快捷指令 | 可使用个人上下文，快捷指令在获准后可以操作应用，部分自动化能由时间或其他事件触发 | Siri 的个人上下文依赖设备、系统版本和地区。快捷指令的个别动作可能需要交互。[Siri](https://support.apple.com/guide/iphone/get-started-with-siri-ai-iphv6zwrg8jvfgr/27/ios/27) · [快捷指令授权](https://support.apple.com/en-euro/guide/shortcuts/apd961a4fc65/ios) · [自动化](https://support.apple.com/guide/shortcuts/enable-or-disable-a-personal-automation-apd602971e63/ios) |
| 华为小艺 | 支持帮记个人信息，在后续对话中查询；可用自然语言管理日历，重要日期能提醒 | 帮记入口、同步和提醒随鸿蒙及应用版本变化。[小艺记忆](https://consumer.huawei.com/cn/support/content/zh-cn16010214/) · [语音管理日历](https://consumer.huawei.com/cn/support/content/zh-cn16010212/) |

手机编程另有两个直接参照。Termux 在 Android 上提供可安装软件包的终端和 Linux 环境。Code App 在 iPad 上随包提供多个语言运行时，其中 C/C++ 通过 clang 与 WebAssembly 执行。Orb 采用随包提供工具链的办法，使用 xcc 编译 C、QuickJS 运行 JavaScript；模型生成的程序只接收本轮选中的工作区文件和标准输入。[Termux](https://github.com/termux/termux-app) · [Code App](https://github.com/thebaselab/codeapp#the-plan) · [QuickJS](https://bellard.org/quickjs/)

这些资料用于选题。它们无法说明几款助手执行同一条请求的成功率。OpenAI 和 DeepSeek 是 Orb 的模型供应商，调用它们的 API 只计入 Orb 的成绩。

## 可复现的验收

- **记忆**。在真实 SQLite 上启用自动记忆，让模型记录一个合成偏好。重建控制器、重开对话，检查模型回答和实际入选的记忆 ID。再纠正、重新询问、遗忘、重新询问，分别检查数据库、回复和上下文。最后验证明确要求保存一项假密码时不会生成记忆。DeepSeek 和 OpenAI 使用不同测试值。
- **跨应用**。只在独立模拟器的测试日历中操作。核对权限面板、取消后的记录、创建后的实际系统 ID、相交区间查询、修改、删除及另一日历中的无关事件。模型链路另用上轮保存的地点创建日程。在外部笔记场景，实际笔记服务自行保存文本与写入次数，分别验收拒绝、同意、撤销授权。
- **后台**。系统设置中拒绝通知权限时，手机应说明原因并避免新建无法通知的提醒。允许后离开 Orb，由操作系统调度。提醒需要一条真实系统通知；模型任务还须核查独立对话及模型产物。iOS 的按时通知和系统择机提供的后台算力分别验收。
- **编码**。四个产品分别从同一初始工作区开始，只收到公开中文请求。主持端检查最终文件，给 C 程序额外提供未见输入，避免把模型自己的测试当作验收。题目和评分规则见 [用例](../tool/product_benchmark/cases.mjs) 和 [评分程序](../tool/product_benchmark/score.mjs)。

## 已观察到的结果

| 验收项 | 环境 | 观察到的结果 |
| --- | --- | --- |
| 本机记忆生命周期 | Android 模拟器，官方 deepseek-flash 和 gpt-5.4-mini | 两者都在新会话中召回原值，更正后只使用新值；遗忘后不再选入旧记忆，也未猜中合成值。另一次 Android 实测中，存入后由宿主彻底停止 Orb，下一次启动使用不同进程 ID，仍从 SQLite 选中了同一条记忆并正确回答。 |
| 记忆用于跨应用操作 | Android 系统 Calendar Provider，同上两个模型 | 分别在新对话中提出建日程，确认卡展示从前一对话记住的地点。宿主随后读到两条时间、标题、地点均正确的系统记录，无关日历保持原样。 |
| iOS 日历操作 | iPhone 17 模拟器、iOS 26.1 | 系统拒绝后读写失败；系统允许后真实 EventKit 增查改删通过。全天及三次循环的实例保持只读；在 Orb 预览中取消后没有新增记录。点「查看日程」会读取最新 EventKit 记录并展示只读详情，已看到正确标题、时区、时间、地点、日历，并可关闭回到 Orb。iOS 15/16 仅验证编译兼容。 |
| Android 离屏提醒 | Android 36 模拟器，桌面前台 | 拒绝通知权限时返回失败且没有任务入库；允许后返回桌面，WorkManager 运行记录为 done，系统通知栏出现预期标题和正文。 |
| Android 离屏模型任务 | Android 36 模拟器、官方 deepseek-flash | 打开桌面后，后台模型读取了指定文件，保存独立结果对话；重新打开 Orb 前，宿主已从数据库和系统通知中核对到文件里的合成原文。 |
| Android 系统日历 | 专用 Android 16 模拟器、系统 Provider、Google Calendar | 系统权限拒绝/同意、单次日程增查改删通过。错配日历、全天、重复及含其他参会者的会议无法修改，其他记录保持不变。手点打开详情能启动 Google Calendar 的目标 Activity；无账号模拟器随后显示登录页，未验证该客户端显示事件标题。 |
| 独立笔记 | Android、官方 deepseek-flash、独立本机 MCP 服务 | 拒绝后原文不变且写入为 0 次，确认后精确更新为「资料架是青色。」且只有 1 次写入，撤销后该工具从对话目录消失。 |
| iOS 离屏提醒 | iPhone 17 模拟器、iOS 26.1 | 按 Home 后，系统在设定时刻投递通知。桌面出现准确标题和正文；重新打开 Orb 可从系统已送达列表核对同一条。iOS 后台生成模型答案仍受系统择机调度。 |

端侧运行另在 iPhone 17 模拟器核对了 JavaScript 双表计算，结果文件完整保存 17,461 个 UTF-8 字节。DeepSeek 从一句要求写出脚本，换数据后用同一源码再次得到正确结果。该 iOS 用例覆盖入口相对路径；随后新增的完整路径写法已在 Android 上用原失败脚本验证。

另起一轮的库存对账留出题在四个产品首次接触时均通过了 4 项检查。该题与后续家庭账单题的公开请求、输入及独立判分材料都在运行前冻结。[冻结题包与复现命令](../tool/product_benchmark/README.md#两道独立冻结题)

六道编码题首轮的共同模型为 deepseek-flash。按手机 xcc 运行，Orb 为 4/6，Aider 为 3/6，OpenCode 和 Cline 各为 5/6。使用隔离的宿主标准 C 编译器和相同隐藏输入重判完全相同的提交后，分别为 4/6、4/6、6/6、6/6。差别来自班次时长题：两个桌面提交用了 sscanf，另一个用了 ferror。Orb 的两项失败是颜色样例没有落成文件，以及最终议程附带了被取消的活动名。总分要求一道题的全部检查通过。

引入 QuickJS 后，用同一台 Android 模拟器、相同输入和评分器重跑。六道共同题，DeepSeek 和 OpenAI 各完成 5/6；两者都正确合并了保留活动的时间和场地，但又在输出文件中附注了已取消活动，违反「仅列保留活动」。库存对账题另计，DeepSeek 通过，OpenAI 首次使用该题时未通过全部检查。工作区工具便于核实产物，模型每次选取的解法仍有差异。

最后冻结一题家庭账单整理，要求从两张合成 CSV 交付可核实的月度分类结果。所有参赛者仅取得同一条中文请求与初始文件，宿主在它们提交末态后分别检查输入保留、输出文件、分类、金额和总数。Orb + OpenAI 首次 6/6 项通过。Orb + DeepSeek 首次仅保留了原输入，工具回执显示多次运行失败，未产生交付 CSV。首次脚本使用已授权的完整工作区路径，运行器当时只接受入口相对名。修复后，Android 直接重放原脚本通过了全部 6 项检查；之后让 DeepSeek 和 OpenAI 各用全新会话从头完成同一题，两份新月报均通过 6 项检查。Aider、OpenCode、Cline、Goose 和 Hermes 提交的首份月报也各通过 6 项。每个组合每轮只采一次，原脚本回放与新会话复测单独计分。

## 开源通用助手的实际对照

测试均使用官方 DeepSeek Flash。每个产品有独立工作目录和身份状态。记忆题在不同会话中保存、召回、更正、再次召回、遗忘、再询问；笔记题向独立的 MCP 服务写入指定的一句话，由服务自行计数；定时题在用户离开交互后等待时间到达，核实真实文件或结果对话。Orb 在模拟器运行，另外三个产品在开发机的独立环境运行。

| 产品 | 跨会话记忆 | 外部笔记 | 到时执行 |
| --- | --- | --- | --- |
| Orb Mobile | 通过，另在 OpenAI 上通过 | 确认后写入 1 次；取消时 0 次 | Android 离开 App 后将真实模型结果存入新对话；iOS 到时通知，模型执行时机由系统决定 |
| OpenClaw 2026.11.6 | 通过，六个独立会话 | 官方 MCP 连接准确写入 1 次；断开后再次请求仍为 1 次 | 常驻 Gateway 在预定时间开始运行，7 秒后完成，产物和官方记录均可核对 |
| Hermes Agent（ac646d1f） | 通过，实际工作记忆从新增到更正再删除 | 官方 MCP 连接写入精确文本 1 次 | 聊天退出后由官方 Gateway 调度，预定时刻约 62 秒后生成正确文件，原生记录完成 1 次 |
| Goose 1.60.2 | 通过，内置 memory 扩展 | 内置 Streamable HTTP 扩展准确写入 1 次 | 常驻桌面会话得到正确文件和调度记录。请求一次性任务后，年度 cron 条目仍保留，测试结束时手动移除 |

Goose 首次登记遇到测试主机休眠期间的供应商断连，恢复网络后重新指定了未来时间。开放协议的笔记验收使用合成服务，消费端原生日历、账号连接目录、语音唤醒与桌面网关都有独立的使用条件。[OpenClaw MCP](https://docs.openclaw.ai/tools/mcp) · [OpenClaw 调度](https://docs.openclaw.ai/automation/cron-jobs) · [Goose 扩展](https://goose-docs.ai/docs/getting-started/using-extensions/) · [Goose 调度](https://goose-docs.ai/docs/guides/goose-cli-commands/)

## 本机复现

使用可清理的独立模拟器。API 通过开发机回环代理访问，手机只保存测试配置。运行方式、密钥来源和独立设备要求见 [真实 API 验证](evaluation.md)。对 Android 的目标模拟器运行以下命令，先在两个独立终端启动相应的代理。

```sh
python3 tool/provider_test_proxy.py deepseek --port 18961
python3 tool/provider_test_proxy.py openai --port 18962
```

```sh
adb -s "$DEVICE" reverse tcp:18961 tcp:18961
adb -s "$DEVICE" reverse tcp:18962 tcp:18962
flutter test --no-uninstall -d "$DEVICE" integration_test/personal_memory_test.dart \
  --dart-define=ORB_DEEPSEEK_PORT=18961 --dart-define=ORB_OPENAI_PORT=18962
python3 tool/calendar_benchmark.py --device "$DEVICE" seed
```

双模型日历用例使用同样两个端口，入口为 `integration_test/personal_calendar_chat_test.dart`。该用例预期系统日历权限已授予，以便只需核对聊天里的写入确认。独立的原生用例验证首次授权和拒绝。用 `tool/calendar_benchmark.py --device "$DEVICE" inspect` 从系统 Provider 读取结果，最后用 `cleanup` 清理合成日历。

冷启动记忆用例 `integration_test/cold_memory_test.dart` 需在同一专用模拟器上运行两次，并在两次运行之间执行 `adb -s "$DEVICE" shell am force-stop studio.orb.orb_mobile`。两次均使用 `--no-uninstall --dart-define=ORB_COLD_MEMORY=true --dart-define=ORB_DEEPSEEK_PORT=18961`。用例会核实两个进程 ID 不同并清理合成记忆和测试对话。

外部笔记用例先运行 `python3 tool/product_benchmark/notes_service.py --state "$NEW_TEMP_FILE" --port 18965`，其中状态文件须尚未存在。转发 18965 后运行 `integration_test/personal_notes_chat_test.dart`，传入 `ORB_NOTES_PORT=18965` 和 `ORB_DEEPSEEK_PORT=18961`。开发机可通过服务的 `/state` 核对最终内容和写入次数。
