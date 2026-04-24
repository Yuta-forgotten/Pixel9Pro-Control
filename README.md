# Pixel 9 Pro Control Module v4.3.15

> APatch / KernelSU 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、CPU 调度、ZRAM、待机优化和 UE 网络能力控制模块。

## 当前版本

- Release: `v4.3.15`
- versionCode: `50`
- Asset: `pixel9pro_control_v4.3.15.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`


## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 机型分支已适配；未实际测试 |

安装时自动检测机型，刷入对应的温控配置。
基带配置仅限 Pixel 9 Pro。

## 功能

### CPU 调度 (5 种模式)

| 模式 | top-app | 小核策略 | 小核 resp | 中核 resp | 大核 resp |
|------|---------|----------|-----------|-----------|-----------|
| 游戏 | cpu0-7 | 不锁最低频 | 8ms | 8ms | 12ms |
| 平衡 | cpu0-7 | 允许低频浮动 | 16ms | 40ms | 160ms |
| 轻度 | cpu0-6 | 长亮屏低温优先 | 24ms | 64ms | 200ms |
| 省电 | cpu0-6 | 更保守低频浮动 | 32ms | 96ms | 200ms |
| 默认 | cpu0-7 | 系统默认 | 16ms | 64ms | 200ms |

- 调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`
- `light` / `battery` 不再沿用旧版 `top-app → 4-7 + 小核锁 820MHz` 路线，改为让小核承担 steady-state 前台杂务，并让 X4 慢介入或不介入
- 游戏模式未测试

### 前台自动调度 (实验)

- 模式：`manual` / `auto`
- `manual`：固定使用当前选中的 profile
- `auto`：只在亮屏前台做**慢切换收口**
  - steady-screen 候选前台先保持 `balanced`
  - 同一长亮屏场景持续约 `45s` 后切到 `light`
  - `VIRTUAL-SKIN >= 40.8°C` 持续约 `90s` 后压到 `battery`
  - `battery` 状态下温度回落到 `40.4°C` 以下持续约 `60s` 后恢复 `light`
  - 息屏或退出 steady-screen 超过约 `30s` 后回到 `balanced`

- 自动模式只在 `balanced / light / battery` 三档之间收口，不会自动进入 `game / stock`
- steady-screen 候选只做低频、保守的用户空间近似识别，不把包名白名单当成通用负载分类器

### 温控优化 (4 档可调)

| 档位 | Offset | VIRTUAL-SKIN 首档 | 说明 |
|------|--------|-------------------|------|
| 出厂阈值 | +0°C | 39°C | 原厂阈值 |
| 轻度放宽 | +2°C | 41°C | 全档整体 +2°C |
| 日常推荐 | +4°C | 43°C | 安装默认值 |
| 性能优先 | +6°C | 45°C | 全档整体 +6°C |

偏移覆盖 8 个 VIRTUAL-SKIN 相关传感器。安全阈值 `55°C / 59°C` 保留不变。

### ZRAM / 内存优化

- 算法：`lz77eh`（Emerald Hill 硬件加速）
- 容量：`11392MB`
- VM 参数：`swappiness=100`、`min_free_kbytes=65536`、`vfs_cache_pressure=60`

### 待机与 modem 策略

保留 `5G / 5GA / CA / IMS` 能力，通过使用层优化降低功耗：

| 设置项 | 值 | 说明 |
|--------|-----|------|
| `adaptive_connectivity_enabled` | `1` | Google 官方 5G 节电：app 不需要高速时自动 NR→LTE |
| `network_recommendations_enabled` | `1` | 系统网络建议 |
| `mobile_data_always_on` | `0` | Wi-Fi 下不保持蜂窝常驻 |
| `wifi_scan_always_enabled` | `0` | 关闭 Wi-Fi 后台常扫 |
| `ble_scan_always_enabled` | `0` | 关闭 BLE 后台常扫 |
| `nearby_sharing_enabled` | `0` | 关闭 Nearby Sharing |

- Wi-Fi multicast：亮屏开启，息屏关闭
- SIM2 空槽：副卡槽为空时通过 `cmd phone radio power` 关闭 slot 1 radio 和 IMS，插卡后自动恢复

### NR 息屏降级

- 息屏超过 60 秒后将网络模式切换到 LTE
- 亮屏时恢复保存的 NR 模式
- 热点开启时跳过切换

### Doze 友好后台

v4.3.0 将原 4 个独立后台循环合并为 1 个统一工作循环：

| 状态 | sleep 间隔 | dumpsys 调用频率 |
|------|-----------|-----------------|
| 亮屏 | 15s | ~4次/min |
| 息屏首次 | 60s | ~1次/min |
| 息屏后续 | 600s | ~0.1次/min |
| 温度突发 | 5s | ~12次/min (用户触发, 5 分钟) |

### UE 网络能力 / UECap 切换

UECap 告诉基站"手机支持哪些载波组合"。**不直接影响功耗**——功耗取决于信号强度和 modem 活跃时间。

| 配置 | 内部模式 | 说明 | 相对原厂 |
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

可选：`ntp.aliyun.com`（默认）、`ntp.myhuaweicloud.com`、`ntp1.xiaomi.com`、`time.android.com`

### WebUI

端口 6210，`http://127.0.0.1:6210`（仅绑定 127.0.0.1 回环）。

- 4 个 Tab：状态总览、性能调度、温控阈值、连接与优化
- 主题：system / light / dark
- 性能页支持 `手动 / 自动` 调度策略切换，并显示当前自动切换原因
- 轮询按当前 tab 收口，用户闲置 45s 自动降频
- 温度历史窗口：10分钟 / 30分钟 / 2.5h / 12h
- 功耗详情区分"当前放电会话 / 今日累计 / batterystats 窗口"
- 安全：启动时随机 token、CSP `script-src 'self'`、写操作强制 JSON + CORS preflight

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载 `pixel9pro_control.zip` 最新版
2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
3. APatch / KernelSU → 模块 → 从存储安装
4. **首次安装**：音量键交互向导，可选择温控偏移、CPU 调度、UECap 档位、NR 降级、NTP
5. **升级安装**：自动迁移已有设置，无需重新配置
6. 重启
7. 打开 `http://127.0.0.1:6210` 验证

## 兼容性

- `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
- `Android 17 QPR1 Beta 1 (SDK 37)` 当前验证基线
- `APatch 0.10+` 实机验证
- `KernelSU 0.9+` 代码兼容（需 metamodule，未完成真机闭环）

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
- **[RMBD](https://github.com/Yuta-Ming/Reduce_Modem_Battery-Drain)** — 待机功耗优化参考
- **[WZL203](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-control)** — Pixel thermal_info_config.json 参考

## 免责声明

本模块通过修改温控阈值、CPU 调度参数、ZRAM 配置和系统设置来改变设备行为。**使用本模块可能带来以下风险**：

- **过热风险**：提高温控节流阈值会延迟系统降温介入
- **稳定性风险**：修改 CPU 调度参数可能导致系统不稳定
- **网络风险**：NR 息屏降级会在息屏时切换网络模式

**用户应在充分理解上述风险的前提下自行决定是否安装和使用本模块。作者不对因使用本模块造成的任何直接或间接损害承担责任。**

- **Pixel**、**Android**、**Tensor**、**Material Design** 是 Google LLC 的商标。本项目与 Google LLC 无任何关联。
