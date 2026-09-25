# Pixel 9 Pro Control Module

> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、可选 CPU 调度、ZRAM、UE 网络控制模块；Material 3 WebUI 控制台，可与 Uperf Game Turbo、fas-rs 等外部调度模块协同。（Magisk 下 UE 切换不可用）


## 支持状态

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实际测试 |
| Pixel 9 Pro XL | komodo | 无 XL 实机验证 |

安装时自动检测机型；温控默认不添加配置。CarrierSettings、APN、China MCFG 和 IMS properties 由独立的 `pixel9pro_baseband_trial` 模块按 `caiman/komodo` manifest 管理；Control 不打包独立基带模块。

## 功能

### CPU 调度 / 外部调度接管

模块内置 Pixel 9 Pro 的微调参数，支持切换 UGT 调度，并与 fas-rs 协同。


| 内置方案 | top-app | response_time_ms (小/中/大) | uclamp.min cap | 说明 |
|------|---------|------|------|------|
| ① 省电 | cpu0-6 | 16 / 96 / 320 | 0 | 保持小核效率；延后中核/X4 |
| ② 均衡 | cpu0-6 | 16 / 64 / 240 | 0 | 前台优先小中核；保留突发响应并压低长亮屏功耗 |
| ③ 系统默认 | cpu0-7 | 内核 nom（本机 9 / 52 / 165） | 1024 | 内核出厂调度：response 回写只读 `response_time_ms_nom`、cpuset 与 cap 还原出厂值 |

- 自动模式以均衡模式为主；放电 `VIRTUAL-SKIN ≥38.8°C/60s`、充电 `≥39.8°C/60s` 或 Thermal Status ≥2 时转为省电，回落到 `≤37.5°C/120s` 后恢复；临界区设有粘滞，避免边界来回抖动
- 采用 Pixel 模块的调度时，fas-rs 常驻 PID 表示服务可用；运行白名单内进程时 `effective=external`，退出后恢复原调度状态并保留 resident process
- 采用 UGT 调度时，owner worker 在触发游戏 lease 时选择暂停/恢复 UGT；退出相关进程后调用 UGT lifecycle helper 恢复UGT调度，不重放完整 boot 初始化

调度参数的所有权由 `scripts/cpu_profile_lib.sh` 的 JSON contract 统一声明：`foreground/cpus=framework`（observe-only）；`top-app/response_time_ms/sched_util_clamp_min/vendor_sched L2=pixel_best_effort`；`background/system-background=pixel_transaction`；`scaling_min/max_freq=thermal_powerhal_scene`。


### 温控策略与自定义阈值

默认只有一个零修改选项：**不修改温控（不添加配置）**。该选项不创建 `/vendor/etc/thermal_info_config.json` overlay，也不修改或停止系统 Thermal HAL。只有用户明确选择 custom 时，才从当前设备真实 vendor 配置或已验证的模块私有 stock snapshot 生成下列偏移。Hybrid Mount 只消费模块 regular source；WebUI 修改写入 source 并标记 `pending_reboot`，不在运行期 promotion、bind 或重启 Thermal HAL。

| 档位 | Offset 偏移值 | 最早介入温度 (HINT) | 说明 |
|------|--------|---------------------------|------|
| 提前介入 | -2°C | 35°C | 比出厂提前 2°C 介入 |
| 轻度放宽 | +2°C | 39°C | HINT 最早 39°C；VIRTUAL-SKIN 主阈值约 41°C |
| 日常放宽 | +4°C | 41°C | 显式 custom；靠近 SHUTDOWN 时收敛 |
| 最大放宽 | +6°C | 43°C | 前置 severity 温控 +6°C，最后安全阈值不平移 |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器（VIRTUAL-SKIN / HINT / SOC / CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU）。安装器和 WebUI 共用同一份生成逻辑，每次从当前机型 stock JSON 重建。前置 severity 先按档位平移；第 7 个 SHUTDOWN 槽位若为数值，保留 stock `55/59°C`。靠近 SHUTDOWN 时，生成器按 stock `HotHysteresis` 从后向前收窄，并额外保留 `0.1°C` 的严格间隔，保证“前一档阈值 `<` 下一档阈值减下一档 hysteresis”；只检查阈值递增并不足以保证 Pixel Thermal HAL 接受配置。SELinux 只验证 effective `/vendor/etc/thermal_info_config.json` 的 `vendor_configs_file`；模块 source 的 `system_file` label 不再被错误地当成挂载证明。

WebUI 温度优先读取后台 worker 维护的 `.thermal_cache.json`，避免普通刷新被 `dumpsys thermalservice` 慢路径阻塞；当缓存缺失、无 `VIRTUAL-SKIN`、温度越界或连续异常时，自动走 `fresh=1` 重建。

温控档位提交后进入模块私有 `.thermal_tx` journal。同一 boot 且 backend 返回
`cancel_supported=true` 时，“放弃本次修改”会携带 `pending_id` 原子恢复旧 source、policy
和 offset；跨 boot 或 readback degraded 状态不会显示撤销按钮。待重启期间禁止再次选择其他档位，避免覆盖同一 source。

### ZRAM / 内存优化

- 算法：由当前系统 owner 初始化；caiman / `CP41.260814.003.B1` 实机为 `lz77eh`（Emerald Hill 硬件加速）
- 容量：WebUI 只读显示设备实际 `disksize`、owner、swap 状态与 `SwapTotal`；APatch 0.13.8 + Hybrid Mount 下由 mmd 独占 ZRAM，Control 不 reset/swapoff/resize；
- VM 参数：`swappiness=100`、`min_free_kbytes=131072`、`watermark_scale_factor=200`、`vfs_cache_pressure=60`
- 首次安装默认 `feature_vm=system`，模块不写 ZRAM；VM/dirty 参数仅在用户显式选择后写入。WebUI 的 ZRAM 容量请求先写 mmd 官方 `mmd.zram.size`，仅在当前 swap 未启用且设备提供 `mmd --setup-zram` 时尝试在线应用；正在使用的 zram 不执行 swapoff/reset，返回 `pending_reboot` 由 mmd 在下次启动应用。

### 待机与 modem 策略（以 Google 默认机制为主）

模块保留 `5G / 5GA / CA / IMS` 能力，主要通过系统设置和使用层策略降低待机功耗：

| 设置项 | 值 | 说明 |
|--------|-----|------|
| `adaptive_connectivity_enabled` | `1` |  NR→LTE |
| `network_recommendations_enabled` | `1` | 系统网络建议 |
| `mobile_data_always_on` | `0` | Wi-Fi 下不保持蜂窝常驻 |
| `wifi_scan_always_enabled` | `0` | 关闭 Wi-Fi 后台常扫 |
| `ble_scan_always_enabled` | `0` | 关闭 BLE 后台常扫 |
| `nearby_sharing_enabled` | `0` | 关闭 Nearby Sharing |



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
| Google 默认 | `universal` | 不做任何修改 | +0 / -0 / ~0 |

- 切换只重启蜂窝 modem，不影响 Wi-Fi / 蓝牙
- WebUI 切换后自动校验配置摘要，确认一致后才提示成功

UECap 的设备边界必须与实际状态分开理解：`caiman` 使用
`balanced/special/universal` 三档；`komodo` 只有 `stock/candidate` 两态，默认 stock，只有用户明确选择后才 bind
`PLATFORM_6287228797510365516.binarypb`。XL 文件由用户提供

两个 `PLATFORM_*` 文件属于不同 SKU，不能改名或交叉替换。

### 独立模块与外部调度协同

本项目按“控制模块 + 基带模块 + 第三方外部调度模块”协同使用。三者都可独立安装和工作；其中 `pixel9pro_control` 与 `pixel9pro_baseband_trial` 由本项目维护，Uperf Game Turbo / fas-rs 等外部调度项目由各自上游维护。本项目不打包、不替代第三方模块。

| 模块 | 归属 | 详情 |
|------|------|------|
| `pixel9pro_control` | 本项目 | 可选温控、ZRAM、caiman 三档/komodo candidate UECap、NR 降级、SIM2 管理、后台限制、WebUI；未关闭或让出时管理 Pixel 原厂 CPU 调度 |
| `pixel9pro_baseband_trial` | 本项目可选基带模块 | 支持 caiman/komodo 的 CarrierSettings、APN、China MCFG 与 VoLTE/WFC properties；不携带、不写入任何 UECap `binarypb` |
| Uperf Game Turbo / fas-rs / 其它外部调度器 | 第三方或独立外部调度模块 | CPU scene 调度、输入/前台/游戏线程调度、frame-aware 调度、per-app 性能模式；由各自上游独立维护 |

- 只安装控制模块：温控/ZRAM/NR/SIM2/UECap/WebUI 正常工作；CPU 调度由本模块管理
- 只安装基带模块：单独安装当前明确发布的基带 ZIP，CarrierSettings/APN/IMS 配置按 manifest 生效，UECap 保持由 Control 或系统原生路径负责
- 控制模块 + 基带模块：WebUI 检测并展示基带模块状态；UECap 由控制模块管理，CarrierSettings / MCFG 由基带模块提供
- 控制模块 + UGT：Pixel/UGT 双向切换均在重启后生效；APatch 可由 WebUI staging，KernelSU/Magisk 需在各自 Root 管理器启停 UGT 后重启
- 控制模块 + fas-rs：fas-rs 在 Pixel boot 常驻待机；进入白名单进程后由 lease 进入接管，退出后恢复 Pixel 日常 profile，不通过 PID 存在单独判断 active owner
- 三者都安装：Pixel 或 UGT 作为日常 baseline；fas-rs 命中游戏时临时成为唯一调度写入者，退出后恢复进入 lease 前的同一 baseline；基带模块独立负责运营商配置增强

**基带模块兼容性**：`pixel9pro_baseband_trial` 当前源码 manifest 只允许 `caiman` / `komodo`，两机共用 CarrierSettings、APN、China MCFG 和 IMS properties，但不携带 UECap payload。Control 的 UECap binarypb 按 SKU 独立 staging：`caiman` 使用 `PLATFORM_9055801516233416490.binarypb` 三档，`komodo` 使用独立的 `PLATFORM_6287228797510365516.binarypb` candidate；不能交叉解析或改名替代。

**基带模块升级规则**：升级的是普通基带模块时，不要求卸载 APatch Manager，也不应由普通模块删除 `/data/adb/modules`、修改 `modules.img` 或自行写入 MetaModule content image。若旧模块的 active source、MetaModule content image、effective overlay、source/content/effective hash 及同一 boot 的 runtime receipt 都能复读确认，可以直接安装新版并在重启后复读；只有这些证据缺失、为空、冲突、跨 boot 或失败时，才进入 clean reinstall：Root Manager 卸载旧的普通基带模块 → 重启 → 安装新版 → 再重启 → 复读 active module、MetaModule content image、effective path、mount 和 runtime receipt。


### NTP 服务器选择

可选：`ntp.aliyun.com`（默认）、`ntp.myhuaweicloud.com`、`ntp1.xiaomi.com`、`time.android.com`。

### WebUI 控制台

端口 6210，`http://127.0.0.1:6210`（仅绑定本机回环地址）。采用 Material 3 设计，提供状态、性能温控、网络和系统四个页面；温度与功耗历史可查看采样覆盖、缺测区间并导出记录。

### 隐私安全审计日志

- 路径：`/data/adb/pixel9pro_control/logs/events.log`，目录 `0700`、文件 `0600`。
- 单文件达到 256 KiB 后轮转，保留 3 份历史。
- 只记录 schema、时间、模块版本、Root 类型、设备代号、phase、operation、result、reason code 和 duration。
- 不记录请求体、ADB endpoint、用户路径、完整包列表、原始 dumpsys/logcat、账号、号码、IMEI/IMSI/ICCID、MAC 或完整 fingerprint；边界层会把疑似值写成 `redacted`。
- CGI 失败同时返回真实 HTTP 4xx/5xx 和 `ok=false`。


**应用与 UID 识别目录**

- `config/app_identities.tsv` 是功耗排行和后台应用限制共用的唯一名称资料源，记录 Android 特殊 UID、系统分项、常用包名、中文名称、类别和限制风险级别。
- 功耗排行优先使用当前 PackageManager 的 UID→包名关系，再用目录补充易读名称；`UID -5` 会识别为“网络共享 / 热点”，未知负 UID 标成 Android 特殊统计 UID。
- 目录是只读 TSV 数据，后端使用字段白名单解析，不作为 shell 脚本 `source` / `eval`；新增常用 App 时只需增加一行，不需要修改 `energy.sh` 或 `app.js`。



## 安装

本次挂载后端设计、APatch/Hybrid Mount 生命周期与官方约束见
[`DESIGN.md`](DESIGN.md) 及 `E:\Pixel ADB\docs\` 下的研究文档。

1. 温控模块使用 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 中发布；基带模块 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases#release-v1.1.0-rc3)
2. KernelSU /Apatch用户需先安装 metamodule（如 `Hybrid Mount`）并重启
3. APatch / KernelSU / Magisk → 模块 → 从存储安装
4. **首次安装**：音量键交互向导依次配置温控、CPU 调度、按 SKU 的 UECap、NR、SIM2、VM/ZRAM 和 NTP；最终摘要后再次倒计时确认。安全默认是温控不添加配置、NR 关闭、VM/ZRAM system no-write，调度能力不完整时强制 off，komodo UECap 保持 stock。`meta-overlayfs` backend 使用 content image（温控变更需卸载重装）；Hybrid Mount backend 使用单一 regular module source（温控变更写 source，重启后复读有效 `/vendor`），两者都不执行运行期动态 bind。
5. **升级安装**：Control 自动迁移已有设置（旧 performance 调度档并入均衡，系统默认档保留）；
若旧配置缺少启动模式状态，则按 UGT 模块在下次 boot 是否启用选择 UGT 或 Pixel；已安装 fas-rs 时保留或默认启用游戏临时接管，并在退出后恢复同一 baseline。
若 MetaModule content image 仍有旧 Control 内容，安装器会拒绝覆盖并要求先卸载旧 Control、重启，再安装新包，避免 stale thermal/UECap 文件残留。
独立普通基带模块按“基带模块升级规则”判断是否升级或 clean reinstall，不因 APatch Manager 更新本身强制卸载 Manager
6. 重启
7. 打开 `http://127.0.0.1:6210` 验证

## 兼容性

- `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
- `Android 17 QPR2 Beta4  (SDK 37)` 当前验证基线
- APatch 0.13.8 bundled KernelPatch + `Hybrid Mount` 采用 regular source 挂载；安装后必须以同一 boot 的 effective readback receipt 为准
- `KernelSU 0.9+` 代码兼容
- `Magisk v27+` 普通功能代码兼容；UECap managed profiles 明确停用

### Root 实现差异

| 功能 | APatch / KSU+metamodule | Magisk |
|---|---|---|
| 温控阈值偏移、CPU 调度、ZRAM、后台应用限制、SIM2、NR 降级、WebUI | ✅ | ✅ |
| UECap：caiman 三档 / komodo stock+candidate | `meta-overlayfs` 写 content image；`Hybrid Mount` 写 regular source，重启后复读有效 `/vendor` | ❌ 不激活 |
| 独立基带模块 CarrierSettings/APN/China MCFG/IMS properties | ✅（caiman/komodo，需按各自挂载契约复读） | ✅（使用 Magic Mount；不承担 UECap） |

## 已知问题

### 卡二屏

| 原因 | 解决 |
|------|------|
| `thermal_info_config.json` 格式错误 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| thermal source 与 effective context 不同 | source 只作输入；post-mount 只读复核 effective `vendor_configs_file`，不再强制 source `chcon` |
| 活动 MetaModule content image 下通过 WebUI 修改自定义温控 | 返回 `409 Conflict`，卸载 Control、重启后重新安装并在安装向导中选择目标档位 |
| Hybrid Mount 下温控挡位反复互锁 | 已删除 thermal A/B slot、promotion 与 post-fs-data 写 `/vendor`；使用单一 `.thermal_tx` journal，同一 boot 可按 txid 撤销，复读成功后自动清理 |

**紧急恢复**：长按电源键 → 第二屏时`电源`+`音量下`进安全模式 → 重启。

### WebUI 缓存

顶栏版本号不对说明浏览器缓存命中。资源已按版本号附加缓存参数；如仍命中可访问 `http://127.0.0.1:6210/?r=<随机数>` 绕过。

## 致谢

- **[Sun_Dream（酷安）](https://www.coolapk.com/u/1281808)** — cpuset + sched_pixel 调度思路、基带模块 PLMN/CarrierSettings 设计
- **[DYSBRT（酷安）](https://www.coolapk.com/u/22128139)** — 5G CA 设计
- **[Uperf Game Turbo](https://github.com/yinwanxi/Uperf-Game-Turbo)** / fas-rs — 外部调度器；本模块仅做探测与让权协同
## 免责声明

### 验证边界


本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入
- **稳定性风险**：修改 CPU 调度参数可能导致系统不稳定
- **网络风险**：NR 息屏降级会在息屏时切换网络模式

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任。**

- **Pixel**、**Android**、**Tensor**、**Material Design** 是 Google LLC 的商标。本项目与 Google LLC 无任何关联。
