# Pixel 9 Pro Control Module

> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、可选 CPU 调度、ZRAM、待机优化和 UE 网络控制模块；可与 Uperf Game Turbo 等外部调度模块协同。（Magisk 下基带 UE 切换不可用）。

## 当前版本

- Release: `v4.4.11`
- versionCode: `75`
- Asset: `pixel9pro_control_v4.4.11.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`
- 组件版本: 见 `versions.prop` (webui / scheduler / core)

### v4.4.11

- WebUI token 改为**静默自动填充**：写操作首次触发时由前端从本机 loopback `auth.sh` 静默读取 token，不再弹确认框；仅当 `auth.sh` 不可达时回退手动输入。`#token=<token>` 仍可会话配对。
- CPU 调度面板收敛为「均衡 / 省电」两档；性能优先与默认退出 WebUI（降为 force/CLI/boot 内部基线），更强性能请切到 UGT `external` 外部接管。老用户旧 `performance`/`default`/`responsive`/`light` 档安装时自动迁移到 `balanced`。
- 版本治理：引入 `versions.prop` 组件分版（webui/scheduler/core），改哪个组件只升对应行；`index.html` 的 `?v=` 由打包脚本据 `versions.prop` 自动戳，安装/日志横幅动态读 `module.prop`，不再全局齐改版本号。

### v4.4.10

- 修复 `external` 调度接管时 standby worker 诊断 `active_profile` 可能沿用旧缓存的问题，确保 WebUI 待机守护诊断与 `profile.sh` 当前状态一致。
- 保留 v4.4.9 的 token prompt 预填、待机隔离响应修正、后台限制解析修正与 CSP console error 修正。

### v4.4.9

- 优化 WebUI token 会话体验：首次写操作弹窗会从本机 loopback 自动读取并预填 token，`#token=<token>` 仍可直接配对。
- 修复待机隔离模式响应被旧诊断状态覆盖，以及后台限制列表在 Android `/system/bin/sh` 下解析为空的问题。
- 保留 v4.4.8 的 UGT `external` 安全底座、NR 热点识别、旧配置迁移、功耗/温度历史导出能力。

## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 机型分支已适配；未实际测试 |

安装时自动检测机型，刷入对应的温控配置。
基带配置仅限 Pixel 9 Pro。

## 功能

### CPU 调度 / UGT 外部调度接管

本模块内置 Pixel 原厂调度参数微调；如已安装 Uperf Game Turbo，可在安装向导或 WebUI 中选择 `external`，将 CPU scene / 游戏调度交由 UGT 处理。本项目不打包、不改写 UGT，只做只读探测和调度让权。

**v4.4.11 起 WebUI 仅提供「均衡 / 省电」两档**；性能优先与默认降为内部基线（force/CLI/boot 兜底，不在 WebUI），需要更强性能请切到 UGT `external` 接管。下表后两档仅作内部参数参考。

| 模式 | top-app | 说明 | 小核 resp | 中核 resp | 大核 resp |
|------|---------|------|-----------|-----------|-----------|
| 性能优先 | cpu0-7 | 内部基线 (force/CLI)，v4.4.11 起不在 WebUI；还原动态 boost 上限 (cap=1024)；不参与自动策略 | 12ms | 20ms | 80ms |
| 均衡 | cpu0-7 | 低热日用底座，兼顾视频/feed 稳态和日常 burst | 16ms | 40ms | 200ms |
| 省电 | cpu0-6 | 避免 X4 常态介入，优先控温和续航 | 32ms | 96ms | 200ms |
| 默认 | cpu0-7 | 内部基线 (开机/CLI 兜底)，v4.4.11 起不在 WebUI；接近 Google 默认响应曲线 | 16ms | 64ms | 200ms |

- 调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`
- `foreground/cpus` 会被 framework 重置到 `0-6`，模块主要托管 `top-app/background/system-background`
- 前台自动调度仅在 `.cpu_sched_owner=pixel` 时生效；选择 `external` 后，本模块主动让位给 UGT 或其它外部调度模块
- 选择“不覆盖 Uperf / external”后，本模块不再周期性写 CPU 调度节点，WebUI 的 profile/auto/enforce 会暂停；若未检测到 Uperf，v4.4.8 起会先执行一次 `balanced` 安全底座清理，避免旧高 boost 残留

当 `.cpu_sched_owner=external` 时，本模块会跳过：

- `sched_pixel response_time_ms`
- `sched_util_clamp_min`
- `/dev/cpuset/*/cpus`
- `/proc/vendor_sched/ug_bg_*`

此时前台交互、游戏、线程 affinity/prio、top-app 与 touch scene 由 UGT 自身策略处理；本模块继续负责温控、ZRAM、NR/SIM2、UECap 与 WebUI。


### 温控优化 (4 档)

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

### 待机与 modem 策略（以 Google 默认机制为主）

本模块不再强行削弱 modem 能力，保留 `5G / 5GA / CA / IMS` 能力，主要通过系统设置和使用层策略降低待机功耗：

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



### UE 网络能力 / UECap 切换

UECap 告诉基站"手机支持哪些载波组合"。**不直接影响功耗**——功耗取决于信号强度和 modem 活跃时间。

| 配置 | 内部模式 | 说明 | 对比默认 |
|------|----------|------|----------|
| **国内频段** | `balanced` | 原厂 +25 组中国 NR 组合 (n28/n41/n79) | +25 / -0 / ~0 |
| 全面增强 | `special` | 原厂 +52 组全球 NR 组合 | +52 / -0 / ~0 |
| Google 默认 | `universal` | 原厂能力表，不做任何修改 | +0 / -0 / ~0 |

- 切换只重启蜂窝 modem，不影响 Wi-Fi / 蓝牙
- WebUI 切换后自动校验配置摘要，确认一致后才提示成功

### 独立模块与外部调度协同

本项目当前按“控制模块 + 基带模块 + 第三方外部调度模块”协同使用。三者都可以独立安装和独立工作；其中 `pixel9pro_control` 与 `pixel9pro_baseband_trial` 由本项目维护，Uperf Game Turbo 是第三方项目，本项目只做只读探测和 CPU 调度让权，不打包、不改写、不替代其上游维护。

| 模块 | 归属 | 详情 |
|------|------|------|
| `pixel9pro_control` | 本项目 | 温控、ZRAM、UECap 三档切换、NR 降级、SIM2 管理、WebUI；未让出时可管理 Pixel 原厂 CPU 调度 |
| [`pixel9pro_baseband_trial`](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/download/v4.3.11/pixel9pro_baseband_trial_v1.0.1.zip) | 本项目可选基带模块 | CarrierSettings (3210 .pb)、China MCFG (5 .mbn)、APN、VoLTE/VoNR/WFC props |
| Uperf Game Turbo | 第三方外部调度模块 | CPU scene 调度、输入/前台/游戏线程调度、per-app 性能模式；由 UGT 上游独立维护 |

- 只安装控制模块：温控/ZRAM/NR/SIM2/UECap/WebUI 正常工作；CPU 调度默认由本模块管理，也可手动设为 `external` 停用本模块调度
- 只安装基带模块：下载 `pixel9pro_baseband_trial_v1.0.1.zip` 后单独刷入，VoLTE/VoNR 自动生效，UECap 保持原厂
- 只安装 UGT：UGT 自行接管 CPU scene / 游戏调度；不包含本项目温控、基带增强和 WebUI
- 控制模块 + 基带模块：WebUI 检测并展示基带模块状态；UECap 由控制模块管理，CarrierSettings / MCFG 由基带模块提供
- 控制模块 + UGT：首次安装检测到启用中的 UGT 即默认 `external`（交 UGT 接管）；本模块停止写 CPU 调度节点，保留温控、ZRAM、NR/SIM2、UECap 和 WebUI
- 三者都安装：推荐的协同边界是 UGT 负责 CPU 调度，本模块负责温控与系统优化，基带模块负责运营商配置增强

**基带模块兼容性**：`pixel9pro_baseband_trial` 中的 CarrierSettings / MCFG 基于中国运营商配置。UECap binarypb 由控制模块管理，基于 Pixel 9 Pro (Exynos 5400 modem) 固件定制。Pixel 9 Pro XL 不可共用，binarypb 需重新提取。

**UGT 协同说明**：Uperf Game Turbo 为第三方外部调度项目，建议从其官方发布渠道安装和更新。本项目不会引导安装 UGT；首次安装检测到启用中的 UGT 时默认交其接管（`external`），可在 WebUI 改回本模块接管。`external` 下本模块前台自动 CPU 调度不再生效，避免与 UGT 互相抢写 `cpuset`、`uclamp`、`sched_pixel` 或其它调度节点。

### NTP 服务器选择

可选：`ntp.aliyun.com`（本模块默认配置）、`ntp.myhuaweicloud.com`、`ntp1.xiaomi.com`、`time.android.com`

### WebUI

端口 6210，`http://127.0.0.1:6210`（仅绑定 127.0.0.1 回环）。

- 性能页在本模块接管 CPU 调度时支持 `手动 / 自动` 策略切换；选择 `external` 后显示调度接管状态并暂停 profile/auto/enforce 写入
- 优化页支持 `SIM2 空槽管理`、`待机隔离模式`、按包策略 `后台应用限制` 显式开关，以及 `后台 worker 摘要` 只读诊断卡片；后台限制默认仅预置抖音，策略为“休眠”：锁屏或离开前台 5 分钟后 `force-stop`
- 温度历史窗口：10分钟 / 30分钟 / 2.5h / 12h
- 功耗详情区分"当前放电会话 / 今日累计 / 15-30-60 分钟短窗口 / batterystats 窗口"；蜂窝功耗同时显示 ODPM 硬件实测与系统估算，系统 `mobile_radio` 仅作失真参考
- 功耗详情支持手动保存 15/30/60 分钟或本次 WebUI 窗口的功耗与温度历史到 `/sdcard/Download`
- 安全：启动时轮换随机 token、`info.sh` 不下发 token、写操作需 `X-PIXEL9PRO-TOKEN`、CSP `script-src 'self'`、写操作强制 JSON + CORS preflight
- token 配对：`cat /data/adb/modules/pixel9pro_control/.webui_token` 后可打开 `http://127.0.0.1:6210/#token=<token>`；首次写操作时前端会从本机 loopback `auth.sh` 静默读取并自动填充当前 token（无弹窗，不可达才回退手输）

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载 `pixel9pro_control.zip` 最新版
2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
3. APatch / KernelSU / Magisk → 模块 → 从存储安装
4. **首次安装**：音量键交互向导，依次配置温控偏移、CPU 调度（检测到启用中的 UGT 则默认交其接管；否则四选一：不接管／均衡／省电／自动）、UECap 档位（仅 APatch/KSU）、NR 降级、NTP
5. **升级安装**：自动迁移已有设置（旧 performance/default 调度档并入均衡）；若旧配置缺调度接管设置，则检测到 UGT 默认交其接管、否则默认本模块管理（不打断升级）
6. 重启
7. 打开 `http://127.0.0.1:6210` 验证

## 兼容性

- `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
- `Android 17 QPR1 Beta 1 (SDK 37)` 当前验证基线
- `APatch 0.10+` 实机验证
- `KernelSU 0.9+` 代码兼容（需 metamodule，未完成真机闭环）
- `Magisk v27+` 代码兼容（v4.4.0 未完成真机闭环）

### Root 实现差异

| 功能 | APatch / KSU+metamodule | Magisk |
|---|---|---|
| 温控阈值偏移、CPU 调度、ZRAM、后台应用限制、SIM2、NR 降级、WebUI | ✅ | ✅ |
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
- **[Uperf Game Turbo](https://github.com/yinwanxi/Uperf-Game-Turbo)** — 第三方全平台用户态性能控制器；本模块仅做探测与让权协同

## 免责声明

本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入
- **稳定性风险**：修改 CPU 调度参数可能导致系统不稳定
- **网络风险**：NR 息屏降级会在息屏时切换网络模式

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任。**

- **Pixel**、**Android**、**Tensor**、**Material Design** 是 Google LLC 的商标。本项目与 Google LLC 无任何关联。
