# 工作区跨产品评测

六道题通过同一条用户消息和一份全新的 UTF-8 工作区衡量交付结果。主指标是完整通过的题数，每题权重相同。子检查用于定位遗漏。工具次数、token、耗时和用户补充操作另行记录。报告应列出运行产品、版本、模型、任务数和每题采样次数。

| 任务 | 交付与验收 |
| --- | --- |
| screening-list | 从 225 场排片中筛出指定场次，生成有序 M3U 并保留原表 |
| rgb-export | 修复颜色导出，交付样例结果。宿主另编译调用共享头文件的独立程序 |
| parcel-lines | 修复原有编译错误，验证空行、结尾换行和未结束的标签行，交付样例计数 |
| event-brief | 合并相继发布的通知，核对最终日程的活动、时间、场地和先后次序 |
| shift-span | 创建可重复使用的 C 程序，验证公开样例、跨午夜和未公开的新班次 |
| active-profile | 根据发布索引修改启用的 JSON 配置，核对其他字段以及预览、归档和旁支文件 |

公共包是一个 JSON 数组，每题包含 `id`、`prompt` 和 `files`。路径统一从 `project/` 开始。下面的命令从仓库根目录运行。冻结的公共包 SHA-256 为 `bd501c2f7b899bdf6b6055c272b202971a30ad3e7a88b63ce8d7b1933098202f`。

```sh
node tool/product_benchmark/cases.mjs pack > /tmp/orb-product-public.json
shasum -a 256 /tmp/orb-product-public.json
node tool/product_benchmark/cases.mjs prepare rgb-export "$CASE_ROOT"
node tool/product_benchmark/cases.mjs prompt rgb-export
```

为每个产品和每次运行准备独立空目录。外部产品从 `$CASE_ROOT` 启动，只能访问其中的 `project/`。Orb 导入同一题的 `files`。发送 `prompt` 的完整原文，并保留产品真实生成的末态。宿主掌握评分脚本、隐藏输入和独立主程序，参与产品的文件工具、命令行和检索功能均应与这些资料隔离。

```sh
node tool/product_benchmark/score.mjs rgb-export "$CASE_ROOT"
node tool/product_benchmark/score.mjs rgb-export --json "$SNAPSHOT"
```

两种评分入口接受同一份末态。目录入口读取 `project/`。JSON 入口接受 `{"files":{"project/main.c":"…"}}` 或直接使用路径到文本的映射。评分器返回 `passed`、通过项数及每项布尔结果。正常完成评分的进程以 0 退出。程序题在宿主提供的 Orb C/Wasm 环境中从提交源码重新编译并执行，另外核对提交的磁盘产物。有效实现可以采用不同的代码或编辑方式，文档格式可以使用列表、表格或普通文本。该样本覆盖文件、文档和 C 工具交付，系统日历等跨应用结果需要相应的原生验收。

### 原生标准 C 交叉评分

在装有 Xcode Command Line Tools 或完整 Xcode 的 macOS 上，可以给同一份末态另算一组 Apple clang 分数。两个入口共用上面的业务断言、未公开输入和文件保留检查。分别报告 C/Wasm 和原生结果，以反映两个宿主对标准库的支持差异。

```sh
node tool/product_benchmark/score_native.mjs rgb-export "$CASE_ROOT"
node tool/product_benchmark/score_native.mjs rgb-export --json "$SNAPSHOT"
```

每次探针在新的临时目录中复制提交的文本文件，以 C11 编译并执行，结束后移除该目录。系统沙箱限制文件访问到临时副本及系统工具链，关闭网络，并限制运行时间与输出。预编译的参赛者二进制不会进入探针。记录所用版本时，Command Line Tools 安装可运行 `/Library/Developer/CommandLineTools/usr/bin/clang --version`，仅装完整 Xcode 时运行 `xcrun clang --version`。

### 两道独立冻结题

库存对账和家庭账单在六道共同题之外独立计分。将对应的 `public.json` 单独提供给参赛者，每次使用新的工作区。初次提交、修复后执行原脚本、修复后新会话重做分别记录。评分器只在主持端运行。

| 任务 | 发给产品的请求和文件 | 主持端评分命令 |
| --- | --- | --- |
| 库存对账 | [公共包](holdouts/stock-reconciliation/public/public.json) | `python3 tool/product_benchmark/holdouts/stock-reconciliation/private/grade.py "$SNAPSHOT"` |
| 家庭账单 | [公共包](holdouts/household-april/public.json) | `python3 tool/product_benchmark/holdouts/household-april/host/score.py "$SNAPSHOT"` |

两个评分器均可读取含 `project/` 的最终目录，或手机导出的路径到文件内容的 JSON。库存核对所有差异行及数量；账单核对两份原始数据、输出文件、表头、分类、各项金额与总计。
