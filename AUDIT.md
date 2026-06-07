# Pixel 9 Pro Control 模块审计入口

**状态**：轻量入口
**最后更新**：2026-06-08
**完整审计报告**：`../docs/50_审查复盘/2026-06-08_Pixel9Pro-Control模块完整审计报告.md`

模块仓库根部只保留代码邻近审计入口，不再承载长期项目知识正文。长期审计结论、风险分级、验证建议、Uperf 共存边界、WebUI 安全边界统一维护在根级 `docs/`。

## 当前结论摘要

- v4.4.8 已修复 `info.sh` GET 暴露 WebUI token、external 无 Uperf 时旧高 boost 残留、Android 17 热点桥接接口漏判、`.profile_history` 旧 9 列记录缺少 `sched_owner` 口径等问题。
- `Uperf Game Turbo / 外部调度接管` 的正确边界是 `.cpu_sched_owner=external` 后，本模块停止写 CPU 调度节点；温控、ZRAM、NR、SIM2、后台限制、NTP、UECap 等能力仍由本模块负责。
- WebUI 安全边界是 `127.0.0.1:6210 + token + JSON POST`。已拥有 root 或能读取 `/data/adb/modules/pixel9pro_control/.webui_token` 的进程不在 WebUI token 防护边界内。
- UECap bind mount、modem restart、thermal service 在线重启仍属于设备敏感操作；每次 Android 大版本或 root 框架变化后应重做实机验证。

## 写回规则

- 新的长期审计报告写入根级 `../docs/50_审查复盘/`。
- 稳定设计规则写入 `../docs/20_专题知识/` 或 `../docs/30_技术参考/`。
- 缺陷状态写入 `../bugs.yaml`。
- 原始证据写入 `../logs/`，并在 `../docs/01_索引/日志索引.md` 建立映射。
