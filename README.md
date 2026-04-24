# Pixel 9 Pro Control Module v4.3.12

> APatch / KernelSU 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、CPU 调度、ZRAM、待机轻度优化和 UE 能力配置控制模块。

## 当前版本

- Release: `v4.3.12`
- versionCode: `47`
- Asset: `pixel9pro_control_v4.3.12.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`


## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 机型分支已适配；未实际测试 |

安装时自动检测机型，刷入对应的温控配置。
基带内容配置仅限Pixel 9 Pro

## 功能

### CPU 调度 (5 种模式)

| 模式 | top-app | 小核策略 | 小核 resp | 中核 resp | 大核 resp |
|------|---------|----------|-----------|-----------|-----------|
| 游戏 | cpu0-7 | 不锁最低频 | 8ms | 8ms | 12ms |
| 平衡 | cpu4-7 | 最低频 820MHz | 200ms | 12ms | 8ms |
| 轻度 | cpu4-7 | 最低频 820MHz | 200ms | 20ms | 16ms |
| 省电 | cpu4-7 | 最低频 820MHz | 500ms | 40ms | 30ms |
| 默认 | cpu0-7 | 系统默认 | 16ms | 64ms | 200ms |

- 调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`。
- 游戏模式未测试

### 温控优化 (4 档可调)

| 档位 | Offset | VIRTUAL-SKIN 首档 | 说明 |
|------|--------|-------------------|------|
| 出厂阈值 | +0°C | 39°C | 原厂阈值 |
| 轻度放宽 | +2°C | 41°C | 全档整体 +2°C |
| 日常推荐 | +4°C | 43°C | 安装默认值 |
| 性能优先 | +6°C | 45°C | 全档整体 +6°C |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器：

- `VIRTUAL-SKIN`
- `VIRTUAL-SKIN-HINT`
- `VIRTUAL-SKIN-SOC`
- `VIRTUAL-SKIN-CPU-LIGHT-ODPM`
- `VIRTUAL-SKIN-CPU-MID`
- `VIRTUAL-SKIN-CPU-ODPM`
- `VIRTUAL-SKIN-CPU-HIGH`
- `VIRTUAL-SKIN-GPU`

安全阈值 `55°C / 59°C` 保留不变。切换后尝试重启 thermal 服务。

### ZRAM / 内存优化

- 算法：`lz77eh`
- 容量：`11392MB`
- VM 参数：
  - `swappiness=100`
  - `min_free_kbytes=65536`
  - `vfs_cache_pressure=60`

### 待机与 modem 策略

- 保留 `5G / 5GA / CA / IMS` 能力，不再走“多关开关 = 更省电”的旧思路
- 模块显式管理的收敛项：
  - `mobile_data_always_on=0`
  - `wifi_scan_always_enabled=0`
  - `ble_scan_always_enabled=0`
  - `nearby_sharing_enabled=0`
  - `nearby_sharing_slice_enabled=0`
- 不再强制托管的系统项：
  - `adaptive_connectivity_enabled`
  - `adaptive_connectivity_wifi_enabled`
  - `network_recommendations_enabled`
  - `wfc_ims_enabled`
- Wi-Fi multicast：亮屏开启，息屏关闭
- SIM2 空槽：副卡槽为空时通过 `cmd phone radio power` 关闭 slot 1 radio 和 IMS，插卡后自动恢复

当前 WebUI 中，“优化”页更偏向审计这些状态是否和当前策略一致，而不再把关闭更多系统开关当作主目标。

### NR 息屏降级 (v4.0.5+)

- 息屏超过 `60` 秒后将网络模式切换到 LTE
- 亮屏时恢复保存的 NR 模式
- 恢复后冷却时间：`600` 秒
- 热点开启时跳过切换
- 默认状态：关闭（v4.3.12 起）

### Doze 唤醒 (v4.3.0+)

v4.3.0 将原 4 个独立后台循环合并为 1 个统一工作循环，大幅减少息屏 IPC 调用：

| 状态 | sleep 间隔 | dumpsys 调用频率 |
|------|-----------|-----------------|
| 亮屏 | 15s | ~4次/min |
| 息屏首次 | 60s | ~1次/min (NR 防抖) |
| 息屏后续 | 600s | ~0.1次/min |
| 温度突发 | 5s | ~12次/min (用户触发, 5 分钟) |

- WiFi multicast：仅在屏幕状态变化时切换，不再轮询
- 息屏 dumpsys 调用从 v4.2.x 的 ~10次/min 降至 ~0.1次/min

### 独立基带模块协同

- `pixel9pro_control` 负责：
  - UECap binarypb 三档切换
  - bind mount 到 `/vendor/firmware/uecapconfig/`
  - 切换后触发 cellular modem 重读能力表
- `pixel9pro_baseband_trial` 独立模块负责：
  - `CarrierSettings`
  - China `MCFG`
  - 5G / IMS 相关属性
- 当前仓库也同时保存它的源码，建议路径：`modules/pixel9pro_baseband_trial/`
- 发布时仍然分成两个 release asset：`pixel9pro_control_v4.3.12.zip` 和 `pixel9pro_baseband_trial_v1.0.1.zip`
- 控制模块的 WebUI 会检测基带模块是否已安装

**基带模块兼容性**：`pixel9pro_baseband_trial` 中的 UECap binarypb 基于 Pixel 9 Pro (caiman) 固件定制，N79 CA 组合能力依赖特定平台的 binarypb 文件结构。Pixel 9 Pro XL (komodo) 理论上可共用（同 Tensor G4 + Exynos 5400 modem）但未实测；其他 Pixel 机型使用不同 modem/平台 ID，binarypb 需重新提取。CarrierSettings / MCFG overlay 为通用中国运营商配置，适用于所有中国区 Pixel 设备。

### UE 能力配置 / UECap 切换 (v4.3.0+) 

v4.3.0 将 UECap 改为**三档切换**，移除自动策略循环。WebUI 中这一项显示为“UE 能力配置”。

先区分两个“默认”：

- **系统原生 / stock**：控制模块没有接管时，设备直接使用原厂CA配置 `PLATFORM_9055801516233416490.binarypb`
- **控制模块默认**：控制模块接管后，默认受管档位是 `balanced`（国内优先，v4.3.12 起）
- 如果只安装 `pixel9pro_baseband_trial`，UECap 仍保持 **系统原生 / stock**，因为基带模块不管理 binarypb

当前仓库实际 payload 审计结果（2026-04-24 复核）：

| 配置 | 当前 payload | SHA-256 前 8 位 | comboGroups | 相对 stock | 说明 |
|------|--------------|-----------------|-------------|------------|------|
| 系统默认 / `universal` | stock 等价副本 | `0E37F39C` | `7213` | `+0 / -0 / ~0` | 当前 `universal` 与 stock hash 完全一致，等价于回到原厂能力表 |
| `balanced` (国内优选) | `trial_minimal_cn_combo` | `2870BA9C` | `7238` | `+25 / -0 / ~0` | 只新增中国相关 `n28/n41/n79` 组合，不删除、不改写原厂顶层字段 |
| `special` (全场景增强) | `global special` | `69DF3BF6` | `7266` | `+52 / -0 / ~0` | 在 stock 基线上增加更完整的 `n79/n41/n28` 与更多 `n78/ENDC` 组合 |

组合层面的直观理解：

- `stock / universal`：原厂最小基线
- `balanced`：在 stock 上只补 25 组中国常用 NR 组合
- `special`：在 stock 上补 52 组更激进的国际+国内组合

需要特别澄清：

- 当前控制模块中的 `universal` payload hash 与出厂默认 stock 一致

- WebUI 优化页提供三选一按钮组，切换后立即生效 (bind mount)
- 切换后仅执行 `cmd phone restart-modem` 重启蜂窝 modem，不触发 `airplane mode`
- `balanced` 对应经审计的 `trial_minimal_cn_combo` payload，与 `special` 保持独立 binarypb
- 切换后 WebUI 会自动校验当前配置和目标摘要，确认一致后才提示成功
- 节电更多依赖 `Adaptive Connectivity` / `network_recommendations` / `NR 息屏降级`

### NTP 服务器选择 (v4.0.5+)

可选项：

- `ntp.aliyun.com`
- `ntp.myhuaweicloud.com`
- `ntp1.xiaomi.com`
- `time.android.com`

开机时恢复上次选择。

### WebUI 控制

端口 6210，`http://127.0.0.1:6210` 访问（仅绑定 127.0.0.1 回环）。

- 主题模式：`system / light / dark`
- 热区数据后台缓存：亮屏 `15s`，息屏 `600s`（温度突发时 `5s`）
- fetch 超时：`8s`
- 前端轮询：
  - 页面可见时仅轮询当前 tab 相关数据
  - 切到后台页或锁屏后前端轮询暂停
  - 用户闲置 `45s` 或弹窗打开时自动降频
- 温度历史打开时触发 5 分钟突发录制 (5s 间隔)
- 温度历史窗口：`10分钟 / 30分钟 / 2.5h / 12h`；其中前两个显示曲线 + 统计
- 功耗详情默认按“当前放电会话”展示，额外区分“今日累计 / Android batterystats 窗口”


### WebUI 安全

- httpd 绑定 `127.0.0.1:6210`（仅回环访问）
- 启动时生成随机 token，写操作强制 `X-PIXEL9PRO-TOKEN` 头校验
- 写操作强制 `Content-Type: application/json`，触发 CORS preflight 阻断跨域 CSRF
- 写操作加服务端 mkdir 互斥锁 + PID 过期自动回收，防并发写抖动
- CSP `script-src 'self'`（无 unsafe-inline）

## 技术背景

Pixel 内核的 `sched_pixel` governor 通过 `freq_qos` 框架管理 CPU 频率。Thermal HAL 通过独立的 `freq_qos_request` 对象控制 `scaling_max_freq`，会覆盖任何用户空间的直接写入。

本模块的策略是**非对抗 Thermal HAL**，控制 Thermal HAL 不管理的参数：
- `cpuset` — 任务核心分配 (top-app / background)
- `response_time_ms` — governor 升频响应时间

> `foreground cpuset` 由 Android 框架层在 OOM adj 重算时写回 `0-6`，不通过文件覆盖修改。
>
> `down_rate_limit_us` 为内核根据 `response_time_ms` 计算的派生值，不单独写入。

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载发行包 `pixel9pro_control_v4.3.12.zip`
2. 如果使用 **KernelSU** 且需要 `system/vendor` 覆盖（本模块的温控 JSON 属于此类），先安装 metamodule，例如 `meta-overlayfs` 或 `Hybrid Mount`，然后重启一次
3. APatch / KernelSU → 模块 → 从存储安装
4. **首次安装**：安装器提供音量键交互向导，可在安装阶段选择 UECap 档位、温控偏移等关键配置
5. **升级安装**：安装器自动从旧模块目录迁移已有设置（如 CPU 档位、NTP 选择、NR 降级开关等），无需重新配置
6. 安装器自动检测机型 (Pro / Pro XL) 并刷入对应温控配置
7. **整机重启**
8. 打开 `http://127.0.0.1:6210` 验证 WebUI

## 兼容性

- 设备：
  - `Pixel 9 Pro (caiman)` 
  - `Pixel 9 Pro XL (komodo)` （基带配置仅兼容Pixel 9 Pro）
- 系统：`Android 17 Beta 3 (SDK 37)` 为当前开发与验证基线
- Root：
  - `APatch 0.10+`：已完成本项目实机验证
  - `KernelSU 0.9+`：代码路径已兼容；`system/vendor` 覆盖需预装 metamodule；未完成 KSU 真机闭环验证

## 已知问题与故障排除


### 卡二屏（卡在开机动画）

| 原因 | 说明 | 解决 |
|------|------|------|
| `thermal_info_config.json` 格式错误 | JSON 语法不合法，Thermal HAL 拒绝加载 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动 | 脚本中的死循环阻塞 late_start | 同上 |

**紧急恢复**：长按电源键强制关机 → 开机进入第二屏时电源+音量下进安全模式 → 重启

### Chrome 缓存

Chrome 对本地 `http://` 资源缓存较强。验证方法：顶栏 kicker 显示 `Pixel 9 Pro · UI vX.Y.Z`，版本号不对就是缓存命中。

**绕过**：访问 `http://127.0.0.1:6210/?r=<随机数>`，或 Chrome 设置→网站设置→127.0.0.1→清除站点数据。

## 致谢与参考

- **Sun_Dream（酷安）** — cpuset 路由 + sched_pixel 调度思路
- **[RMBD (Reduce Modem Battery Drain)](https://github.com/Yuta-Ming/Reduce_Modem_Battery-Drain)** — 待机功耗优化参考
- **[WZL203/Pixel-8-pro-thermal-SOC-Charging-control](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-control)** — Pixel thermal_info_config.json 温控配置参考
- pixel9pro_baseband_trial 模块设计与功能均来源于酷安社区，特别鸣谢[Sun_Dream](https://www.coolapk.com/u/1281808) , [DYSSBRT](https://www.coolapk.com/u/22128139)


## 免责声明

### 风险告知

本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入，可能导致设备表面温度显著升高。极端情况下可能影响电池寿命或造成设备硬件损伤。
- **稳定性风险**：修改 CPU 调度参数和内核 VM 设置可能导致系统不稳定、应用崩溃或异常重启。
- **网络风险**：NR 息屏降级功能会在息屏时切换网络模式，可能导致短暂的网络中断，影响后台下载或即时通讯。
- **数据风险**：如因模块导致系统无法启动，可能需要进入安全模式清除模块数据。

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任，包括但不限于设备损坏、数据丢失、电池损耗或保修失效。**

### 声明

- **Pixel** 是 Google LLC 的注册商标。
- **Android** 是 Google LLC 的注册商标。
- **Tensor** 是 Google LLC 的商标。
- **Material Design / Material 3** 是 Google LLC 的商标。

本项目与 Google LLC 没有任何关联、赞助或背书关系。本项目中对上述商标的使用仅用于标识兼容设备和技术规格，不暗示任何官方授权或合作关系。所有商标权利归其各自所有者所有。

### 开源许可

本项目按原样 (AS IS) 提供，不附带任何明示或暗示的保证。使用者自行承担使用风险。
