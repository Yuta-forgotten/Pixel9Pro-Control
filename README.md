# Pixel 9 Pro Control Module

> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、CPU 调度、ZRAM、待机优化和 UE 网络控制模块。（Magisk 下基带 UE 切换不可用）。

## 当前版本

- Release: `v4.4.8`
- versionCode: `72`
- Asset: `pixel9pro_control_v4.4.8.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`

### v4.4.8

- 修复 ADB 实机审查发现的 WebUI token bootstrap 风险：`info.sh` 不再通过 GET 返回 token，前端改为 `#token=<token>` 或首次写操作手动配对，token 仅保存在 `sessionStorage`。
- 修复未检测到 Uperf 且 `.cpu_sched_owner=external` 时保留旧高 boost 的问题：boot 与 WebUI 切换 external 时会先做一次 `balanced` 安全底座清理，然后继续停止周期性 CPU 调度写入。
- 修复 Android 17 热点桥接接口漏判：NR 息屏降级热点保护新增 `ap_br_wlan*` / `ap_br_softap*`，并在关闭 NR 降级时立即恢复保存的 NR 模式。
- 修复 NR WebUI 口径：`nr_switch.sh` 同时返回 raw setting、slot0 setting 和 telephony 实际 RAT，前端优先展示实际 RAT。
- 修复旧 `.profile_history` 非空时不追加 `sched_owner` baseline 的迁移问题；WebUI pid/lock 状态文件权限收紧为 `0600/0700`。

### v4.4.7

- 安装向导新增 Uperf Game Turbo 实机探测：检测到 Uperf 时选择“本模块覆盖接管 CPU 调度”或“不覆盖，交给 Uperf/外部模块”；未检测到 Uperf 时只提示“启用/不启用本模块 CPU 调度”，不会引导安装外部模块。
- WebUI 性能页显示 Uperf 探测状态、模块名、启用状态和当前调度接管方；按钮文案按“覆盖 Uperf / 不覆盖 Uperf / 启用本模块调度 / 停用本模块调度”四种语义切换。
- `profile.sh` GET 增加 `uperf_detected`、`uperf_module_id/name/path/source/state/enabled` 字段，安装期与 WebUI 共用 `scripts/scheduler_detect_lib.sh`，避免探测口径分叉。

### v4.4.6

- 修复审计余患：后台应用限制新增 `.bg_restrict_baseline`，添加限制前记录原始 standby bucket 与 AppOps，移除包名或关闭功能时优先按原值恢复，避免一律放宽到 `active/allow`。
- WebUI token 改为每次 `service.sh` 启动重新生成，缩短 token 暴露后的可用窗口；`httpd` 改用 `.webui_httpd.pid` 定位本模块实例，避免端口粗匹配误杀其它 httpd。
- `.profile_history` 新增 `sched_owner` 字段，外部调度接管时可直接区分 `pixel/external`；`energy.sh` 的 cache lock 增加 stale 回收，避免异常退出后长期返回旧功耗快照。

### v4.4.5

- 新增 `Uperf Game Turbo 共存模式`：安装向导与 WebUI 性能页均可开启。开启后，本模块停止写入 CPU 调度相关节点，包括 `sched_pixel response_time_ms`、`sched_util_clamp_min`、`/dev/cpuset/*/cpus` 与 `/proc/vendor_sched/ug_bg_*`，CPU 调度权交给 Uperf/外部模块。
- 共存模式仅让出 CPU 调度权；温控阈值、ZRAM/VM、NR 息屏降级、SIM2 空槽管理、后台应用限制、UECap 管理等功能仍按原逻辑运行。

### v4.4.4

- 调整 `balanced` 为低热日用底座：`response_time_ms` 从 `16/24/160` 改为 `16/40/200`，保持 `top-app=cpu0-7` 与 `sched_util_clamp_min=0`。目标是在 PiliPlus/视频/信息流等稳态前台负载下降低中核持续补偿与 X4 介入，同时保留日常 burst 兜底。

### v4.4.3

- 修复 WebUI 温度历史折线图只加载一次的问题：弹窗打开后每 10 秒静默刷新，关闭、返回或切换其它详情时自动清理刷新器。


## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 机型分支已适配；未实际测试 |

安装时自动检测机型，刷入对应的温控配置。
基带配置仅限 Pixel 9 Pro。

## 功能

### CPU 调度 (4 种模式)

| 模式 | top-app | 说明 | 小核 resp | 中核 resp | 大核 resp |
|------|---------|------|-----------|-----------|-----------|
| 性能优先 | cpu0-7 | 还闸放开动态 boost (cap→1024)，手动专用；不参与自动策略 | 12ms | 20ms | 80ms |
| 均衡 | cpu0-7 | 低热日用底座，兼顾视频/feed 稳态和日常 burst | 16ms | 40ms | 200ms |
| 省电 | cpu0-6 | 避免 X4 常态介入，优先控温和续航 | 32ms | 96ms | 200ms |
| 默认 | cpu0-7 | 接近 Google 默认响应曲线，作为保守回退 | 16ms | 64ms | 200ms |

- 调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`
- `foreground/cpus` 会被 framework 重置到 `0-6`，模块主要托管 `top-app/background/system-background`
- 选择“不覆盖 Uperf/外部调度”后，本模块不再周期性写 CPU 调度节点，WebUI 的 profile/auto/enforce 会暂停；若未检测到 Uperf，v4.4.8 起会先执行一次 `balanced` 安全底座清理，避免旧高 boost 残留。

### 前台自动调度

- 模式：`manual` / `auto`
- `manual`：固定使用当前选中的 profile
- `auto`：以 `balanced` 作为亮屏日常底座，只在持续热平台做**慢切换收口**
  - 亮屏前台默认保持 `balanced`
  - `VIRTUAL-SKIN >= 40.8°C` 持续约 `90s` 后压到 `battery`
  - `battery` 状态下温度回落到 `40.4°C` 以下持续约 `60s` 后恢复 `balanced`
  - 充电 / 有线 ADB 场景独立使用体感热闸：`VIRTUAL-SKIN >= 41.0°C` 持续约 `120s` 后压到 `battery`
  - 充电体感热回落到 `39.5°C` 以下持续约 `90s` 后恢复 `balanced`；系统 `thermalservice severity >= 2` 时仍立即压到 `battery`
  - 息屏后回到 `balanced`

- 自动模式不会自动进入 `performance`
- `.profile_history` 会记录启动 baseline 与最近 500 条切档证据（时间、policy、sched_owner、profile、reason、充电状态、VIRTUAL-SKIN、thermal severity、cap、response_time_ms），用于 ADB + Scene 复盘
- `performance` 在 `12/20/80` 升频节奏基础上把 `sched_util_clamp_min` 还原到出厂 `1024`，放开 ADPF/HBoost/fork/ExoPlayer 等内核动态 boost（顺内核“还闸”，不写 vendor 黑箱地板）；放开 boost 后温升更快，长亮屏/热平台请使用 `balanced` 或 `battery`
- `light` 已在 v4.3.22 删除：实测 steady-state 前台负载下，小核低频高占用会诱发中核补偿升频，反而更费电
- `responsive` 已在 v4.4.0 由 `performance` 取代（两者同为 `12/20/80`，performance 多了 cap 还闸维度）；老配置自动迁移

### 三层功耗优化

| 层 | 机制 | 持久化 | 说明 |
|----|------|--------|------|
| L1 | App Standby Bucket + AppOps | 重启保留 | 列表中的应用降至 RESTRICTED + 禁止后台自启，WebUI 可增删 |
| L2 | vendor_sched 后台 CPU 限制 | volatile + enforce 守护 | bg_uclamp_max=200, bg_group_throttle=100 (亮屏每 15s 校验) |
| L3 | sched_pixel response_time_ms + sched_util_clamp_min | volatile, 切档时写 | 由 CPU 调度模式管理；`performance` 档把 cap 还原 1024 |

- L1 通过 WebUI「后台应用限制」卡片配置，支持添加/移除/开关/刷新
- L2 全自动，无需用户操作
- 外部调度接管时跳过周期性 L2/L3 写入，避免与 Uperf 或其它外部调度模块互相覆盖；未检测到 Uperf 时会先做一次 `balanced` 安全底座清理
- `sched_util_clamp_min` 按档管理：它是 uclamp.min 的**系统级上限 (cap)**，不是“虚假 100% 利用率信号”（内核文档 sched-util-clamp）；非性能档=`0`（抑制走 per-task 请求路径的 boost），`performance`=`1024`（还 Google 出厂上限，放开动态 boost）

### 温控优化 (4 档可调)

| 档位 | Offset偏移值 | 最早介入温度 (HINT) | 说明 |
|------|--------|---------------------------|------|
| 出厂阈值 | +0°C | 37°C | Google 原厂设定 |
| 轻度放宽 | +2°C | 39°C | 提升 +2°C |
| 日常推荐 | +4°C | 41°C | 模块默认设定 |
| 性能优先 | +6°C | 43°C | 提升 +6°C |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器（VIRTUAL-SKIN / HINT / SOC / CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU）。各传感器 Google 原厂首档不同（HINT 37°C 最低，GPU 43°C 最高），偏移统一叠加。安全阈值 `55°C` 保留不变。

WebUI 实时温度优先解析 `thermalservice` 的 `Current temperatures from HAL`，缓存超过 `30s` 会强制重建，避免长时间运行后旧缓存或 `Cached temperatures` 段造成显示偏差。

### ZRAM / 内存优化

- 算法：`lz77eh`（Emerald Hill 硬件加速）
- 容量：`11392MB`
- VM 参数：`swappiness=100`、`min_free_kbytes=65536`、`vfs_cache_pressure=60`

### 待机与 modem 策略

保留 `5G / 5GA / CA / IMS` 能力，通过使用层优化降低功耗：

| 设置项 | 值 | 说明 |
|--------|-----|------|
| `adaptive_connectivity_enabled` | `1` | Google 官方 5G 节电建议：app 不需要高速时自动 NR→LTE |
| `network_recommendations_enabled` | `1` | 系统网络建议 |
| `mobile_data_always_on` | `0` | Wi-Fi 下不保持蜂窝常驻 |
| `wifi_scan_always_enabled` | `0` | 关闭 Wi-Fi 后台常扫 |
| `ble_scan_always_enabled` | `0` | 关闭 BLE 后台常扫 |
| `nearby_sharing_enabled` | `0` | 关闭 Nearby Sharing |

- Wi-Fi multicast：亮屏开启，息屏关闭
- SIM2 空槽：默认关闭（手动开启）。通过 `cmd phone set-sim-count 1` 在息屏时将 modem 实例从 2 降到 1，消除空槽 modem 的搜网/IMS 注册开销。亮屏或检测到 SIM2 插入时自动恢复双 modem
- 待机隔离模式：仅用于过夜 A/B 排障。开启后，息屏阶段暂停 NR 降级、SIM2 管理、功耗采样、thermal burst 和自动调度，尽量把 control 模块的待机干扰降到最低

### NR 息屏降级

- 息屏超过 300 秒后将网络模式切换到 LTE
- 亮屏时恢复保存的 NR 模式
- 热点开启时跳过切换

### Doze 友好后台

| 状态 | sleep 间隔 | 探屏方式 |
|------|-----------|----------|
| 亮屏 | 15s | sysfs `card0-DSI-1/enabled`（IPC-free） |
| 息屏首次 | 60s | 同上 |
| 息屏后续 | 600s | 同上 |
| 已降 LTE | 300s | 同上 |
| 温度突发 | 5s | 同上（用户触发, 5 分钟） |

- 探屏改 sysfs 直读（替换 `dumpsys display`），消除模块自身对 Linux kernel suspend 的设计性阻碍
- `.standby_diag_state` 低噪声诊断摘要，记录 worker 当前分支、下一次唤醒时间和 profile / NR 状态
- `待机隔离模式` 显式开关，便于把"是不是 control 模块挡住 deep sleep"收敛成可执行的 A/B 测试


### UE 网络能力 / UECap 切换

UECap 告诉基站"手机支持哪些载波组合"。**不直接影响功耗**——功耗取决于信号强度和 modem 活跃时间。

| 配置 | 内部模式 | 说明 | 对比默认 |
|------|----------|------|----------|
| **国内频段** | `balanced` | 原厂 +25 组中国 NR 组合 (n28/n41/n79) | +25 / -0 / ~0 |
| 全面增强 | `special` | 原厂 +52 组全球 NR 组合 | +52 / -0 / ~0 |
| Google 默认 | `universal` | 原厂能力表，不做任何修改 | +0 / -0 / ~0 |

- 切换只重启蜂窝 modem，不影响 Wi-Fi / 蓝牙
- WebUI 切换后自动校验配置摘要，确认一致后才提示成功

### 独立基带模块协同

本项目采用双模块架构，两个模块可独立工作：

| 模块 | 详情 |
|------|------|
| `pixel9pro_control` | 温控、CPU 调度、ZRAM、UECap 三档切换、NR 降级、SIM2 管理、WebUI |
| `pixel9pro_baseband_trial` | CarrierSettings (3210 .pb)、China MCFG (5 .mbn)、APN、VoLTE/VoNR/WFC props |

- 只安装控制模块：温控/调度/WebUI 正常工作，UECap 可切换，无基带增强
- 只安装基带模块：VoLTE/VoNR 自动生效，UECap 保持原厂
- 两个模块都装：控制模块 WebUI 检测并展示基带模块状态

**基带模块兼容性**：`pixel9pro_baseband_trial` 中的 CarrierSettings / MCFG 基于中国运营商配置。UECap binarypb 由控制模块管理，基于 Pixel 9 Pro (Exynos 5400 modem) 固件定制。Pixel 9 Pro XL 不可共用，binarypb 需重新提取。

### NTP 服务器选择

可选：`ntp.aliyun.com`（本模块默认配置）、`ntp.myhuaweicloud.com`、`ntp1.xiaomi.com`、`time.android.com`

### WebUI

端口 6210，`http://127.0.0.1:6210`（仅绑定 127.0.0.1 回环）。

- 性能页支持 `手动 / 自动` 调度策略切换，并显示当前自动切换原因
- 优化页支持 `SIM2 空槽管理`、`待机隔离模式`、`后台应用限制` 显式开关，以及 `后台 worker 摘要` 只读诊断卡片
- 温度历史窗口：10分钟 / 30分钟 / 2.5h / 12h
- 功耗详情区分"当前放电会话 / 今日累计 / batterystats 窗口"；蜂窝功耗同时显示 ODPM 硬件实测与系统估算
- 安全：启动时轮换随机 token、`info.sh` 不再下发 token、写操作需 `X-PIXEL9PRO-TOKEN`、CSP `script-src 'self'`、写操作强制 JSON + CORS preflight
- token 配对：`cat /data/adb/modules/pixel9pro_control/.webui_token` 后可打开 `http://127.0.0.1:6210/#token=<token>`，或首次写操作时在浏览器 prompt 中输入

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载 `pixel9pro_control.zip` 最新版
2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
3. APatch / KernelSU / Magisk → 模块 → 从存储安装
4. **首次安装**：音量键交互向导，可选择温控偏移、CPU 调度、Uperf/外部调度接管关系、UECap 档位（仅 APatch/KSU）、NR 降级、NTP
5. **升级安装**：自动迁移已有设置；若旧配置缺少调度接管设置，会提示选择是否由本模块接管 CPU 调度
6. 重启
7. 打开 `http://127.0.0.1:6210` 验证

## 兼容性

- `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
- `Android 17 QPR1 Beta 1 (SDK 37)` 当前验证基线
- `APatch ` 实机验证
- `KernelSU 0.9+` 代码兼容（需 metamodule，未完成真机闭环）
- `Magisk v27+` 代码兼容（v4.4.0 未完成真机闭环）

### Root 实现差异

| 功能 | APatch / KSU+metamodule | Magisk |
|---|---|---|
| 温控阈值偏移、CPU 调度、ZRAM、L1-L3 功耗、SIM2、NR 降级、WebUI | ✅ | ✅ |
| UECap 三档基带切换 (balanced/special/universal) | ✅ | ❌ 不支持 |

## 已知问题

### 卡二屏

| 原因 | 解决 |
|------|------|
| `thermal_info_config.json` 格式错误 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动 | 同上 |

**紧急恢复**：长按电源键 → 第二屏时电源+音量下进安全模式 → 重启


### Chrome 缓存

顶栏版本号不对说明缓存命中。绕过：访问 `http://127.0.0.1:6210/?r=<随机数>`

## 致谢

- **[Sun_Dream（酷安）](https://www.coolapk.com/u/1281808)** — cpuset + sched_pixel 调度思路、基带模块 PLMN/CarrierSettings 设计
- **[DYSBRT（酷安）](https://www.coolapk.com/u/22128139)** — 5G CA 设计

## 免责声明

本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入
- **稳定性风险**：修改 CPU 调度参数可能导致系统不稳定
- **网络风险**：NR 息屏降级会在息屏时切换网络模式

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任。**

- **Pixel**、**Android**、**Tensor**、**Material Design** 是 Google LLC 的商标。本项目与 Google LLC 无任何关联。
