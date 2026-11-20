# Orb Mobile 0.3.0 验证与能力边界

## 桌面 Harness 中能在手机复用的部分

| 使用场景 | Orb 已有的行为 | 实际验证 |
| --- | --- | --- |
| 对话中调用工具 | 模型可连续调用多个工具。手机验证参数、执行、回传结果，并在该轮保留可展开的执行记录。 | DeepSeek/兼容、OpenAI Responses、Claude Messages 的流式协议分别测试。实际对话完成新建提醒、改时间、写入与修改工作文件。 |
| 文件工作区 | 可列举、搜索、读取、创建、按原文精确替换。覆盖旧内容时检查版本。 | 通过随后再次读取的正文核对成功写入，已变化的旧版本会得到冲突结果。 |
| 定时任务 | 单次、每天、每周。聊天与任务页共用本地存储和系统调度器。定时模型任务可在工作区读取或写入，并记录运行结果。 | Android 实测系统自动调起后台任务；iOS 验证了本地安排和「立即运行」路径，背景模型执行时间由系统分配。 |
| 扩展 | 可导入标准 Markdown 技能，主动启用，订阅更新、验证新版本和回退。远端服务可用 MCP Streamable HTTP。 | 实测技能从文件安装、启用、更新、回退及导出。真实 MCP 服务验证授权、读取校验码和撤销后停止调用。 |
| 迁移数据 | 选择对话、附件、记忆、提示、任务、工作文件和技能。ZIP 有 Markdown 索引，桌面可直接读写。支持旧包、加密包、双端冲突保留和重复导入。 | Android 系统文件选择器配合桌面压缩工具往返。Claude Code 改写的工作文件导回后内容匹配，OpenCode 也按索引读到了正文。 |

独立安装默认选中云端 DeepSeek，支持用户自己的 OpenAI、Claude 或兼容服务。手机保留数据和执行工具，发送前需配置所选服务。应用没有内置推理模型或任意终端进程。Android 上可以安装终端环境。Orb 内置的工具作用于自己的应用沙盒和用户授权的服务，远端 MCP 当前可选只读工具。桌面助手是否会自动发现技能，取决于它采用的技能目录约定。[Android 应用沙盒](https://source.android.com/docs/security/app-sandbox) · [Agent Skills](https://agentskills.io/specification) · [MCP 工具](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

## 验证范围

- 运行静态分析、整个 Flutter 单元及组件套件和六个原生集成测试文件。集成覆盖普通聊天、排队、语音打断与录音、记忆和续写、文档与图像、创建及执行任务和工作文件。受控服务负责产生已知的模型输出，实际文件与任务写入均由手机完成。
- Android 实体机验证应用外悬浮球、左右贴边、点开面板、长按及回到应用后收起。模拟器另测最小与最大直径、自由拖动、重新开启贴边和横竖屏。语音有静音、风噪、低音量预录人声与服务返回无语音的对照。
- iOS 使用模拟器。商业云服务的账号权限、实时价格、响应质量及线上可用性未用个人付费密钥实测。早期使用过真实测试模型跑通能力，后续回归可直接用受控 HTTP 服务。
- 桌面互通覆盖 Claude Code 和 OpenCode。Codex CLI 搭配当次测试推理服务时在工具协议协商阶段停止，未取得其实际读写记录。普通 Markdown、相对路径和原始附件仍可由通用文件工具打开。

## 复现不依赖模型的全量回归

在装有 Python 3 和 Pillow 的环境启动 `python3 tool/protocol_fixture.py`。服务仅监听当前电脑的回环地址，默认不写日志。它为现有用例返回流式协议数据，检查附带的文档、图片像素和工具回执。Android 测试设备需通过 ADB 转发该测试端口，并允许 Orb 使用麦克风；iOS 模拟器可直接访问主机回环地址。

```sh
flutter analyze
flutter test
flutter test -d "$DEVICE_ID" integration_test/run_all.dart \
  --dart-define=ORB_TEST_BASE_URL=http://127.0.0.1:18334/v1 \
  --dart-define=ORB_TEST_MODEL=orb-fixture-text \
  --dart-define=ORB_TEST_VISION_URL=http://127.0.0.1:18334/v1 \
  --dart-define=ORB_TEST_VISION_MODEL=orb-fixture-vision \
  --dart-define=ORB_TEST_NATIVE_AUDIO=true
```

在明确提供无声麦克风输入的测试设备上，还可启用 `--dart-define=ORB_TEST_SILENT_MIC=true` 验证零转写调用。实体机语音质量和云服务模型表现需要各自的实际输入与服务凭据。

## 0.3.0 build 7 实测结果

Flutter 静态分析通过，72 个单元和组件用例通过。Android 和 iOS 模拟器分别通过六个文件中的七项集成用例。最新 APK 已在 vivo 实体机核对安装哈希。三次自然环境下的长按均未触发聊天或朗读，其中两次向受控转写端发出请求并得到空结果。这个数字反映当前样本，附近真实人声仍可能进入转写。

393 × 852 视口首页和侧栏的 SSIM 分别为 0.986767、0.990377。48 dp 悬浮球的左贴边、右贴边和自由态为 0.991029、0.989947、0.993020，均达到 0.98 门槛并完成独立语义复核。资产导入预览为 0.965656，技能列表为 0.977350；两页的操作和文字可读性验收通过，仍有字体、图标的像素差异，正式视觉门均未通过。
