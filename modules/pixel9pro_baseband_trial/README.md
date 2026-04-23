# Pixel 9 Pro Baseband Trial

独立基带配置模块，负责：

- `persist.dbg.volte_avail_ovr=1`（VoLTE）
- `persist.dbg.wfc_avail_ovr=1`（Wi-Fi Calling）
- CarrierSettings（3210 个运营商配置）
- China MCFG overlay（移动/联通/电信/广电）

不负责：

- UECap binarypb 管理（由 `pixel9pro_control` 模块负责）
- 温控 / CPU 调度 / ZRAM / WebUI

## 与 pixel9pro_control 的关系

- 两个模块**路径不冲突**，可同时安装
- 本模块：OverlayFS 覆盖 `/product/etc/CarrierSettings/` 和 `/vendor/rfs/.../mcfg_sw/`
- 控制模块：bind mount 覆盖 `/vendor/firmware/uecapconfig/`
- 控制模块 WebUI 可检测本模块状态并展示

## 安装

- APatch: `apd module install /sdcard/Download/pixel9pro_baseband_trial_v1.0.1.zip`
- KSU: 需预装 metamodule（meta-overlayfs / Hybrid Mount）
- v1.0.1 起安装脚本会检测常见 metamodule；未检测到时会在刷入阶段直接给出明确告警

## 不要叠刷

- `5G+Pixel56789TenVoLteVo5G-Global.zip`
- `pixel_uecap_special_apatch_magisk_2026.04.03.zip`
