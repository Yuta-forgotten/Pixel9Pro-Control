# Pixel 9 Pro Control Module

> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、可选 CPU 调度、ZRAM、UE 网络控制模块；Material 3 WebUI 控制台，可与 Uperf Game Turbo、fas-rs 等外部调度模块协同。（Magisk 下基带 UE 切换不可用。）

## 当前版本

- Version: `v4.5.07`
- versionCode: `112`
- Package filename: `pixel9pro_control_v4.5.07.zip`；已作为独立 GitHub Release `v4.5.07` 发布。此前功能等价候选已在 caiman/APatch 完成安装、重启和运行态复核；当前发布 ZIP 已完成源码、确定性构建和 ZIP 结构审计，但尚未重新安装。当前 ZIP 的体积、SHA256 和 source fingerprint 统一记录在根级审查文档与日志索引中，不在模块 README 内自引用，避免源码 fingerprint 与 ZIP digest 形成循环漂移
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`

## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | 当前 active 为此前功能等价的 `v4.5.07/112` 候选；APatch 安装、重启、UECap bind/receipt 与 NR_SA n41 电话注册已复核；GitHub Release `v4.5.07` 发布 ZIP 尚未重新安装 |
| Pixel 9 Pro XL | komodo | 温控分支已适配；UECap 由系统/外部路径保持 stock，Control 不写入 XL payload；未完成 XL 实机闭环 |

安装时自动检测机型，刷入对应的温控配置。CarrierSettings、APN、China MCFG 和 IMS properties 由独立的 `pixel9pro_baseband_trial` 模块按 `caiman/komodo` manifest 管理；Control 不把独立基带模块重新打包进自身。

## 功能

### CPU 调度 / 外部调度接管

本模块内置 Pixel 原厂调度参数微调。Pixel 与 UGT 是重启后选择的日常 baseline：切到 UGT 或完全退出 UGT 都先提交下次 boot 状态，再重启验证，当前 boot 不直接改变日常 baseline。若已安装 fas-rs，命中游戏时可在任一 verified baseline 上建立临时 `fas-rs:game:<pkg>` lease；Pixel baseline 退出游戏后恢复 Pixel profile 并保留 resident process，UGT baseline 则先暂停 UGT、退出后恢复同一 UGT 单实例。

WebUI 提供「省电 / 均衡 / 系统默认」三档（卡片顺序即省电→均衡→系统默认）；性能优先降为内部基线。UGT 提供另一套重启后生效的日常调度，fas-rs 只在有效游戏 lease 内成为唯一临时写入者。

| 模式 (WebUI 顺序) | top-app | response_time_ms (小/中/大) | uclamp.min cap | 说明 |
|------|---------|------|------|------|
| ① 省电 | cpu0-6 | 32 / 96 / 200 | 0 | 放慢升频；top-app 排除大核 X4 |
| ② 均衡 | cpu0-7 | 16 / 40 / 200 | 0 | 中等升频速率；top-app 全核（默认档） |
| ③ 系统默认 | cpu0-7 | 内核 nom（本机 9 / 52 / 165） | 1024 | 恢复内核出厂调度：response 回写只读 `response_time_ms_nom`、cpuset 与 cap 还原出厂值，不压制 boost |
| 性能优先 | cpu0-7 | 12 / 20 / 80 | 1024 | 内部基线 (force/CLI)，不在 WebUI；不参与自动策略 |

- 调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`
- `foreground/cpus` 会被 framework 重置到 `0-6`，模块主要托管 `top-app/background/system-background`
- 自动模式以均衡为日常底座，温度持续偏高时收口至省电，回落后恢复；死区设有粘滞，避免边界来回抖动
- `.scheduler_boot_state` 区分 pending / verifying / success / failed；`.sched_owner_desired` 与 `.cpu_sched_owner` 只在重启后验证通过时提交，fas-rs 游戏 lease 不覆盖启动模式
- Pixel 日常调度下，fas-rs 常驻 PID 只表示服务可用；有效游戏 lease 才令 `effective=external`，退出后恢复原 Pixel auto/manual 状态并保留 resident process
- UGT 日常调度下，owner worker 只在游戏 lease 边界暂停/恢复 UGT；进入 lease 前必须确认单一 UGT baseline，退出后只调用 UGT lifecycle helper 恢复单实例，不重放完整 boot 初始化
- CPU、cpuset、uclamp cap 与 vendor_sched L2 同属一个 profile 事务；省电 L2 为 `150/80`，均衡/性能为 `200/100`，系统默认恢复 `1024/308`
- Auto、owner、WebUI profile/handoff 共用同一 transition lock；拿锁后复读 boot mode、desired/effective owner、policy 与当前 profile，旧决策只返回 no-op
- 周期性 owner/auto 决策遇到锁占用立即跳过并在下一周期重新计算；WebUI 写请求只做短时有界等待，避免旧前台/温度决策排队后补写
- 自动写入最多 3 次且受 30 秒 deadline 约束，随后发布最终成功/失败；profile/owner terminal 主状态提交失败时写独立 fallback，同一失败 terminal key 不再重复拿锁，显式用户操作可重置后重试
- 独立 300 秒 health 只读调度节点；先检查 transition lock，再对控制面和 profile 做前后快照。切换中或状态变化时不改持久 health 文件，由 compact GET 动态返回 deferred；fas-rs 临时接管可记录稳定 deferred；首次稳定 mismatch 最多触发一次有界 repair

当实际 `.cpu_sched_owner=external` 时，本模块跳过 Pixel profile/auto 写入；该状态可能是 UGT 日常 baseline，也可能是 fas-rs 游戏 lease，必须结合 `.owner_state` 判断。永久从 UGT 回到 Pixel 仍需先 staging/禁用 UGT 并重启；游戏临时 lease 只在本次 boot 内恢复原 baseline。温控、ZRAM、NR/SIM2、UECap 与 WebUI 始终由本模块负责。

### 温控阈值 (5 档)

| 档位 | Offset 偏移值 | 最早介入温度 (HINT) | 说明 |
|------|--------|---------------------------|------|
| 提前介入 | -2°C | 35°C | 比出厂提前 2°C 介入 |
| 原厂阈值 | 0°C | 37°C | 不平移前置阈值 |
| 轻度放宽 | +2°C | 39°C | HINT 最早 39°C；VIRTUAL-SKIN 主阈值约 41°C，并非 39°C 硬限温 |
| 日常放宽 | +4°C | 41°C | 模块默认；靠近 SHUTDOWN 时安全收敛 |
| 最大放宽 | +6°C | 43°C | 前置阈值目标 +6°C，最后安全阈值不平移 |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器（VIRTUAL-SKIN / HINT / SOC / CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU）。安装器和 WebUI 共用同一份生成逻辑，每次从当前机型 stock JSON 重建。前置 severity 先按档位平移；第 7 个 SHUTDOWN 槽位若为数值，保留 stock `55/59°C`。靠近 SHUTDOWN 时，生成器按 stock `HotHysteresis` 从后向前收窄，保证“前一档阈值 `<=` 下一档阈值减下一档 hysteresis”；只检查阈值递增并不足以保证 Pixel Thermal HAL 接受配置。

WebUI 实时温度优先读取后台 worker 维护的 `.thermal_cache.json`，避免普通刷新被 `dumpsys thermalservice` 慢路径阻塞；当缓存缺失、无 `VIRTUAL-SKIN`、温度越界或连续异常时，会自动走 `fresh=1` 重建，连续异常后清除缓存再重建，避免坏缓存长期误导显示。

### ZRAM / 内存优化

- 算法：`lz77eh`（Emerald Hill 硬件加速）
- 容量：`11392MB`
- VM 参数：`swappiness=100`、`min_free_kbytes=131072`、`watermark_scale_factor=200`、`vfs_cache_pressure=60`
- WebUI 支持模块默认、原厂恢复和手动调节 VM 参数；手动值即时生效并随 custom 模式开机恢复。

### 待机与 modem 策略（以 Google 默认机制为主）

本模块不强行削弱 modem 能力，保留 `5G / 5GA / CA / IMS` 能力，主要通过系统设置和使用层策略降低待机功耗：

| 设置项 | 值 | 说明 |
|--------|-----|------|
| `adaptive_connectivity_enabled` | `1` | Google 官方 5G 节电建议：app 不需要高速时自动 NR→LTE |
| `network_recommendations_enabled` | `1` | 系统网络建议 |
| `mobile_data_always_on` | `0` | Wi-Fi 下不保持蜂窝常驻 |
| `wifi_scan_always_enabled` | `0` | 关闭 Wi-Fi 后台常扫 |
| `ble_scan_always_enabled` | `0` | 关闭 BLE 后台常扫 |
| `nearby_sharing_enabled` | `0` | 关闭 Nearby Sharing |

- Wi-Fi multicast：亮屏开启，息屏关闭
- SIM2 空槽：默认开启。通过 `cmd phone set-sim-count 1` 将 modem 实例从 2 降到 1；检测到 SIM2 插入或用户关闭自动管理时通过 `set-sim-count 2` 恢复双 modem
- 待机隔离模式：仅用于过夜 A/B 排障。开启后息屏阶段暂停 NR 降级、SIM2 管理、功耗采样、thermal burst 和自动调度，尽量把 control 模块的待机干扰降到最低
- 后台应用限制：按包选择 `降低后台优先级 / 禁止后台服务 / 禁止后台活动 / 休眠` 策略；添加区会从统一应用识别目录列出本机已安装的常用应用，也保留手输包名。默认仅预置抖音（休眠：锁屏或离开前台延时后 `force-stop`），移除或关闭时按接管前 bucket/AppOps 恢复

### NR 息屏降级

- 息屏超过 300 秒后将网络模式切换到 LTE
- 亮屏时恢复保存的 NR 模式
- 热点开启时跳过切换

### UE 网络能力 / UECap 切换

UECap 告诉基站“手机支持哪些载波组合”。**不直接影响功耗**——功耗取决于信号强度和 modem 活跃时间。

| 配置 | 内部模式 | 说明 | 对比默认 |
|------|----------|------|----------|
| **国内频段** | `balanced` | 原厂 +25 组中国 NR 组合 (n28/n41/n79) | +25 / -0 / ~0 |
| 全面增强 | `special` | 原厂 +52 组全球 NR 组合 | +52 / -0 / ~0 |
| Google 默认 | `universal` | 原厂能力表，不做任何修改 | +0 / -0 / ~0 |

- 切换只重启蜂窝 modem，不影响 Wi-Fi / 蓝牙
- WebUI 切换后自动校验配置摘要，确认一致后才提示成功

UECap 的设备边界必须与实际状态分开理解：`caiman` 才有 Control 管理的
`balanced/special/universal` 三档；`komodo` 在当前源码中是
`external/stock`，Control 只读展示设备、modem、radio 和 receipt 证据，不写入
`PLATFORM_6287228797510365516.binarypb`。两个 `PLATFORM_*` 文件属于不同 SKU，不能改名或交叉替换。

### 独立模块与外部调度协同

本项目按“控制模块 + 基带模块 + 第三方外部调度模块”协同使用。三者都可独立安装和工作；其中 `pixel9pro_control` 与 `pixel9pro_baseband_trial` 由本项目维护，Uperf Game Turbo / fas-rs 等外部调度项目由各自上游维护。本项目不打包、不替代第三方模块，但会在用户启用游戏 handoff 后受控协调 UGT 的单实例 stop/start、fas-rs lease owner marker 与 owner-aware `powercfg` router；每次 mutation 都必须复读并在失败时恢复原 baseline。

| 模块 | 归属 | 详情 |
|------|------|------|
| `pixel9pro_control` | 本项目 | 温控、ZRAM、UECap 三档切换（仅 caiman + APatch/KSU）、NR 降级、SIM2 管理、后台限制、WebUI；未让出时管理 Pixel 原厂 CPU 调度 |
| `pixel9pro_baseband_trial` | 本项目可选基带模块 | 支持 caiman/komodo 的 CarrierSettings、APN、China MCFG 与 VoLTE/WFC properties；不携带、不写入任何 UECap `binarypb` |
| Uperf Game Turbo / fas-rs / 其它外部调度器 | 第三方或独立外部调度模块 | CPU scene 调度、输入/前台/游戏线程调度、frame-aware 调度、per-app 性能模式；由各自上游独立维护 |

- 只安装控制模块：温控/ZRAM/NR/SIM2/UECap/WebUI 正常工作；CPU 调度由本模块管理
- 只安装基带模块：单独安装当前明确发布的基带 ZIP，CarrierSettings/APN/IMS 配置按 manifest 生效，UECap 保持由 Control 或系统原生路径负责
- 控制模块 + 基带模块：WebUI 检测并展示基带模块状态；UECap 由控制模块管理，CarrierSettings / MCFG 由基带模块提供
- 控制模块 + UGT：Pixel/UGT 双向切换均在重启后生效；APatch 可由 WebUI staging，KernelSU/Magisk 需在各自 Root 管理器启停 UGT 后重启
- 控制模块 + fas-rs：fas-rs 在 Pixel boot 常驻待机；仅有效游戏 lease 进入接管，退出后恢复 Pixel 日常 profile，不通过 PID 存在单独判断 active owner
- 三者都安装：Pixel 或 UGT 作为日常 baseline；fas-rs 命中游戏时临时成为唯一调度写入者，退出后恢复进入 lease 前的同一 baseline；基带模块独立负责运营商配置增强

**基带模块兼容性**：`pixel9pro_baseband_trial` 当前源码 manifest 只允许 `caiman` / `komodo`，两机共用 CarrierSettings、APN、China MCFG 和 IMS properties，但不携带 UECap payload。Control 的 UECap binarypb 仍按 SKU 独立管理：`caiman` 使用 `PLATFORM_9055801516233416490.binarypb` 三档，`komodo` 使用系统/外部原生路径并保持 stock；不能用 caiman 文件代替 XL 文件。

**基带模块升级规则**：升级的是普通基带模块时，不要求卸载 APatch Manager，也不应由普通模块删除 `/data/adb/modules`、修改 `modules.img` 或自行写入 MetaModule content image。若旧模块的 active source、MetaModule content image、effective overlay、source/content/effective hash 及同一 boot 的 runtime receipt 都能复读确认，可以直接安装新版并在重启后复读；只有这些证据缺失、为空、冲突、跨 boot 或失败时，才进入 clean reinstall：Root Manager 卸载旧的普通基带模块 → 重启 → 安装新版 → 再重启 → 复读 active module、MetaModule content image、effective path、mount 和 runtime receipt。

**外部调度协同说明**：Uperf Game Turbo、fas-rs 等为外部调度项目，本项目只识别设备上已经存在的模块，不提供下载、推荐或安装引导。

**可选模块按需显示**：WebUI 仅在检测到 UGT 时显示启动模式切换，仅在检测到 fas-rs 时显示游戏 handoff / arbiter 控制；独立调度健康状态始终可见，不依赖任一可选模块。`pixel9pro_baseband_trial` 未安装、已禁用或待移除时，基带配置卡完全隐藏。首次安装只报告 UGT、fas-rs 与本项目基带模块是否已检测到，不提供下载、推荐或第三方安装引导。单独残留的 `/data/adb/fas_rs` 状态目录不再被当成 fas-rs 已安装。

**profile API 响应边界**：profile/policy/owner/handoff 写请求只返回本次已复读并提交的 compact 状态；compact GET 同步返回 boot、health 与 profile retry terminal 状态，不触发完整外部模块发现。完整发现放到后台读取；落后于显式 mutation 的旧响应直接丢弃，期间若有更新的 compact auto 状态则在 full discovery 后重新叠加，避免“实际已成功但前端超时”或旧状态覆盖新操作。

**owner arbiter**：`scripts/owner_arbiter.sh` 在 verified Pixel/UGT baseline 上启动。Pixel idle 允许 fas-rs resident process 存在；UGT idle 要求一个 root UGT 且无 fas-rs lease。命中游戏时，Pixel baseline 按 `cpufreq restore → cap=1024 → ensure resident → publish lease` 接管；UGT baseline 先保存 cap、停止并复读 UGT，再恢复 cpufreq、设 cap=1024、启动 fas-rs 并记录精确 PID/start_ticks。退出 lease 时 Pixel 恢复 profile 并保留 resident；UGT 停止精确 lease PID、恢复 pre-lease cap，再仅调用 `libuperf.sh -> uperf_start()` 恢复单实例。失败路径必须恢复原 baseline；若 UGT 恢复失败，则保留可验证的 fas-rs lease而不能发布假成功。所有决策拿共享锁后复读 boot mode、desired/effective owner 和 handoff policy；同一 transition key 最多 3 次/30 秒。

**owner arbiter cpufreq 恢复边界**：低频残留恢复只在 `FAS_LEASED_GAME` / `EXIT_HOLD` 且 ThermalHAL CPU cooling 未激活时尝试。恢复时从 `scaling_available_governors` 保留空格匹配 `sched_pixel` 或 `schedutil`，再按“打开 `scaling_max_freq` 到 `cpuinfo_max_freq` → 切 governor → 再写 max → 等待 `ARB_CPUFREQ_RESTORE_SETTLE_S`（默认 2 秒）→ 复读验证”的顺序执行；首次复读失败只做一轮 guarded retry，并在日志中同时记录 `first_after` 与 `retry_after`。如果仍失败，状态会保持 `cpufreq_restore_failed=yes`，这代表存在 PowerHAL / Scene object / cpufreq QoS 等外层写入者或平台限制，不能用循环抢写 sysfs 当作修复。

**owner arbiter worker**：`service.sh` 在 scheduler boot state=`success/pixel|ugt` 时启动独立 owner worker。屏幕交互态以 `cmd deviceidle get screen` 为主真值；AOD 的 `mWakefulness=Dozing` / `mScreenState=DOZE` 必须归为非交互态，DRM `enabled` 只表示 encoder 仍连接，绝不能单独证明亮屏。非交互或状态未知时 owner 在 scheduler detection、状态迁移、前台 `dumpsys` 和任何调度写入前退出。亮屏默认每 5 秒观察一次；稳定 baseline、重复 disabled 状态和失败 terminal 都不重放参数、不改 `.arbiter_state`、不追加 history。独立 scheduler health 每 300 秒只读控制面；有效 fas-rs lease 在 Pixel/UGT 两种 baseline 下都只发布 deferred，不触发 baseline repair。

### NTP 服务器选择

可选：`ntp.aliyun.com`（默认）、`ntp.myhuaweicloud.com`、`ntp1.xiaomi.com`、`time.android.com`。

### WebUI 控制台

端口 6210，`http://127.0.0.1:6210`（仅绑定 127.0.0.1 回环）。采用 Material 3 设计：四个一级标签页、贴边底部导航、四向安全区，支持深色 / 浅色 / 跟随系统及可换主题色。

**信息架构（四标签）**

- **状态**：当前模式、机身温度、内存与系统、CPU 实时频率、设备信息、操作记录
- **性能温控**：调度接管 / 手动·自动、CPU 实时频率与参数、性能模式卡、温度详情、温控阈值档位
- **网络**：UECap 三档、基带模块状态、NR 息屏降级、SIM2 空槽管理
- **系统**：ZRAM/VM、后台应用限制、待机隔离、后台 worker 摘要、NTP、主题与配色

**应用与 UID 识别目录**

- `config/app_identities.tsv` 是功耗排行和后台应用限制共用的唯一名称资料源，记录 Android 特殊 UID、系统分项、常用包名、中文名称、类别和限制风险级别。
- 功耗排行优先使用当前 PackageManager 的 UID→包名关系，再用目录补充易读名称；`UID -5` 会识别为“网络共享 / 热点”，未知负 UID 会标成 Android 特殊统计 UID，不再误报成已卸载 App。
- 后台限制只把目录中标记为 `normal` / `caution` 且本机已安装的包显示为候选；系统组件只用于识别，不进入候选列表。`caution` 项会提示可能影响通知、VPN、穿戴同步或持续连接。
- 目录是只读 TSV 数据，后端使用字段白名单解析，绝不作为 shell 脚本 `source` / `eval`；新增常用 App 时只需增加一行，不需要修改 `energy.sh` 或 `app.js`。

**主题与配色（调色盘）**

系统页「主题与配色」卡集成显示模式开关与主题色板：

- 显示模式：跟随系统 / 浅色 / 深色
- 预设主题色：青绿（默认）/ 天青 / 雾蓝 / 暮紫 / 樱粉 / 暖橙 / 苔绿，并支持自定义十六进制颜色
- 取色采用 Material 3 Expressive 风格的 tonal 派生：由一个种子色推导 primary / secondary / tertiary 三类强调色与中性表面轻染；强调色、选中态、状态 chips、徽章、整页背景与各级卡片表面均随主题联动；警告（琥珀）、危险（红）、温度色阶等语义色保持固定以确保可辨识
- 配色仅影响 WebUI 显示，不改变温控、调度或系统参数；选择持久保存，明暗切换自动重新派生

**其它**

- 温度历史窗口：10 分钟 / 30 分钟 / 2.5h / 12h；前端对长窗口做抽稀绘制，保留峰值/低值趋势，降低 canvas 绘制压力
- 功耗详情区分「当前放电会话 / 今日累计 / 15-30-60 分钟短窗口 / batterystats 窗口」；顶部主题色指标卡突出会话、充放电状态和今日放电，蜂窝功耗同时显示 ODPM 硬件实测与系统估算（系统 `mobile_radio` 仅作失真参考），并可手动导出 15/30/60 分钟或本次窗口的功耗与温度历史到 `/sdcard/Download`
- 安全：启动时轮换随机 token、`info.sh` 不下发 token、写操作需 `X-PIXEL9PRO-TOKEN` 头、CSP `script-src 'self'`、写操作强制 JSON + CORS preflight；token 可经 `cat .../.webui_token` 或本机 loopback `auth.sh` 静默配对

## 安装

1. 对外安装只使用 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 中明确发布且 SHA256 校验一致的 ZIP；Control 当前独立 Release 为 `v4.5.07`；该发布 ZIP 已完成源码/结构审计但尚未重新安装，设备运行证据仍归属于此前功能等价候选；`v4.5.03` 与本地 `v4.5.04` 含 B110 错误合同，禁止安装；需要回滚时使用已验证的 `v4.4.41`
2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
3. APatch / KernelSU / Magisk → 模块 → 从存储安装
4. **首次安装**：音量键交互向导，依次配置温控偏移、CPU 调度（检测到启用中的 UGT 时默认交其接管；否则四选一：均衡／省电／系统默认／自动）、UECap 档位（仅 APatch/KSU）、NR 降级、NTP
5. **升级安装**：Control 自动迁移已有设置（旧 performance 调度档并入均衡，系统默认档保留）；若旧配置缺少启动模式状态，则按 UGT 模块在下次 boot 是否启用选择 UGT 或 Pixel；已安装 fas-rs 时保留或默认启用游戏临时接管，并在退出后恢复同一 baseline。独立普通基带模块按上面的“基带模块升级规则”判断直接升级或 clean reinstall，不因 APatch Manager 更新本身强制卸载 Manager
6. 重启
7. 打开 `http://127.0.0.1:6210` 验证

## 兼容性

- `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
- 当前源码版本：`v4.5.07/112`；已作为独立 GitHub Release 发布，当前发布 ZIP 已完成本地确定性构建和结构审计但尚未重新安装，设备运行证据仍归属于此前功能等价候选
- `Android 17 QPR1 Beta 1 (SDK 37)` 当前验证基线
- `APatch 0.10+` 实机验证
- `KernelSU 0.9+` 代码兼容（需 metamodule，未完成真机闭环）
- `Magisk v27+` 代码兼容（未完成真机闭环）

### Root 实现差异

| 功能 | APatch / KSU+metamodule | Magisk |
|---|---|---|
| 温控阈值偏移、CPU 调度、ZRAM、后台应用限制、SIM2、NR 降级、WebUI | ✅ | ✅ |
| UECap 三档基带切换 (balanced/special/universal) | ✅（仅 caiman） | ❌ 不支持 |
| 独立基带模块 CarrierSettings/APN/China MCFG/IMS properties | ✅（caiman/komodo，需按各自挂载契约复读） | ✅（使用 Magic Mount；不承担 UECap） |

## 已知问题

### 卡二屏

| 原因 | 解决 |
|------|------|
| `thermal_info_config.json` 格式错误 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动 | 同上 |

**紧急恢复**：长按电源键 → 第二屏时电源+音量下进安全模式 → 重启。

### WebUI 缓存

顶栏版本号不对说明浏览器缓存命中。资源已按版本号附加缓存参数；如仍命中可访问 `http://127.0.0.1:6210/?r=<随机数>` 绕过。

## 致谢

- **[Sun_Dream（酷安）](https://www.coolapk.com/u/1281808)** — cpuset + sched_pixel 调度思路、基带模块 PLMN/CarrierSettings 设计
- **[DYSBRT（酷安）](https://www.coolapk.com/u/22128139)** — 5G CA 设计
- **[Uperf Game Turbo](https://github.com/yinwanxi/Uperf-Game-Turbo)** / fas-rs — 外部调度器；本模块仅做探测与让权协同

## 免责声明

### 2026-09-05 实机验证边界

在 `caiman / CP41.260814.003.B1 / APatch` 上，VM/ZRAM、NTP、NR 息屏策略、thermal burst、standby idle isolate 和 CPU profile 已完成真实的“修改→权威复读→恢复”验证。温控在线切换已改为在 Thermal HAL 阈值复读一致时才报告 `restarted=true`，否则报告 `pending_reboot`；该修复需安装包含提交 `93eac97` 的版本后再做最终复读。UECap 当前处于 `pre_modem`，只完成 receipt/状态读取，未强制执行 modem reload；SIM2 未在无法建立 slot 回滚基线时执行关闭。实机证据不外推到其它 build、SKU 或 root 实现。

本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入
- **稳定性风险**：修改 CPU 调度参数可能导致系统不稳定
- **网络风险**：NR 息屏降级会在息屏时切换网络模式

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任。**

- **Pixel**、**Android**、**Tensor**、**Material Design** 是 Google LLC 的商标。本项目与 Google LLC 无任何关联。

源码仓库保留 `tests/` 用于 contract、failure injection 和 WebUI 回归；`ADB/` 是本地 TestLab fixture 镜像，不是发布内容。正式安装 ZIP 由固定构建器排除 `tests/`、`ADB/`、`docs/`、Node 依赖和开发配置。日常温控修改可先运行 `npm run test:thermal`，涉及设备行为时再追加设备 TestLab，正式发布仍须执行完整 source gate、确定性构建和 ZIP 审计。
