# Pixel 9 Pro Control Module v4.1.0

> APatch/KernelSU 模块 — Pixel 9 Pro / Pro XL (Tensor G4) 温控 + CPU 调度 + ZRAM 优化 + 待机功耗优化 + Material 3 WebUI

## 版本选择

| 版本 | 特点 | 适合 |
|------|------|------|
| **[v3.3.1](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/tag/v3.3.1)** | 安全加固版 | 类玻璃态 UI / 稳定核心功能 |
| **[v4.1.0](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/tag/v4.1.0)** | Material 3 + 双机型 + NR 息屏降级 | Pro & Pro XL 全功能 |

两个版本的核心功能一致，v4 版本需要卸载 v3 版本后安装。

## 支持设备

| 设备 | 代号 | 状态 |
|------|------|------|
| Pixel 9 Pro | caiman | 完整支持 (主开发机型) |
| Pixel 9 Pro XL | komodo | 完整支持 (v4.1.0 起) |

安装时自动检测机型，刷入对应的温控配置。两个设备共享同一 SoC (Tensor G4)，所有功能均可用。

## 功能

### CPU 调度 (5 种模式)

| 模式 | top-app | 小核 resp | 中核 resp | 大核 resp |
|------|---------|-----------|-----------|-----------|
| 游戏 | cpu0-7 全核 | 8ms | 8ms | 8ms |
| 平衡 | cpu4-7 | 200ms (锁820MHz) | 12ms | 8ms |
| 轻度 | cpu4-7 | 200ms (锁820MHz) | 20ms | 16ms |
| 省电 | cpu4-7 | 500ms (锁820MHz) | 40ms | 30ms |
| 默认 | cpu0-7 (系统默认) | 16ms | 64ms | 200ms |

通过 WebUI 切换，不与 Thermal HAL 冲突。

### 温控优化 (4 档可调)

| 档位 | VIRTUAL-SKIN 起始节流 | 说明 |
|------|----------------------|------|
| 默认节流 | 39°C (原厂) | 恢复出厂阈值 |
| 轻度节流 | 41°C (+2°C) | 减少日常误触发 |
| 常规节流 | 43°C (+4°C) | **模块默认**，兼顾性能释放与温控 |
| 激进节流 | 45°C (+6°C) | 高负载短时冲刺 |

偏移覆盖 8 个 VIRTUAL-SKIN 节流传感器（VIRTUAL-SKIN / HINT / SOC / CPU-LIGHT-ODPM / CPU-MID / CPU-ODPM / CPU-HIGH / GPU），安全阈值 (55°C/59°C) 保留不动。切换后自动重启 thermal 服务，无需整机重启。

### ZRAM / 内存优化

- **算法**：lz77eh (Emerald Hill 硬件加速)，Tensor G4 内置固定功能压缩电路，CPU 零开销
- **容量**：11392MB（默认 ~8GB / 50% RAM，模块扩展至 75% RAM）
- **VM 参数**：swappiness 150→100 · min_free_kbytes 27386→65536 · vfs_cache_pressure 100→60

### 待机功耗优化 (保 5G)

- 关闭 `mobile_data_always_on`（不影响 5G/CA 能力，可能略增 WiFi→蜂窝回切时延）
- **不强制关闭 VoWiFi**（避免影响 Wi-Fi Calling / 室内通话连续性）
- WiFi multicast 息屏自动关闭
- 关闭 BLE/WiFi 后台扫描、自适应连接、网络推荐、附近共享
- 开机后延迟复写一次易被系统回弹的待机项
- 所有设置均以保留 5G / 5GA / 5G CA 能力为前提

### NR 息屏降级 (v4.0.5+)

- 息屏超过 60 秒后将网络模式从 5G NR 切换到 LTE，降低调制解调器射频功耗
- 亮屏时立即恢复 5G/NR 模式
- 恢复 NR 后冷却 10 分钟，避免频繁亮灭导致来回切换
- 开启热点时自动跳过降级，保障共享连接
- 默认关闭，通过 WebUI 手动开启

### NTP 服务器选择 (v4.0.5+)

支持在阿里云 / 华为云 / 小米 / Google 默认四个 NTP 服务器间切换，开机自动恢复用户选择。

### WebUI 控制

端口 6210，`http://127.0.0.1:6210` 访问（仅绑定 127.0.0.1 回环）。

- Material 3 Expressive + 深色模式（跟随系统 / 浅色 / 深色）
- 热区数据 5s 后台缓存，避免 busybox httpd 单线程被 dumpsys 阻塞
- 所有 fetch 请求 AbortController 8s 超时
- 顶栏滚动自动收起
- 下拉刷新 + 左右滑动切换页面

**四个页面**：
- **状态**：模式 Hero + 实时温度/CPU 频率/ZRAM 摘要 + 设备信息 + 操作记录
- **性能**：实时 CPU 频率详情 + 5 种模式切换
- **温控**：实时机身温度 + 传感器矩阵 + 4 档节流切换
- **优化**：ZRAM/Swap 参数 + 待机优化状态 + NR 息屏降级 + NTP 服务器

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

> **foreground cpuset**：由 Android 框架层在 OOM adj 重算时强制写回系统默认值 `0-6`，无法通过文件覆盖修改。小核 `response_time_ms=200ms` 大部分时候锁定 820MHz，调度器优先选择响应更快的中核。
>
> **down_rate_limit_us**：内核根据 `response_time_ms` 自动计算的只读派生值，不可独立写入。

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载 zip
2. APatch / KernelSU → 模块 → 从存储安装
3. 安装器自动检测机型 (Pro / Pro XL) 并刷入对应温控配置
4. **整机重启**
5. 打开 `http://127.0.0.1:6210` 验证 WebUI

## 兼容性

- **设备**：Pixel 9 Pro (caiman) / Pixel 9 Pro XL (komodo)
- **系统**：基于 **Android 17 Beta 3 (SDK 37)** 开发和测试
- **Root**：APatch 0.10+ / KernelSU

## 已知问题与故障排除

### 卡二屏（卡在开机动画）

| 原因 | 说明 | 解决 |
|------|------|------|
| `thermal_info_config.json` 格式错误 | JSON 语法不合法，Thermal HAL 拒绝加载 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动 | 脚本中的死循环阻塞 late_start | 同上 |
| 连续安装模块 | 短时间内多次 `apd module install`，OverlayFS 竞态 | 每次安装等 ≥30s 再操作 |
| 禁用温控模块后重启 | Android 17 Beta 的 thermal HAL 对 overlay mount 卸载敏感 | 不要先禁用再装新版，直接覆盖安装 |

**紧急恢复**：长按电源键强制关机 → 开机进入第二屏时电源+音量下进安全模式 → 重启

### Chrome 缓存

Chrome 对本地 `http://` 资源缓存激进。验证方法：顶栏 kicker 显示 `Pixel 9 Pro · UI vX.Y.Z`，版本号不对就是缓存命中。

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

### 商标声明

- **Pixel** 是 Google LLC 的注册商标。
- **Android** 是 Google LLC 的注册商标。
- **Tensor** 是 Google LLC 的商标。
- **Material Design / Material 3** 是 Google LLC 的商标。

本项目与 Google LLC 没有任何关联、赞助或背书关系。本项目中对上述商标的使用仅用于标识兼容设备和技术规格，不暗示任何官方授权或合作关系。所有商标权利归其各自所有者所有。

### 开源许可

本项目按原样 (AS IS) 提供，不附带任何明示或暗示的保证。使用者自行承担使用风险。
