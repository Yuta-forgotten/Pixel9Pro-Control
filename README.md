# Pixel 9 Pro Control Module v3.2.0

> APatch/KernelSU 模块 — Pixel 9 Pro (Tensor G4) 温控 + CPU 调度 + 待机功耗优化

## 功能

### CPU 调度 (不与 Thermal HAL 冲突)
- **cpuset 路由**: 前台 App (top-app) 用中+大核 (cpu4-7)，小核 (cpu0-3) 跑后台
- **小核锁最低频**: 通过 `response_time_ms=200ms` 将小核压在 820MHz，后台轻任务无需高频
- **sched_pixel 参数调优**: 通过 `response_time_ms` / `down_rate_limit_us` 控制升降频，不写 `scaling_max/min_freq`
- 四种模式: game / balanced / battery / stock，通过 WebUI 切换

### 温控优化
- CPU 降频起始温度从默认 37°C 提高到 **42°C**
- 渐进式降频：42°C 轻度 → 45°C 中度 → 48°C 重度
- 安全阈值 (56°C/59°C) 保留不动
- WebUI 支持 +0/+2/+4/+6°C 档位微调

### 待机优化
- 自动关闭 `mobile_data_always_on` (modem 休眠关键)
- 关闭 VoWiFi (停止 IWLAN 搜索注册唤醒 modem)
- WiFi multicast 息屏自动关闭
- 关闭 BLE/WiFi 后台扫描、自适应连接、网络推荐、附近共享
- 所有设置仅在开机时执行一次，可在系统设置中临时恢复

### WebUI 控制台
- 端口 6210，通过 `http://127.0.0.1:6210` 访问
- 支持 APatch WebView 内打开
- 伪实时 CPU 频率/温度监控 + 功耗优化状态面板
- CPU 档位 + 温控档位在线切换
- 支持左右滑动切换页面

## 背景

Pixel 内核的 `sched_pixel` governor 通过 `freq_qos` 框架管理 CPU 频率。Thermal HAL 通过独立的 `freq_qos_request` 对象控制 `scaling_max_freq`，会覆盖任何用户空间的直接写入。

本模块的策略是**非对抗 Thermal HAL**，而是控制 Thermal HAL 不管理的参数：
- `cpuset` — 任务核心分配
- `response_time_ms` — governor 升频响应时间（Thermal HAL 不碰此参数）
- `down_rate_limit_us` — governor 降频速率

## 安装

1. 下载 ZIP
2. APatch / KernelSU → 模块 → 从存储安装
3. 重启

## 兼容性

- **设备**: Pixel 9 Pro (caiman)
- **系统**: 基于 **Android 17 Beta 3 (SDK 37)** 开发和测试。理论上 sched_pixel 和 thermal HAL 在 Android 15/16 上结构相同，但**未经实际验证**。如果你在其他 Android 版本上使用，请自行测试温控和调度是否正常
- **Root**: APatch 0.10+ / KernelSU

## 致谢与参考

- **Sun_Dream（酷安）** — cpuset 路由 + sched_pixel 调度思路（小核移出前台、response_time 控制升频）
- **[RMBD (Reduce Modem Battery Drain)](https://github.com/Ethan-Ming/Reduce_Modem_Battery-Drain)**
- **[Mori不是魔力](https://space.bilibili.com/)** — Pixel 插卡续航优化
- **[WZL203/Pixel-8-pro-thermal-SOC-Charging-control](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-controlnl)** — Pixel thermal_info_config.json 温控配置参考


## 免责声明

修改温控参数可能导致设备过热。请在理解风险的情况下使用。作者不对因使用本模块造成的任何损害负责。
