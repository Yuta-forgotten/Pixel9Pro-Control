# Release Notes:v4.3.21


## 温控基线修正

修正各档位实际介入温度（以最早介入的 HINT 为准）：

| 档位 | 偏移 | HINT 介入 | VIRTUAL-SKIN 介入 |
|------|------|----------|------------------|
| 出厂阈值 | +0°C | 37°C | 39°C |
| 轻度放宽 | +2°C | 39°C | 41°C |
| 日常推荐 | +4°C | 41°C | 43°C |
| 性能优先 | +6°C | 43°C | 45°C |

HotHysteresis 同步修正为 proto 值 (1.9/1.4，原为 2.0/1.5)。

## Kernel Suspend 后台 (v4.3.18)

service.sh 后台 worker 重构，消除模块自身对 kernel suspend 的设计性阻碍：

- 探屏方式从 `dumpsys display`（IPC 唤醒 system_server）改为 sysfs 直读 `/sys/class/drm/card0-DSI-1/dpms`
- NR 降级延迟从 60s 改为 300s，减少短亮屏（口袋误触 / glance）触发的 NR↔LTE 切换和 RIL re-init
- LTE 状态轮询从 60 次/h 降到 12 次/h，给 kernel 真正的 deep suspend 窗口
- 新增 `.standby_diag_state` 低噪声诊断摘要，记录 worker 当前分支、下次唤醒时间、NR/调度状态

## SIM2 空槽管理 (v4.3.16)

- SIM2 自动管理默认关闭，WebUI 新增显式开关
- 关闭时若模块此前已 power down slot 1 radio/IMS，立即恢复到未管理基线

## 待机隔离模式 (v4.3.17)

- 新增 `.idle_isolate_mode` 开关 + WebUI "待机隔离模式"卡片
- 开启后息屏阶段暂停 NR 降级、SIM2 管理、功耗采样、thermal burst、自动调度
- 用于过夜 A/B 排障：隔离"是否为 control 模块阻碍 deep sleep"

## NR 降级修复 ( v4.3.21)

- v4.3.20: 修复 adaptive sleep bug — 等待期间 worker 从 600s 长 sleep 改为 60s，确保 5 分钟后正确触发降级
- v4.3.21: 修复 tethering 误判根因 — `wlan1` (bcmdhd P2P 虚拟接口，Wi-Fi 开启时 state=DOWN) 被误判为热点接口，导致 `_tether=1` 永久阻止降级。修复：只检测 `swlan0/ap0/softap0/rndis0/ncm0` 且 `operstate=up`


## EAS 调度修正 (v4.3.20)

- `sched_util_clamp_min=0`：stock 默认 1024 向 EAS 发送虚假 100% 利用率信号，修正后 EAS 可正确评估任务负载

## awk 多行格式支持 (v4.3.21)

- `set_thermal.sh` 和 `customize.sh` 的 awk 偏移脚本新增多行 HotThreshold 数组支持（此前仅处理单行格式）

## 升级说明

- 从 v4.3.15 升级：APatch/KernelSU 刷入后重启，已有设置自动迁移
