# Pixel 9 Pro Control v4.4.8

## 更新

- 新增 Uperf Game Turbo 协同模式：安装向导与 WebUI 可检测已安装的 UGT，并选择由本模块接管 CPU 调度，或选择 `external` 将 CPU scene / 游戏调度交给 UGT。
- `external` 模式仅让出 CPU 调度：本模块停止周期性写入 `sched_pixel response_time_ms`、`sched_util_clamp_min`、`/dev/cpuset/*/cpus` 和 `/proc/vendor_sched/ug_bg_*`，温控、ZRAM、NR/SIM2、UECap 与 WebUI 继续保留。
- CPU 调度模型调整：`performance` 替代旧 `responsive`，使用 `12/20/80` 响应曲线并将 `sched_util_clamp_min` 还原到 `1024`，作为手动性能档，不参与自动策略。
- WebUI 性能页显示 UGT 探测状态、当前调度接管方和对应操作按钮；选择 `external` 后 profile/auto/enforce 写入会暂停。
- 修复温度历史弹窗只加载一次的问题：打开后每 10 秒静默刷新，关闭、返回或切换详情时自动清理刷新器。
- 优化实时温度读取：优先解析 `thermalservice` 的 HAL 当前温度，缓存过期后强制重建，减少旧缓存导致的显示偏差。

## 使用建议

- 已安装 Uperf Game Turbo：建议选择“不覆盖 Uperf / external”，让 UGT 负责 CPU scene、触控、前台和游戏调度，本模块负责温控、ZRAM、NR/SIM2、UECap 与 WebUI。
- 未安装 UGT：可继续使用本模块内置 Pixel 原厂调度方案；日常建议 `balanced`，长时间亮屏或热平台使用 `battery`，`performance` 仅建议手动短时使用。
- Magisk 用户仍需注意：基带 UE/UECap 切换不可用；APatch / KSU 环境下可用。
