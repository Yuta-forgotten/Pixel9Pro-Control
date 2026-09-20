# Pixel9Pro-Control 后续改造与审计计划

计划状态：Accepted，按阶段实施中
目标仓库：pixel9pro_control_v2
当前源码基线：pixel9pro_control v4.5.09 / versionCode=114
适用设备：Pixel 9 Pro（caiman）、Pixel 9 Pro XL（komodo）
适用 Root：APatch、KernelSU、Magisk

## 1. 计划目标

本计划用于指导下一轮模块改造、分阶段提交、代码复查、包级验证和后续 PRO XL 实机验证。

目标是形成一个按设备和 Root 类型自动分流、功能可选、日志可完整审计、失败可回滚的模块。

目标行为：

- 按 ro.product.device 自动选择 caiman / komodo。
- 按 Root 类型选择 APatch、KernelSU、Magisk 行为。
- 首次安装明确询问主要功能是否启用。
- 每个安装步骤保留音量键倒计时。
- 温控默认使用系统自带配置。
- 官方内核保持当前调度方案。
- 非官方或未知内核自动关闭不兼容的调度写入。
- caiman 使用三档 UECap。
- komodo 使用单文件 XL UECap candidate。
- 日志不包含个人隐私数据。
- 构建阶段拒绝 CRLF、BOM、路径遍历和错误 ZIP 元数据。
- 功耗统计导出必须同时提供可阅读摘要、机器可读数据、原始采样、数据质量和来源边界，不能只导出基础电量与温度两张简表。



## 2. 当前证据和问题边界

### 2.1 实际源码基线

- 正式工作仓库：`E:\Pixel ADB\pixel9pro_control_v2`。
- Git 基线：`1966613a1d12cb352d469e4ad693ddc6a72d9217`，分支 `main`，上游 `origin/main`。
- 当前版本：`v4.5.09 / versionCode=114`。
- Desktop 下的 `Pixel9Pro-Control-main` 是无 `.git` 的来源副本，不在该目录直接实施或提交。
- 旧 WSL/fixture/smoke 脚本只作为历史实现参考，不作为本轮完成标准。

### 2.2 已确认的实现差距

- 安装器当前默认生成 `+4°C` 温控 overlay，不符合“system 默认不覆盖”。
- 调度当前有 profile/owner/boot transaction，但没有独立的 capability 状态和统一 `off` 门禁。
- 当前 ZIP 只携带 caiman payload；komodo 安装路径会删除整个 UECap payload 目录。
- 当前功耗导出只有基础 Markdown 元数据和两段原始 CSV，缺少窗口质量、ODPM、系统归因、来源说明和机器可读摘要。
- 当前 `.gitattributes` 和构建链没有覆盖全部运行时文本、BOM、确定性 ZIP、重复 entry、权限和 staging payload 审计。
- 计划中旧的固定 PowerShell/Python 私有路径在当前主机不存在，必须改为仓库内 Python 标准库工具。




### 2.3 温控边界

非官方内核不自动等于温控不可用。需要确认 vendor Thermal HAL、thermal sensor、cooling device、vendor.thermal.config 和有效 overlay 路径仍兼容。



### 2.4 调度边界

当前 auto 是温度和充电状态驱动的 profile 自动切换，不是“检测到非官方内核后自动禁用调度”。

- auto：自动切换 profile，不等于关闭。
- manual：停止自动切换，但仍可能应用手动 profile，不等于关闭。
- default：写入系统默认调度基线，不等于关闭。
- off：停止本模块调度 mutation 和 worker 写入。
- external：真实外部调度器接管，不是通用关闭按钮。

## 3. 设计原则

1. 温控、调度、UECap、NR、SIM2、VM/ZRAM 是独立功能面。
2. SKU 由 ro.product.device 硬门禁决定，不让用户手动选择 caiman 或 komodo。
3. Root 能力按 APatch、KernelSU、Magisk 分开探测。
4. 温控默认使用系统配置，默认不修改系统默认的调度，自定义温控必须显式选择。
5. 官方内核且能力完整时保持当前调度行为。
6. 未知或不兼容内核只关闭调度控制面，不影响温控。
7. 发布 ZIP 同时携带 caiman 与 komodo 的设备隔离 staging payload；运行时只允许当前 SKU 的 payload 激活，XL 单文件不伪造成 caiman 三档。
8. 所有 mutation 遵循校验、捕获、写入、复读、提交、失败回滚、回滚复读。
9. 日志只记录可审计事实，不记录用户隐私。
10. 所有运行时文本使用 LF，构建器拒绝 CRLF 和 BOM。
11. 每个独立代码计划通过定向门禁后创建一个中文 Conventional Commit。
12. 新验证不依赖旧 smoke/fixture 套件；以生产路径静态合同、确定性包审计和真实设备行为为准。

## 4. 共享功能状态合同

建议统一维护以下状态：

- .thermal_policy
- .scheduler_mode
- .scheduler_policy
- .scheduler_profile
- .scheduler_capability
- .scheduler_capability_receipt
- .uecap_policy
- .uecap_mode
- .payload_state
- .feature_nr
- .feature_sim2
- .feature_vm
- .feature_power_export
- .device_variant
- .root_family
- .state_schema
- .install_receipt

必须区分：

- desired state：用户选择。
- effective state：当前实际采用。
- capability：设备当前能力。
- receipt：本次操作的证据摘要。

建议状态值：

- thermal_policy：system、custom。system 是唯一零修改选项，UI 文案为“不修改温控（不添加配置）”；custom 只展示真正改变阈值的档位。
- scheduler_mode：active、off、observe。只有 active 允许 mutation；off 和 observe 均禁止写调度节点，observe 仅保留只读状态采集。
- scheduler_policy：auto、manual，只在 scheduler_mode=active 且 owner=pixel 时生效。
- scheduler_profile：balanced、battery、default；performance 仍只允许内部诊断，不作为安装器/WebUI 常规选项。
- scheduler_owner：pixel、external。external 是 owner，不是 scheduler_policy；default 是 profile，不是 scheduler_mode。
- scheduler_capability：supported、partial、unsupported、unknown。
- uecap_policy：managed_profiles、single_candidate、stock、disabled。
- payload_state：verified、stock、candidate、unverified。

调度状态转换约束：

- `supported + active + pixel`：允许 boot reconcile、手动 profile 和 auto worker。
- `partial + observe`：只显示已探测能力，不启动 auto/repair，不写任何节点。
- `unsupported|unknown + off`：不运行 reconcile、health repair、owner mutation 或 profile mutation。
- `external` owner：保留外部调度状态读取，不把 external 映射成通用 off。
- capability 变化必须先写 receipt，再原子提交 effective mode；失败保持或回退到 off。

## 5. 首次安装向导

### 5.1 向导顺序

1. 设备与 Root 检测。
2. overlay、Thermal、调度和 UECap 能力摘要。
3. 温控功能选择。
4. CPU 调度功能选择。
5. UECap 功能选择。
6. NR 息屏降级选择。
7. SIM2 空槽管理选择。
8. VM/ZRAM 策略选择。
9. 显示最终摘要。
10. 倒计时确认并提交。

### 5.2 倒计时要求

- 保留音量键交互。
- 每一步显示当前选项、默认值和剩余时间。
- 超时后使用安全默认值。
- 无输入时不能无限等待。
- 最终提交前再次显示完整摘要。
- 失败时显示阶段、错误码和回滚结果。

### 5.3 功能默认值

| 功能 | 首次安装选项 | 官方内核默认 | 非官方或未知内核默认 |
|---|---|---|---|
| 温控 | 不修改温控（不添加配置） / 自定义偏移 | 不修改 | 不修改 |
| CPU 调度 | 现有策略 / 禁用本模块调度 | 保持现有方案 | 自动关闭 |
| UECap | 按设备模式 / 系统默认 / 禁用 | caiman 三档 | komodo stock，显式选择后才使用单文件 candidate |
| NR 息屏降级 | 启用 / 禁用 | 保持当前默认 | 保持当前默认 |
| SIM2 空槽管理 | 启用 / 禁用 | 保持当前默认 | 保持当前默认 |
| VM/ZRAM | 系统默认 / 模块优化 / 禁用 | 系统默认 | 系统默认 |
| WebUI/状态读取 | 始终保留 | 保留 | 保留 |

升级时只迁移用户选择，不迁移临时 transition、health、terminal、rollback marker、当前 boot owner 和临时 receipt。

## 6. Root 兼容性

### APatch

检查活动 MetaModule、module.prop、metamodule=1、disable 状态和 mnt 目录。必须区分 staged tree、MetaModule content image、有效 overlay、active module 和 runtime receipt。

### KernelSU

重点验证 system/vendor 是否有活动 MetaModule 覆盖。模块目录存在或安装退出码为零不能代替重启后有效路径复读。

### Magisk

保留温控、CPU 调度、VM/ZRAM、NR、SIM2 和 WebUI。Magisk 不激活 UECap binarypb，安装器写入 uecap disabled 状态并跳过 UECap 向导。

## 7. 日志和错误

安装器界面日志要短、清晰、可操作；模块私有日志放在 /data/adb/pixel9pro_control/logs/，目录 0700，文件 0600，并做大小限制和轮转。

允许记录：

- module_version
- schema_version
- root_family
- device_codename
- android_api
- feature selections
- phase
- operation
- result
- reason_code
- duration_ms
- source hash
- payload hash
- readback hash
- rollback result
- reboot_required

禁止记录：

- 序列号、IMEI、MEID、IMSI、ICCID、电话号码。
- Wi-Fi MAC、蓝牙 MAC、Google 账号、邮箱。
- 完整 ADB endpoint、完整 build fingerprint。
- 完整 installed package list、用户路径。
- 完整 modem 日志、原始 logcat、完整 dumpsys。

建议错误码：

- ROOT_UNSUPPORTED
- ROOT_OVERLAY_UNAVAILABLE
- DEVICE_UNSUPPORTED
- DEVICE_CONTRACT_INVALID
- TEXT_ENCODING_INVALID
- CONTRACT_CRLF
- THERMAL_STOCK_MISSING
- THERMAL_CONFIG_INVALID
- THERMAL_READBACK_MISMATCH
- SCHEDULER_CAPABILITY_UNKNOWN
- SCHEDULER_CAPABILITY_UNSUPPORTED
- SCHEDULER_WRITE_FAILED
- SCHEDULER_READBACK_MISMATCH
- UECAP_PAYLOAD_MISSING
- UECAP_PAYLOAD_HASH_MISMATCH
- UECAP_CROSS_SKU
- UECAP_OVERLAY_UNAVAILABLE
- UECAP_BIND_FAILED
- UECAP_READBACK_UNCONFIRMED
- ROLLBACK_COMPLETE
- ROLLBACK_INCOMPLETE
- REBOOT_REQUIRED
- RUNTIME_UNVERIFIED

CGI 不得用 HTTP 200 和 ok=true 包装真实失败。

## 8. 温控改造

首次安装默认 thermal_policy=system。

system 模式：

- 不覆盖 /vendor/etc/thermal_info_config.json。
- 不生成新的 thermal_info_config.json。
- 不把 stock JSON 复制到模块 overlay。
- 不因为安装模块就改变系统温控。

system 是唯一不创建 overlay 的模式；不得再增加“本模块不管理”或 custom 0°C 等同义入口。任何模式都不得停止、屏蔽或删除系统 Thermal HAL。

只有用户显式选择 custom 时才允许：

1. 读取当前有效 thermal_info_config 文件。
2. 读取 vendor.thermal.config。
3. 以当前设备真实有效文件为基线。
4. 生成偏移后的配置。
5. 校验 JSON、目标 sensor 和槽位数量。
6. 保留 NAN 和最终 SHUTDOWN 槽位。
7. 校验阈值严格递增。
8. 校验 HotThreshold/HotHysteresis overlap。
9. 写入 overlay。
10. 复读有效路径。
11. 失败时删除 overlay 并恢复系统配置。

非官方或未知内核默认使用系统配置。自定义温控必须先确认 Thermal HAL、sensor、cooling device 和 overlay 能力。

## 9. 调度能力和自动关闭

新增 scheduler capability 共享库，探测：

- cpuset 节点存在和可读。
- sched_pixel/response_time_ms 存在。
- sched_util_clamp_min 存在。
- vendor scheduler L2 存在。
- 权限正确。
- 写入后 readback 一致。
- profile transaction 可回滚。

策略：

- supported：保留官方 auto、manual、default 行为。
- partial：默认关闭 auto，只允许已验证的有限操作。
- unsupported 或 unknown：scheduler_mode=off，停止 scheduler mutation 和 worker 写入，保留温控、WebUI 和状态读取。

不能单纯根据 Sultan 字符串、uname -r、模块目录或退出码判断能力。

## 10. UECap 双 SKU

建议使用：

- config/uecap_devices.tsv
- config/uecap_payloads.tsv

设备合同包含 device、label、policy、target、default_mode、candidate_state。

Payload 合同采用一行一个 payload，包含 device、mode、source、target、bytes、sha256、state、source_build。

caiman 保留 balanced、special、universal，全部使用 PLATFORM_9055801516233416490.binarypb。

komodo 只提供：

- 系统默认或 stock。
- XL 单文件 candidate。
- 禁用 UECap 写入。

生产安全默认是 komodo stock/external。测试版中用户明确选择后才允许 single candidate。

一个 ZIP 必须同时携带两个 SKU 的 staging payload，但不得在 ZIP 的 `system/vendor/firmware/uecapconfig/` 中预置任一 SKU 的 canonical target。建议固定布局：

- `payloads/uecap/caiman/PLATFORM_9055801516233416490.{balanced,special,universal}.binarypb`
- `payloads/uecap/komodo/PLATFORM_6287228797510365516.candidate.binarypb`

安装器读取 `ro.product.device` 后，只解析当前设备在 `config/uecap_devices.tsv` 和 `config/uecap_payloads.tsv` 中的行，校验 source 路径、文件大小和 SHA-256，再将匹配文件放入模块私有 runtime staging。MetaModule mount 完成后只 bind 当前设备的 canonical target：

- caiman → `/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.binarypb`
- komodo → `/vendor/firmware/uecapconfig/PLATFORM_6287228797510365516.binarypb`

另一 SKU 的 staging 文件保留在模块私有目录但不可解析、不可 bind、不可出现在有效 `/vendor` target 中。komodo candidate 缺失、hash 不符或来源 build 不匹配时必须保持 stock，不能降级使用 caiman 文件。

禁止：

- 两个 SKU 同时激活。
- caiman 文件改名为 komodo。
- komodo 文件改名为 caiman。
- 设备变化后沿用旧 SKU 状态。

APatch/KernelSU 需要在 MetaModule mount 完成后执行 canonical target bind、有效 /vendor 复读、hash 对比和 runtime receipt。Magisk 不激活 UECap。

## 11. 功耗统计与导出合同

导出入口继续支持 15、30、60 分钟和当前 WebUI session，但每次导出必须创建一个独立目录，至少包含：

- `report.md`：面向用户的中文摘要、警告、来源和解释。
- `summary.json`：固定 schema 的机器可读摘要。
- `power.csv`：窗口内原始电池采样。
- `thermal.csv`：窗口内原始温度采样。
- `attribution.csv`：用户明确导出时的系统分项和 Top 应用归因；不得导出完整 installed package list。

`summary.json` 至少包含：

- schema/module version、生成时间、窗口类型、开始/结束时间和 elapsed。
- battery status、level、charge counter、外接电源和充放电状态变化。
- samples、effective_samples、coverage ratio、coverage quality、baseline 是否补齐。
- discharge/charge/net mAh；只有 quality 可信且覆盖率达到门槛时才输出平均 mAh/h 和 mW。
- 温度 min/avg/max、采样数和缺口数量。
- ODPM modem/RFFE delta、quality、baseline/endpoint 状态和“不等于整机功耗”的说明。
- batterystats window、model quality、系统分项、Top 应用条数和“系统估算不等于硬件计量”的说明。
- 各字段 source、limitations 和缺失原因，禁止用 0 伪装未知值。

导出事务要求：

1. 请求必须通过 loopback、token、JSON 和锁校验。
2. 输出目录名只允许时间戳和受控 suffix，拒绝路径穿越。
3. 所有文件先写临时目录，完成后原子 rename；失败清理临时目录。
4. 返回每个文件的路径、字节数和 SHA-256；部分写入不得返回 `ok=true`。
5. 导出文件不得包含序列号、IMEI/IMSI/ICCID、电话号码、MAC、账号、完整 fingerprint、完整包列表或原始 dumpsys/logcat。
6. WebUI 必须显示导出文件列表、统计窗口、样本数、数据质量和警告，而不是只显示一个路径。

## 12. 跨平台文本与构建错误封堵

.gitattributes 至少覆盖：

- *.sh text eol=lf
- *.tsv text eol=lf
- *.prop text eol=lf
- *.json text eol=lf
- *.js text eol=lf
- *.html text eol=lf
- *.css text eol=lf
- *.md text eol=lf
- *.binarypb binary
- *.zip binary

仓库内 `tools/build_module.py` 在打包前拒绝：

- CRLF
- UTF-8 BOM
- 反斜杠 ZIP 路径
- 绝对路径
- ..
- tests、docs、logs、scratch 目录
- 个人数据
- 重复 ZIP entry、符号链接、设备文件和超出上限的单文件
- 未在 payload 合同声明的 binarypb
- payload bytes/hash 与合同不一致

合同读取端可以做回车字符防御性清理，但不能代替源文件 LF 门禁。

## 13. 验证计划

本轮不以历史 smoke/fixture 数量作为完成依据。旧测试不删除，但不要求为了适配 Windows/MSYS/WSL 测试环境而修改生产代码。每一阶段验证生产合同本身：

Host/parser：

- git diff --check
- Python 标准库源码/包审计
- Node `--check` 校验 WebUI JavaScript
- JSON/TSV 合同解析
- 所有运行时文本 LF 检查
- Android 或兼容 POSIX shell 的 `sh -n`；若主机无可靠 shell，在设备侧执行并记录证据
- 无 BOM 和路径遍历检查

安装器：

- 首次安装无输入
- 每步倒计时
- 超时安全默认
- 用户取消
- 未知设备
- 未知 Root
- Magisk UECap 跳过
- KSU/APatch 无 MetaModule
- 升级状态迁移
- 失败回滚

温控：

- system policy 不产生 thermal overlay
- custom policy 读取真实 stock
- stock 缺失 fail closed
- 非法 JSON 回滚
- SHUTDOWN 不变
- 阈值递增
- hysteresis overlap
- 写入失败 rollback complete
- 回读失败 rollback incomplete

调度：

- 完整节点 supported
- 缺少节点 partial 或 unsupported
- 不可写 unsupported
- readback mismatch unsupported
- rollback failure off
- unknown kernel off
- official fixture 保持旧行为
- off 状态不写调度节点

UECap：

- caiman 三档
- komodo 单文件 candidate
- unknown 失败
- 缺少 XL 文件失败
- XL hash 错误失败
- caiman 引用 XL 失败
- komodo 引用 caiman 失败
- 共享 target 失败
- 两个 SKU 同时激活失败
- bind 失败回滚到 stock
- Magisk 不激活
- CRLF contract 构建失败

日志：

- 不出现 IMEI、IMSI、ICCID、号码、MAC、序列号、用户路径和完整 fingerprint。
- 错误码、阶段、rollback、readback 存在。
- 日志权限和大小正确。

## 14. 主机静态验证边界

主机 Python/Node/POSIX parser 可以验证：

- Shell 语法、LF/CRLF/BOM。
- TSV 合同和设备分流。
- Root fixture。
- caiman/komodo payload 选择。
- 文件名、目录和 hash 约束。
- thermal JSON、阈值和 hysteresis。
- scheduler capability fixture。
- rollback fixture。
- 日志脱敏。
- 确定性构建和 ZIP 审计。

主机静态验证不能证明：

- APatch MetaModule overlay 实际生效。
- KernelSU metamodule 实际生效。
- Magisk vendor.cbd 早期 mmap 行为。
- PRO XL Thermal HAL 和 thermal sensor/cooling 语义。
- PRO XL modem 是否加载 binarypb。
- modem reload、IMS、VoLTE、VoNR。
- 弱覆盖稳定性、重启持久化、SELinux 阻断。
- 卡 G logo、卡第二屏或 bootloop。

主机结论必须写成：

- Host static PASS
- Host contract PASS
- Fixture behavior PASS
- ZIP package PASS
- PRO XL runtime [unverified]
- PRO XL reboot [unverified]
- PRO XL modem load [unverified]

## 15. 分阶段中文 Commit

每个独立代码计划通过定向门禁后创建一个中文 Conventional Commit。不得把未完成的下一阶段混入当前提交。

C0：
docs(plan): 明确双 SKU 载荷与功耗导出合同

C1：
build(contract): 增加跨平台文本与确定性打包门禁

C2：
feat(installer): 增加功能状态、首次安装选择与 receipt

C3：
feat(logging): 增加隐私安全日志、轮转和结构化错误码

C4：
feat(thermal): 默认使用系统温控配置

C5：
feat(scheduler): 增加内核能力探测和调度关闭模式

C6：
feat(uecap): 完成 caiman 与 komodo 的双 SKU 分流

C7：
feat(energy): 完善功耗统计导出与数据质量说明

C8：
release(audit): 完成双 SKU、Root 和确定性包级审计

C9：
docs(control): 更新温控、调度、功耗与 XL candidate 兼容边界

每个 commit 正文必须包含：

- 范围。
- 行为变化。
- 已执行验证。
- 未执行验证。
- 证据边界。
- 回滚方法。

每个 commit 后执行：

- git status --short
- git show --stat --oneline HEAD
- git show --check HEAD
- 检查无关文件
- 执行本阶段定向测试
- 保存 source fingerprint
- 保存测试输出
- 记录 [unverified] 项
- 记录回滚方式

不允许 squash、reset --hard、checkout -- 或把旧 dirty change 伪装成新 commit。

## 16. 当前 dirty worktree

当前正式仓库从 `origin/main` 新克隆，C0 开始前只有本计划文档为未跟踪文件。实施时：

- 只 stage 本阶段实际修改的文件或行。
- 不使用 git add -A。
- 不覆盖用户已有 dirty change。
- 同一文件有旧 dirty change 时精确拆分。
- 无法安全拆分时暂停该文件并记录阻塞原因。

## 17. 构建和 ZIP 审计

必须使用仓库内 Python 标准库构建器，不使用 `Compress-Archive`、PowerShell 打包、手工 zip、tar 或 GitHub Source code ZIP：

- `python tools/build_module.py --source . --output "E:\Pixel ADB\builds\releases\pixel9pro_control_candidate.zip"`
- `python tools/audit_release.py "E:\Pixel ADB\builds\releases\pixel9pro_control_candidate.zip"`
- Python 解释器只要求兼容项目声明的最低版本，不固定不存在的私有绝对路径。

构建输入采用显式白名单；`.git`、测试、文档、工具、日志、scratch、临时文件和本计划文档不得进入运行包。

双次构建比较：

- SHA-256
- entry 数量和顺序
- 时间戳
- 权限
- module.prop
- versions.prop
- WebUI cache stamp

ZIP 需要满足：

- 模块入口在根目录。
- entry 使用正斜杠。
- 没有绝对路径和 ..
- 没有 tests、docs、logs、scratch。
- 没有个人数据。
- Shell 为 0755，普通文件为 0644。
- 同时包含 caiman/komodo 合同声明的 staging payload。
- 不包含任何预激活 canonical target；运行时只允许当前 SKU bind 一个 canonical target。

## 18. PRO XL 实机测试

代码审阅、主机测试和包级审计完成后，再进行真实 PRO XL 安装。

安装前记录：

- device codename
- Android build
- vendor build
- Root 和 MetaModule 版本
- Kernel banner
- 当前 stock UECap hash
- candidate hash
- 安装包 hash
- 回滚包 hash

顺序：

1. 重新枚举 ADB 并固定 serial。
2. 读取 ro.product.device。
3. 读取 stock UECap hash。
4. 读取 vendor.thermal.config。
5. 检查 Thermal sensor/cooling。
6. 检查 scheduler capability。
7. 安装测试 ZIP。
8. 读取安装器日志。
9. 检查 staged、active 和有效 /vendor。
10. 检查 UECap target hash。
11. 检查 thermal system/custom 状态。
12. 检查 scheduler active/off。
13. 重启并重新枚举 ADB。
14. 检查 sys.boot_completed=1、su -c id、active module.prop 和 pending update。
15. 检查 modem load/readback、IMS/VoLTE/VoNR 和 runtime receipt。
16. 执行 stock rollback，再次重启和复读。

只有安装、overlay、UECap hash、modem load、重启持久化和 stock rollback 全部有证据，XL candidate 才能升级为设备验证通过。

## 19. 发布门禁

测试版可以包含 caiman 三档 UECap、komodo 单文件 candidate、调度自动关闭逻辑和温控 system default。

发布说明必须明确：

- test / candidate / prerelease
- PRO XL 尚未完成实机验证
- XL 文件尚未升级为稳定适配

在 README 和 release notes 获得审核前：

- 不创建新 tag。
- 不创建 GitHub Release。
- 不上传稳定版资产。

## 20. 交付物

最终交付：

1. 按阶段拆分的代码 commit 链。
2. 每个 commit 的中文范围和验证说明。
3. Host、parser、contract、failure injection 结果。
4. 主机静态/parser 合同报告和边界说明。
5. 确定性双构建报告。
6. ZIP 内容、权限、路径和 hash 审计报告。
7. 隐私安全日志样例。
8. caiman/komodo UECap 分流证据。
9. PRO XL candidate 来源和 hash。
10. PRO XL 实机安装、重启、modem load 和 rollback 日志。
11. 未验证项目清单。
12. 对应回滚 commit 和回滚 ZIP。

## 21. 当前执行状态

- 本计划文档：已创建。
- 模块源码：本轮未修改。
- 新代码 commit：本轮未创建。
- 新 ZIP：本轮未生成。
- PRO XL 实机安装：未执行。
- PRO XL runtime：未验证。

下一步从 C0 文档合同提交开始，然后按 C1 → C9 顺序逐阶段实施、验证、提交和审计。komodo candidate 只有在取得真实文件、来源 build、bytes、SHA-256 和设备侧证据后才能进入可安装 ZIP；不得以占位文件或 caiman 改名文件绕过门禁。
