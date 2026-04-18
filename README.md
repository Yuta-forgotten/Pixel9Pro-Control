# Pixel 9 Pro Control Module v4.2.3

> APatch / KernelSU 模块。目标设备为 Pixel 9 Pro / Pro XL (Tensor G4)。包含温控偏移、CPU 调度模式、ZRAM 参数、待机设置和本地 WebUI。

## 当前版本

- Release: `v4.2.3`
- Asset: `pixel9pro_control_v4.2.3.zip`
- Module id: `pixel9pro_control`
- WebUI: `http://127.0.0.1:6210`

## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | APatch 实机验证 |
| Pixel 9 Pro XL | komodo | 机型分支已适配；未完成本项目实机复核 |

安装时自动检测机型，刷入对应的温控配置。

## 功能

### CPU 调度 (5 种模式)

| 模式 | top-app | 小核策略 | 小核 resp | 中核 resp | 大核 resp |
|------|---------|----------|-----------|-----------|-----------|
| 游戏 | cpu0-7 | 不锁最低频 | 8ms | 8ms | 8ms |
| 平衡 | cpu4-7 | 最低频 820MHz | 200ms | 12ms | 8ms |
| 轻度 | cpu4-7 | 最低频 820MHz | 200ms | 20ms | 16ms |
| 省电 | cpu4-7 | 最低频 820MHz | 500ms | 40ms | 30ms |
| 默认 | cpu0-7 | 系统默认 | 16ms | 64ms | 200ms |

调度通过 `cpuset` 和 `sched_pixel response_time_ms` 控制；不直接写 `scaling_max_freq`。

### 温控优化 (4 档可调)

| 档位 | Offset | VIRTUAL-SKIN 首档 | 说明 |
|------|--------|-------------------|------|
| 默认节流 | +0°C | 39°C | 原厂阈值 |
| 轻度节流 | +2°C | 41°C | 全档整体 +2°C |
| 常规节流 | +4°C | 43°C | 安装默认值 |
| 激进节流 | +6°C | 45°C | 全档整体 +6°C |

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

### 待机设置

- `mobile_data_always_on=0`
- `wifi_scan_always_enabled=0`
- `ble_scan_always_enabled=0`
- `adaptive_connectivity_enabled=0`
- `adaptive_connectivity_wifi_enabled=0`
- `network_recommendations_enabled=0`
- `nearby_sharing_enabled=0`
- `nearby_sharing_slice_enabled=0`
- Wi-Fi multicast: 亮屏开启，息屏关闭
- `wfc_ims_enabled`: 不托管

以上设置不以关闭 5G/5GA/CA 为前提。

### NR 息屏降级 (v4.0.5+)

- 息屏超过 `60` 秒后将网络模式切换到 LTE
- 亮屏时恢复保存的 NR 模式
- 恢复后冷却时间：`600` 秒
- 热点开启时跳过切换
- 默认状态：关闭

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
- 热区数据后台缓存：亮屏 `5s`，息屏 `60s`
- fetch 超时：`8s`
- 下拉刷新
- 左右滑动切换页面


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

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载发行包 `pixel9pro_control_v4.2.3.zip`
2. **不要**使用 GitHub 自动生成的 `Source code (zip)`，也不要自己把上层目录再压一层；安装器要求 ZIP 根目录直接包含 `module.prop`
3. 如果使用 **KernelSU** 且需要 `system/vendor` 覆盖（本模块的温控 JSON 属于此类），先安装 metamodule，例如 `meta-overlayfs` 或 `Hybrid Mount`，然后重启一次
4. APatch / KernelSU → 模块 → 从存储安装
5. 安装器自动检测机型 (Pro / Pro XL) 并刷入对应温控配置
6. **整机重启**
7. 打开 `http://127.0.0.1:6210` 验证 WebUI

## 兼容性

- 设备：
  - `Pixel 9 Pro (caiman)`
  - `Pixel 9 Pro XL (komodo)`
- 系统：`Android 17 Beta 3 (SDK 37)` 为当前开发与验证基线
- Root：
  - `APatch 0.10+`：已完成本项目实机验证
  - `KernelSU 0.9+`：代码路径已兼容；`system/vendor` 覆盖需预装 metamodule；未完成 KSU 真机闭环验证

## 已知问题与故障排除

### 安装器报 `Error: specified file not found in archive`

该错误通常表示安装器在 ZIP 根目录找不到需要提取的入口文件。

常见原因：
- 选错了文件：用了 GitHub 的 `Source code (zip)`，它会多包一层顶级目录
- 自己手动压缩时把 `pixel9pro_control_v2/` 整个目录包进去了，导致 `module.prop`/`customize.sh` 不在 ZIP 根目录
- 某些 KSU/APatch 分支管理器仍会优先找 `META-INF/com/google/android/update-binary`

`v4.2.3` 发行包同时提供：
- 原生 root-module 布局（ZIP 根目录直接放 `module.prop` / `customize.sh` / `service.sh`）
- Magisk 兼容 `META-INF` 入口

如果你仍看到这个错误，先确认安装的确实是发布页资产 `pixel9pro_control_v4.2.3.zip`，而不是源码压缩包。

### 卡二屏（卡在开机动画）

| 原因 | 说明 | 解决 |
|------|------|------|
| `thermal_info_config.json` 格式错误 | JSON 语法不合法，Thermal HAL 拒绝加载 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动 | 脚本中的死循环阻塞 late_start | 同上 |
| 连续安装模块 | 短时间内多次 `apd module install`，OverlayFS 竞态 | 每次安装等 ≥30s 再操作 |
| 禁用温控模块后重启 | Android 17 Beta 的 thermal HAL 对 overlay mount 卸载敏感 | 不要先禁用再装新版，直接覆盖安装 |

**紧急恢复**：长按电源键强制关机 → 开机进入第二屏时电源+音量下进安全模式 → 重启

### Chrome 缓存

Chrome 对本地 `http://` 资源缓存较强。验证方法：顶栏 kicker 显示 `Pixel 9 Pro · UI vX.Y.Z`，版本号不对就是缓存命中。

**绕过**：访问 `http://127.0.0.1:6210/?r=<随机数>`，或 Chrome 设置→网站设置→127.0.0.1→清除站点数据。

## 致谢与参考

- **Sun_Dream（酷安）** — cpuset 路由 + sched_pixel 调度思路
- **[RMBD (Reduce Modem Battery Drain)](https://github.com/Yuta-Ming/Reduce_Modem_Battery-Drain)** — 待机功耗优化参考
- **[WZL203/Pixel-8-pro-thermal-SOC-Charging-control](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-control)** — Pixel thermal_info_config.json 温控配置参考

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
