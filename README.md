# Pixel 9 Pro Control Module

> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、可选 CPU 调度、ZRAM、待机优化和 UE 网络控制模块；附 Material 3 WebUI 控制台，可与 Uperf Game Turbo、fas-rs 等外部调度模块协同。（Magisk 下基带 UE 切换不可用。）

## 当前版本

- Release: `v4.4.24`
- versionCode: `88`
- Asset: `pixel9pro_control_v4.4.24.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`

## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 机型分支已适配；未实际测试 |

安装时自动检测机型，刷入对应的温控配置。基带配置仅限 Pixel 9 Pro。

## 功能

### CPU 调度 / 外部调度接管

本模块内置 Pixel 原厂调度参数微调；如已安装 Uperf Game Turbo、fas-rs 或其它外部调度器，可在安装向导或 WebUI 中选择 `external`，将 CPU scene / 游戏调度交由外部调度器处理。本项目不打包、不改写 UGT / fas-rs，只做只读探测和调度让权。

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
- 前台自动调度仅在 `.cpu_sched_owner=pixel` 时生效；选择 `external` 后本模块主动让位给 UGT / fas-rs / 其它外部调度模块，并暂停 WebUI 的 profile/auto/enforce 写入
- 切到 `external` 后若未检测到启用中的外部调度器，本模块仍保持让权，不会自动回写 `balanced`

当 `.cpu_sched_owner=external` 时，本模块跳过 `sched_pixel response_time_ms`、`sched_util_clamp_min`、`/dev/cpuset/*/cpus`、`/proc/vendor_sched/ug_bg_*`；此时前台交互、游戏、线程 affinity/prio、top-app 与 touch scene 由 UGT / fas-rs / 外部调度器自身策略处理，本模块继续负责温控、ZRAM、NR/SIM2、UECap 与 WebUI。

### 温控优化 (4 档)

| 档位 | Offset 偏移值 | 最早介入温度 (HINT) | 说明 |
|------|--------|---------------------------|------|
| 出厂阈值 | +0°C | 37°C | Google 原厂设定 |
| 轻度放宽 | +2°C | 39°C | 提升 +2°C |
| 日常推荐 | +4°C | 41°C | 模块默认设定 |
| 性能优先 | +6°C | 43°C | 提升 +6°C |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器（VIRTUAL-SKIN / HINT / SOC / CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU）。各传感器 Google 原厂首档不同（HINT 37°C 最低，GPU 43°C 最高），偏移统一叠加。安全阈值 `55°C` 保留不变。

WebUI 实时温度优先解析 `thermalservice` 的 `Current temperatures from HAL`，缓存超过 `30s` 强制重建，避免长时间运行后旧缓存造成显示偏差。

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
- SIM2 空槽：默认关闭（手动开启）。通过 `cmd phone set-sim-count 1` 在息屏时将 modem 实例从 2 降到 1，消除空槽 modem 的搜网/IMS 注册开销；亮屏或检测到 SIM2 插入时自动恢复双 modem
- 待机隔离模式：仅用于过夜 A/B 排障。开启后息屏阶段暂停 NR 降级、SIM2 管理、功耗采样、thermal burst 和自动调度，尽量把 control 模块的待机干扰降到最低
- 后台应用限制：按包选择 `降低后台优先级 / 禁止后台服务 / 禁止后台活动 / 休眠` 策略，默认仅预置抖音（休眠：锁屏或离开前台延时后 `force-stop`），移除或关闭时按接管前 bucket/AppOps 恢复

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
| `pixel9pro_control` | 本项目 | 温控、ZRAM、UECap 三档切换、NR 降级、SIM2 管理、后台限制、WebUI；未让出时管理 Pixel 原厂 CPU 调度 |
| [`pixel9pro_baseband_trial`](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/download/v4.3.11/pixel9pro_baseband_trial_v1.0.1.zip) | 本项目可选基带模块 | CarrierSettings (3210 .pb)、China MCFG (5 .mbn)、APN、VoLTE/VoNR/WFC props |
| Uperf Game Turbo / fas-rs / 其它外部调度器 | 第三方或独立外部调度模块 | CPU scene 调度、输入/前台/游戏线程调度、frame-aware 调度、per-app 性能模式；由各自上游独立维护 |

- 只安装控制模块：温控/ZRAM/NR/SIM2/UECap/WebUI 正常工作；CPU 调度默认由本模块管理，也可手动设为 `external` 停用
- 只安装基带模块：单独刷入 `pixel9pro_baseband_trial_v1.0.1.zip`，VoLTE/VoNR 自动生效，UECap 保持原厂
- 控制模块 + 基带模块：WebUI 检测并展示基带模块状态；UECap 由控制模块管理，CarrierSettings / MCFG 由基带模块提供
- 控制模块 + 外部调度：首次安装检测到启用中的 UGT / fas-rs 即默认 `external`（交外部调度器接管），可在 WebUI 改回本模块接管
- 三者都安装：推荐边界为外部调度器负责 CPU / 游戏调度、本模块负责温控与系统优化、基带模块负责运营商配置增强

**基带模块兼容性**：`pixel9pro_baseband_trial` 中的 CarrierSettings / MCFG 基于中国运营商配置；UECap binarypb 由控制模块管理，基于 Pixel 9 Pro (Exynos 5400 modem) 固件定制。Pixel 9 Pro XL 不可共用，binarypb 需重新提取。

**外部调度协同说明**：Uperf Game Turbo、fas-rs 等为外部调度项目，建议从其官方渠道安装和更新。本项目不引导安装外部调度器；`external` 下本模块前台自动 CPU 调度不再生效，避免与 UGT / fas-rs 互相抢写 `cpuset`、`uclamp`、`sched_pixel` 等节点。`external` 是让权态，不会因为未检测到外部调度器而自动回落到 `balanced`。

**owner arbiter**：`scripts/owner_arbiter.sh` 默认仍是 Phase A dry-run 观测，每个亮屏 worker 周期读取 top-app、fas-rs `games.toml` / `.lease_game_list`、Scene `games.xml`（仅当 fas-rs `scene_game_list=true`）、UGT/fas-rs 状态和本模块 `.cpu_sched_owner`，把建议状态写到 `/data/adb/fas_rs/.arbiter_state` 与 `.arbiter_history`；fas-rs `exclude_list` 会优先阻止 lease。创建 `/data/adb/fas_rs/.arbiter_apply` 或手动执行 `owner_arbiter.sh apply-tick` 后进入受保护 Phase B：命中游戏稳定后停止 `uperf`、启动 `fas-rs` 并保持 `.cpu_sched_owner=external`；退出 lease 后恢复原 baseline owner，若 baseline 为 UGT 则恢复 `uperf`。UGT 恢复启动带 `/sdcard` 可用性检查、`.uperf_start.lock` 互斥、启动后 5s 稳定窗口与重复实例归一，避免锁屏未解密时堆积等待脚本，或 service worker、UGT 自启动与手动 tick 并发拉起两组 `uperf`。创建 `/data/adb/fas_rs/.arbiter_disable` 可停止 arbiter 采样并记录 `ARB_DISABLED`。

### NTP 服务器选择

可选：`ntp.aliyun.com`（默认）、`ntp.myhuaweicloud.com`、`ntp1.xiaomi.com`、`time.android.com`。

### WebUI 控制台

端口 6210，`http://127.0.0.1:6210`（仅绑定 127.0.0.1 回环）。采用 Material 3 设计：四个一级标签页、贴边底部导航、四向安全区，支持深色 / 浅色 / 跟随系统及可换主题色。

**信息架构（四标签）**

- **状态**：当前模式、机身温度、内存与系统、CPU 实时频率、设备信息、操作记录
- **性能温控**：调度接管 / 手动·自动、CPU 实时频率与参数、性能模式卡、温度详情（刻度条 + 多传感器）、温控阈值档位
- **网络**：UECap 三档、基带模块状态、NR 息屏降级、SIM2 空槽管理
- **系统**：ZRAM/VM、后台应用限制、待机隔离、后台 worker 摘要、NTP、主题与配色

**主题与配色（调色盘）**

系统页「主题与配色」卡集成显示模式开关与主题色板：

- 显示模式：跟随系统 / 浅色 / 深色
- 预设主题色：青绿（默认）/ 天青 / 雾蓝 / 暮紫 / 樱粉 / 暖橙 / 苔绿，并支持自定义十六进制颜色
- 取色采用 Material 3 Expressive 风格的 tonal 派生：由一个种子色推导 primary / secondary / tertiary 三类强调色与中性表面轻染；强调色、选中态、状态 chips、徽章、整页背景与各级卡片表面均随主题联动；警告（琥珀）、危险（红）、温度色阶等语义色保持固定以确保可辨识
- 配色仅影响 WebUI 显示，不改变温控、调度或系统参数；选择持久保存，明暗切换自动重新派生

**其它**

- 温度历史窗口：10 分钟 / 30 分钟 / 2.5h / 12h；详情 sheet 顶部常驻关闭，长内容滚动时关闭始终可达
- 功耗详情区分「当前放电会话 / 今日累计 / 15-30-60 分钟短窗口 / batterystats 窗口」；蜂窝功耗同时显示 ODPM 硬件实测与系统估算（系统 `mobile_radio` 仅作失真参考），并可手动导出 15/30/60 分钟或本次窗口的功耗与温度历史到 `/sdcard/Download`
- 安全：启动时轮换随机 token、`info.sh` 不下发 token、写操作需 `X-PIXEL9PRO-TOKEN` 头、CSP `script-src 'self'`、写操作强制 JSON + CORS preflight；token 可经 `cat .../.webui_token` 或本机 loopback `auth.sh` 静默配对

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载最新 `pixel9pro_control_vX.Y.Z.zip`
2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
3. APatch / KernelSU / Magisk → 模块 → 从存储安装
4. **首次安装**：音量键交互向导，依次配置温控偏移、CPU 调度（检测到启用中的 UGT / fas-rs 外部调度器则默认交其接管；否则五选一：不接管／均衡／省电／系统默认／自动）、UECap 档位（仅 APatch/KSU）、NR 降级、NTP
5. **升级安装**：自动迁移已有设置（旧 performance 调度档并入均衡，系统默认档保留）；若旧配置缺调度接管设置，则检测到启用中的外部调度器默认交其接管、否则默认本模块管理
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
| UECap 三档基带切换 (balanced/special/universal) | ✅ | ❌ 不支持 |

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
