# Pixel 9 Pro Control Module

> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、可选 CPU 调度、ZRAM、UE 网络控制模块；Material 3 WebUI 控制台，可与 Uperf Game Turbo、fas-rs 等外部调度模块协同。（Magisk 下基带 UE 切换不可用。）

## 当前版本

- Release: `v4.5.01`
- versionCode: `106`
- Asset: `pixel9pro_control_v4.5.01.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`

## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 温控分支已适配；未实际测试；UECap 保持 stock |

安装时自动检测机型，刷入对应的温控配置。基带配置仅限 Pixel 9 Pro。

## 功能

### CPU 调度 / 外部调度接管

本模块内置 Pixel 原厂调度参数微调。UGT 可作为日常 `external` baseline；fas-rs 只在命中目标游戏时临时接管，退出后恢复用户选择的 Pixel 或 UGT 日常 baseline。本项目不打包、不改写 UGT / fas-rs，只做只读探测和有验证的调度让权。

WebUI 提供「省电 / 均衡 / 系统默认」三档（卡片顺序即省电→均衡→系统默认）；性能优先降为内部基线，需要游戏级线程调度请切到 `external`，由 UGT / fas-rs / 外部调度接管。

| 模式 (WebUI 顺序) | top-app | response_time_ms (小/中/大) | uclamp.min cap | 说明 |
|------|---------|------|------|------|
| ① 省电 | cpu0-6 | 32 / 96 / 200 | 0 | 放慢升频；top-app 排除大核 X4 |
| ② 均衡 | cpu0-7 | 16 / 40 / 200 | 0 | 中等升频速率；top-app 全核（默认档） |
| ③ 系统默认 | cpu0-7 | 内核 nom（本机 9 / 52 / 165） | 1024 | 恢复内核出厂调度：response 回写只读 `response_time_ms_nom`、cpuset 与 cap 还原出厂值，不压制 boost |
| 性能优先 | cpu0-7 | 12 / 20 / 80 | 1024 | 内部基线 (force/CLI)，不在 WebUI；不参与自动策略 |

- 调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`
- `foreground/cpus` 会被 framework 重置到 `0-6`，模块主要托管 `top-app/background/system-background`
- 自动模式以均衡为日常底座，温度持续偏高时收口至省电，回落后恢复；死区设有粘滞，避免边界来回抖动
- `.sched_owner_desired=pixel|external` 保存用户的日常选择，`.cpu_sched_owner` 只表示当前实际 owner；fas-rs 游戏 lease 不覆盖用户意愿
- Pixel 日常调度下仍可启用 fas-rs 游戏临时接管：命中游戏时 `effective=external`，退出后恢复原 Pixel auto/manual 状态
- 日常选择为 `external` 时，普通应用恢复 UGT；若 UGT 未启用则保持 `external:none` 并明确告警，不会把 fas-rs 误当作日常调度器，也不会擅自回写 Pixel 或 `balanced`

当实际 `.cpu_sched_owner=external` 时，本模块跳过常规 profile/auto/enforce 写入；owner 事务层只在 Pixel/FAS handoff 边界清理 UGT 残留、恢复 cpufreq 基线并复读验证。温控、ZRAM、NR/SIM2、UECap 与 WebUI 始终由本模块负责。

### 温控阈值 (5 档)

| 档位 | Offset 偏移值 | 最早介入温度 (HINT) | 说明 |
|------|--------|---------------------------|------|
| 提前介入 | -2°C | 35°C | 比出厂提前 2°C 介入 |
| 原厂阈值 | 0°C | 37°C | 不平移前置阈值 |
| 轻度放宽 | +2°C | 39°C | HINT 最早 39°C；VIRTUAL-SKIN 主阈值约 41°C，并非 39°C 硬限温 |
| 日常放宽 | +4°C | 41°C | 模块默认；靠近 SHUTDOWN 时安全收敛 |
| 最大放宽 | +6°C | 43°C | 前置阈值目标 +6°C，最后安全阈值不平移 |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器（VIRTUAL-SKIN / HINT / SOC / CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU）。安装器和 WebUI 共用同一份生成逻辑，每次从当前机型 stock JSON 重建。前 6 个 severity 槽位先按档位平移；第 7 个 SHUTDOWN 槽位若为数值，保留 stock `55/59°C`。`+4/+6°C` 在接近 SHUTDOWN 时会向前限幅，至少保留 `0.5°C` 间隔，避免阈值相等或逆序导致 Thermal HAL 启动失败。

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

### 独立模块与外部调度协同

本项目按“控制模块 + 基带模块 + 第三方外部调度模块”协同使用。三者都可独立安装和工作；其中 `pixel9pro_control` 与 `pixel9pro_baseband_trial` 由本项目维护，Uperf Game Turbo / fas-rs 等外部调度项目由各自上游维护，本项目只做只读探测和 CPU 调度让权，不打包、不改写、不替代其上游维护。

| 模块 | 归属 | 详情 |
|------|------|------|
| `pixel9pro_control` | 本项目 | 温控、ZRAM、UECap 三档切换（仅 caiman + APatch/KSU）、NR 降级、SIM2 管理、后台限制、WebUI；未让出时管理 Pixel 原厂 CPU 调度 |
| [`pixel9pro_baseband_trial`](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/download/v4.3.11/pixel9pro_baseband_trial_v1.0.1.zip) | 本项目可选基带模块 | 基于 [Sun_Dream（酷安）](https://www.coolapk.com/u/1281808) 的 PLMN / CarrierSettings 设计；提供 China MCFG、APN 与 VoLTE/VoNR/WFC 配置 |
| Uperf Game Turbo / fas-rs / 其它外部调度器 | 第三方或独立外部调度模块 | CPU scene 调度、输入/前台/游戏线程调度、frame-aware 调度、per-app 性能模式；由各自上游独立维护 |

- 只安装控制模块：温控/ZRAM/NR/SIM2/UECap/WebUI 正常工作；CPU 调度默认由本模块管理，也可手动设为 `external` 停用
- 只安装基带模块：单独刷入 `pixel9pro_baseband_trial_v1.0.1.zip`，VoLTE/VoNR 自动生效，UECap 保持原厂
- 控制模块 + 基带模块：WebUI 检测并展示基带模块状态；UECap 由控制模块管理，CarrierSettings / MCFG 由基带模块提供
- 控制模块 + UGT / fas-rs：WebUI 的“日常选择”决定普通应用使用 Pixel 或 UGT；“游戏接管”可让 fas-rs 只在命中游戏时临时接管
- 三者都安装：推荐边界为 Pixel9Pro-Control 管理日常 baseline、fas-rs 管理指定游戏 lease，基带模块负责运营商配置增强

**基带模块兼容性**：`pixel9pro_baseband_trial` 中的 CarrierSettings / MCFG 基于中国运营商配置，安装器只允许 `caiman`。控制模块的 UECap binarypb 同样基于 Pixel 9 Pro (Exynos 5400 modem) 固件定制；`komodo` 安装时会移除该 payload 和切换脚本并保持 stock，不能用 caiman 文件代替。

**外部调度协同说明**：Uperf Game Turbo、fas-rs 等为外部调度项目，本项目只识别设备上已经存在的模块，不提供下载、推荐或安装引导。

**可选模块按需显示**：WebUI 仅在检测到 UGT 时显示日常 UGT 接管控制，仅在检测到 fas-rs 时显示游戏 handoff / arbiter 控制；两者同时存在时组合显示。`pixel9pro_baseband_trial` 未安装、已禁用或待移除时，基带配置卡完全隐藏。首次安装只报告 UGT、fas-rs 与本项目基带模块是否已检测到，不提供下载、推荐或第三方安装引导。单独残留的 `/data/adb/fas_rs` 状态目录不再被当成 fas-rs 已安装。

**owner arbiter**：`scripts/owner_arbiter.sh` 的普通 `tick` 只记录决策；创建 `/data/adb/fas_rs/.arbiter_apply` 或执行 `apply-tick` / `apply` 才执行事务切换。普通应用只恢复 `.sched_owner_desired`；命中 fas-rs 游戏时停止 UGT、进入 `FAS_LEASED_GAME`，退出后按 desired 精确恢复 Pixel 或 UGT。切换共用 `.owner_transition.lock`，Pixel 接管会停止 UGT/fas-rs、恢复 cpufreq baseline、重新应用当前 profile 并复读 cap/cpuset/response；FAS 启动失败也按 desired 回滚。UGT→fas-rs 必须先修复 powersave/cpufreq residue 并验证 cap=1024，随后才启动 fas-rs 和发布游戏 owner，避免 owner 已显示接管但运行面尚未就绪的假 active 窗口。cap 契约为 Pixel `balanced/battery=0`、UGT 日常 `=0`、fas-rs 游戏 lease `=1024`（Google 出厂上限，允许完整 boost）；退出游戏后恢复 desired baseline 并再次复读。Pixel `default/performance` 仍遵循对应 profile 的出厂/性能语义 `=1024`。这里只写 `sched_util_clamp_min`，不会覆盖 ThermalHAL 独立使用的 `uclamp.max` 热保护。`.arbiter_state` 同时记录 `desired_owner`、effective owner、handoff policy、lease、transition result、`uclamp_cap_current/expected/verified`、重复 UGT 归一与 cpufreq/ThermalHAL 复读结果。UGT enabled 但 desired=Pixel 时不得自行启动；desired=external 但 UGT disabled 时明确进入 `external:none`。

**owner arbiter cpufreq 恢复边界**：低频残留恢复只在 `FAS_LEASED_GAME` / `EXIT_HOLD` 且 ThermalHAL CPU cooling 未激活时尝试。恢复时从 `scaling_available_governors` 保留空格匹配 `sched_pixel` 或 `schedutil`，再按“打开 `scaling_max_freq` 到 `cpuinfo_max_freq` → 切 governor → 再写 max → 等待 `ARB_CPUFREQ_RESTORE_SETTLE_S`（默认 2 秒）→ 复读验证”的顺序执行；首次复读失败只做一轮 guarded retry，并在日志中同时记录 `first_after` 与 `retry_after`。如果仍失败，状态会保持 `cpufreq_restore_failed=yes`，这代表存在 PowerHAL / Scene object / cpufreq QoS 等外层写入者或平台限制，不能用循环抢写 sysfs 当作修复。

**B93 WZRY handoff 闭环**：v4.4.35 将 cpufreq restore 调整为完整事务：先把 `scaling_min_freq` 恢复到 `cpuinfo_min_freq`，再打开 max、切回 `sched_pixel/schedutil`，最后复写 min/max；新 fas-rs lease 不再被旧 idle-owner restore timestamp 压住。配合 Pixel 9 Pro Scheduler `v4.9.1-pixel9pro.19` 的 base governor restore 与 WZRY policy7 floor，真实 WZRY clean wireless/discharge gate 已 PASS，policy7 max 恢复到 `3105000` 且不再出现 `policy7_max_too_low` blocker。

**owner arbiter worker**：`service.sh` 会启动独立 owner arbiter worker，而不是只依赖统一 standby worker。统一 worker 在息屏 deep standby 下可能睡 600 秒；独立 worker 亮屏后默认每 5 秒执行一次 `owner_arbiter.sh tick "$MODDIR" on`。息屏后只读 DRM `enabled` 做低成本观察，前 6 分钟默认 15 秒一次；超过 6 分钟后进入长暂停（默认 3600 秒），但长暂停内部按 `OWNER_ARBITER_PAUSE_POLL_S`（默认 30 秒）只复读 DRM 并在亮屏后提前退出，不跑 window/top-app IPC，避免长睡导致 owner 状态滞留在旧前台。可用环境变量 `OWNER_ARBITER_FAST_ON` / `OWNER_ARBITER_FAST_OFF` / `OWNER_ARBITER_OFF_GRACE_S` / `OWNER_ARBITER_OFF_PAUSE_S` / `OWNER_ARBITER_PAUSE_POLL_S` 调整亮屏轮询、息屏短观察、进入暂停前宽限、长暂停上限和长暂停内 DRM 复读间隔。

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

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载最新 `pixel9pro_control_vX.Y.Z.zip`
2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
3. APatch / KernelSU / Magisk → 模块 → 从存储安装
4. **首次安装**：音量键交互向导，依次配置温控偏移、CPU 调度（检测到启用中的 UGT 时默认交其接管；否则四选一：均衡／省电／系统默认／自动）、UECap 档位（仅 APatch/KSU）、NR 降级、NTP
5. **升级安装**：自动迁移已有设置（旧 performance 调度档并入均衡，系统默认档保留）；若旧配置缺调度接管设置，仅在检测到启用中的 UGT 时设为日常 external，fas-rs 仍只作为游戏临时接管
6. 重启
7. 打开 `http://127.0.0.1:6210` 验证

## 兼容性

- `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
- `Android 17 QPR1 Beta 1 (SDK 37)` 当前验证基线
- `APatch 0.10+` 实机验证
- `KernelSU 0.9+` 代码兼容（需 metamodule，未完成真机闭环）
- `Magisk v27+` 代码兼容（未完成真机闭环）

### Root 实现差异

| 功能 | APatch / KSU+metamodule | Magisk |
|---|---|---|
| 温控阈值偏移、CPU 调度、ZRAM、后台应用限制、SIM2、NR 降级、WebUI | ✅ | ✅ |
| UECap 三档基带切换 (balanced/special/universal) | ✅（仅 caiman） | ❌ 不支持 |

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

本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入
- **稳定性风险**：修改 CPU 调度参数可能导致系统不稳定
- **网络风险**：NR 息屏降级会在息屏时切换网络模式

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任。**

- **Pixel**、**Android**、**Tensor**、**Material Design** 是 Google LLC 的商标。本项目与 Google LLC 无任何关联。
