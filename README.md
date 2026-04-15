# Pixel 9 Pro Control Module v3.3.0

> APatch/KernelSU 模块 — Pixel 9 Pro (Tensor G4) 温控 + CPU 调度 + ZRAM 优化 + 待机功耗优化

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

### WebUI 控制 (v3.3)
- 端口 6210，`http://127.0.0.1:6210` 访问
- **状态页**：当前模式 Hero 卡（含温控档位 · VM 状态）+ 实时温度/CPU 频率条/ZRAM 摘要 + 设备信息 + 操作记录
- **性能页**：实时 CPU 频率详情 + 模式切换
- **温控页**：实时机身温度 + 传感器矩阵 + 节流档位切换
- **优化页**：ZRAM/Swap 参数面板 + 功耗优化状态

## 背景

Pixel 内核的 `sched_pixel` governor 通过 `freq_qos` 框架管理 CPU 频率。Thermal HAL 通过独立的 `freq_qos_request` 对象控制 `scaling_max_freq`，会覆盖任何用户空间的直接写入。

本模块的策略是**非对抗 Thermal HAL**，控制 Thermal HAL 不管理的参数：
- `cpuset` — 任务核心分配 (top-app / background)
- `response_time_ms` — governor 升频响应时间（Thermal HAL 和 Power HAL 均不碰此参数）

### 关于 foreground cpuset

`foreground` cpuset 由 Android 框架层在 OOM adj 重算时强制写回系统默认值 `0-6`，无法通过文件覆盖修改。小核 `response_time_ms=200ms` 大部分时候锁定 820MHz，调度器应该会优先选择响应更快的中核

### 关于 down_rate_limit_us

`down_rate_limit_us` 是内核根据 `response_time_ms` 自动计算的只读派生值，不可独立写入。

## 安装

1. 下载 ZIP
2. APatch / KernelSU → 模块 → 从存储安装
3. 重启

## 兼容性

- **设备**：Pixel 9 Pro (caiman)
- **系统**：基于 **Android 17 Beta 3 (SDK 37)** 开发和测试。理论上 sched_pixel 和 thermal HAL 在 Android 15/16 上结构相同，但**未经实际验证**
- **Root**：APatch 0.10+ / KernelSU

## 已知问题与故障排除

### 卡二屏（卡在开机动画）

| 原因                              | 说明                                                                            | 解决                                                         |
| ------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `thermal_info_config.json` 格式错误 | JSON 语法不合法，Thermal HAL 拒绝加载导致系统服务崩溃循环                                         | 进入安全模式或 Recovery 删除 `/data/adb/modules/pixel9pro_control/` |
| `service.sh` 阻塞启动               | 脚本中的死循环在 `late_start` 阶段阻塞系统初始化                                               | 同上                                                         |
| 连续安装模块                          | 短时间内多次 `apd module install` 引发 OverlayFS 竞态，thermal-service 崩溃 → watchdog 死循环 | 每次安装后等待完整重启再操作                                             |

**紧急恢复**：长按电源键强制关机 → 开机进入第二屏时电源+音量下进安全模式 → 重启

## 致谢与参考

- **Sun_Dream（酷安）** — cpuset 路由 + sched_pixel 调度思路（小核移出前台、response_time 控制升频）
- **[RMBD (Reduce Modem Battery Drain)](https://github.com/Ethan-Ming/Reduce_Modem_Battery-Drain)**
- **[WZL203/Pixel-8-pro-thermal-SOC-Charging-control](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-controlnl)** — Pixel thermal_info_config.json 温控配置参考

## 免责声明

修改温控参数可能导致设备过热。请在理解风险的情况下使用。作者不对因使用本模块造成的任何损害负责。
