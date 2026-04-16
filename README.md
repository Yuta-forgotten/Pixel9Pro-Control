# Pixel 9 Pro Control Module v4.0.3

> APatch/KernelSU 模块 — Pixel 9 Pro (Tensor G4) 温控 + CPU 调度 + ZRAM 优化 + 待机功耗优化 + Material 3 WebUI

## 版本选择

| 版本 | 特点 | 适合 |
|------|------|------|
| **[v3.3.1](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/tag/v3.3.1)** | 安全加固 | 类玻璃态 UI / 稳定核心功能 |
| **[v4.0.3](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/tag/v4.0.3)** | Material 3 重构 + 深色模式 + 热区缓存 | 新 UI 和 bug |

两个版本的核心功能完全一致，v4 版本需要卸载v3版本后安装。

## 功能

### CPU 调度 (5 种模式，不与 Thermal HAL 冲突)

| 模式 | top-app | 小核 resp | 中核 resp | 大核 resp |
|------|---------|-----------|-----------|-----------|
| 游戏 | cpu0-7 全核 | 8ms | 8ms | 8ms |
| 平衡 | cpu4-7 | 200ms (锁820MHz) | 12ms | 8ms |
| 轻度 | cpu4-7 | 200ms (锁820MHz) | 20ms | 16ms |
| 省电 | cpu4-7 | 500ms (锁820MHz) | 40ms | 30ms |
| 默认 | cpu0-7 (系统默认) | 16ms | 64ms | 200ms |

通过 WebUI 切换。

### 温控优化
- 节流起始温度从出厂 39°C 提高到 **43°C**（模块默认 +4°C）
- 渐进式三级降温：42°C 轻度 → 45°C 中度 → 48°C 重度
- 安全阈值 (55°C/59°C) 保留不动
- WebUI 支持 +0/+2/+4/+6°C 四档调整，部分档位支持热重启

### ZRAM / 内存优化
- **算法**：lz77eh (Emerald Hill 硬件加速)，Tensor G4 内置固定功能压缩电路，CPU 零开销
  - 压缩率 29.5%，优于 lz4 的 38.1%
- **容量**：11392MB（默认 ~8GB / 50% RAM，模块扩展至 75% RAM）
- **VM 参数**：swappiness 150→100 · min_free_kbytes 27386→65536 · vfs_cache_pressure 100→60
- 开机后约 48 秒自动完成配置（swapoff → reset → swapon）

### 待机功耗优化
- 关闭 `mobile_data_always_on`（modem 休眠关键）
- 关闭 VoWiFi（停止 IWLAN 搜索注册唤醒 modem）
- WiFi multicast 息屏自动关闭
- 关闭 BLE/WiFi 后台扫描、自适应连接、网络推荐、附近共享
- 所有设置仅在开机时执行一次，可在系统设置中临时恢复

### WebUI 控制

端口 6210，`http://127.0.0.1:6210` 访问（仅绑定 127.0.0.1 回环）。

**v4.0.3 Material 3 Expressive + 深色模式**：
- 深色模式：跟随系统 / 浅色 / 深色 三选一，localStorage 持久化
- 热区数据走 5s 后台缓存，避免 busybox httpd 单线程被 dumpsys 阻塞
- 所有 fetch 请求 AbortController 8s 超时，轮询收敛（CPU 3s / thermal 8s / swap 30s）

**四个页面**：
- **状态**：模式 Hero + 实时温度/CPU 频率/ZRAM 摘要 + 设备信息 + 操作记录
- **性能**：实时 CPU 频率详情 + 5 种模式切换 + 参数详情按钮
- **温控**：实时机身温度 + 传感器矩阵 + 4 档节流切换
- **优化**：ZRAM/Swap 参数面板 + 8 项待机优化状态

### WebUI 安全 (v3.3.1 起)
- httpd 绑定 `127.0.0.1:6210`
- 启动时生成随机 token，所有写操作强制 `X-PIXEL9PRO-TOKEN` 头校验
- 写操作强制 `Content-Type: application/json`，触发 CORS preflight 阻断跨域 CSRF
- profile / set_thermal / swap 加服务端 mkdir 互斥锁，防并发写抖动
- v4.0.3 额外收紧 CSP `script-src 'self'`（去 unsafe-inline）

## 背景

Pixel 内核的 `sched_pixel` governor 通过 `freq_qos` 框架管理 CPU 频率。Thermal HAL 通过独立的 `freq_qos_request` 对象控制 `scaling_max_freq`，会覆盖任何用户空间的直接写入。

本模块的策略是**非对抗 Thermal HAL**，控制 Thermal HAL 不管理的参数：
- `cpuset` — 任务核心分配 (top-app / background)
- `response_time_ms` — governor 升频响应时间（Thermal HAL 和 Power HAL 均不碰此参数）

### 关于 foreground cpuset

`foreground` cpuset 由 Android 框架层在 OOM adj 重算时强制写回系统默认值 `0-6`，无法通过文件覆盖修改。小核 `response_time_ms=200ms` 大部分时候锁定 820MHz，调度器应该会优先选择响应更快的中核。

### 关于 down_rate_limit_us

`down_rate_limit_us` 是内核根据 `response_time_ms` 自动计算的只读派生值，不可独立写入。

## 安装

1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载 zip（v3.3.1 或 v4.0.3）
2. APatch / KernelSU → 模块 → 从存储安装
3. **整机重启**（service.sh 在 late_start 阶段执行，必须重启才能生效）
4. 打开 `http://127.0.0.1:6210` 验证 WebUI


## 兼容性

- **设备**：Pixel 9 Pro (caiman)
- **系统**：基于 **Android 17 Beta 3 (SDK 37)** 开发和测试。理论上 sched_pixel 和 thermal HAL 在 Android 15/16 上结构相同，但**未经实际验证**
- **Root**：APatch 0.10+ / KernelSU

## 已知问题与故障排除

### 卡二屏（卡在开机动画）

| 原因 | 说明 | 解决 |
|------|------|------|
| `thermal_info_config.json` 格式错误 | JSON 语法不合法，Thermal HAL 拒绝加载 | 安全模式删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动 | 脚本中的死循环阻塞 late_start | 同上 |
| 连续安装模块 (B06) | 短时间内多次 `apd module install`，OverlayFS 竞态导致 thermal-service 崩溃 → watchdog 循环 | 每次安装等 ≥30s 再操作 |
| 禁用温控模块后重启 (B08) | Android 17 Beta 3 的 thermal HAL 对 overlay mount 卸载敏感，见 `dmesg` 里 `"lazy service...unable to"` | 不要先禁用再装新版，直接覆盖安装 |

**紧急恢复**：长按电源键强制关机 → 开机进入第二屏时电源+音量下进安全模式 → 重启

### Chrome Beta 缓存 (B09)

Chrome Beta 对本地 `http://` 资源缓存激进，升级模块后可能仍看到旧 UI。验证方法：顶栏 kicker 显示 `Pixel 9 Pro · UI vX.Y.Z`，对不上就是缓存命中。

**绕过**：访问 `http://127.0.0.1:6210/?r=<随机数>`，或 Chrome 设置→网站设置→127.0.0.1→清除站点数据。

## 致谢与参考

- **Sun_Dream（酷安）** — cpuset 路由 + sched_pixel 调度思路（小核移出前台、response_time 控制升频）
- **[RMBD (Reduce Modem Battery Drain)](https://github.com/Ethan-Ming/Reduce_Modem_Battery-Drain)** — 待机功耗优化参考
- **[WZL203/Pixel-8-pro-thermal-SOC-Charging-control](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-control)** — Pixel thermal_info_config.json 温控配置参考

## 免责声明

修改温控参数可能导致设备过热。请在理解风险的情况下使用。作者不对因使用本模块造成的任何损害负责。
