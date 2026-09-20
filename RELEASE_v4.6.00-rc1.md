# v4.6.00-rc1 — 安全默认、双 SKU 与可审计候选版

## 发布级别

- 类型：`test / candidate / prerelease`
- module version：`v4.6.00-rc1`
- versionCode：`115`
- Git 基线起点：`1966613a1d12cb352d469e4ad693ddc6a72d9217`

## 主要变化

1. 温控默认 `system`，发布包不含 `thermal_info_config.json`；custom 只提供 `-2/+2/+4/+6°C`。
2. `scheduler_mode=off` 是硬门禁，不等同 default profile；CPU profile、auto、reconcile、repair、health mutation 和 owner worker 均停止写入。
3. 首装向导覆盖温控、调度、UECap、NR、SIM2、VM/ZRAM、NTP，并在摘要后最终确认。
4. caiman/komodo payload 全部位于模块私有 staging；ZIP 不预激活任何 canonical vendor target。
5. komodo 文件由用户提供：623788 bytes，SHA-256 `f2c0bc1dc1409b1780dbdf57e56ebfef15cf7f889e76315343d2ae139cb19090`，来源 build 未知，状态为 candidate。
6. VM/ZRAM 默认 system no-write；优化和 custom 必须显式选择。
7. 私有审计日志使用 0700/0600、256 KiB 轮转和边界脱敏；CGI 失败使用真实 HTTP 4xx/5xx。
8. 功耗导出包含 report、schema 1 JSON、功耗/温度 CSV、Top 归因 CSV 和逐文件 SHA-256。

## 本次候选修复

- Thermal custom 生成器对 `HotThreshold` 与下一档 `HotHysteresis` 使用严格 `<` 约束，并保留 `0.1°C` 安全间隔；修复等号边界触发 `ThermalHAL could not be initialized properly` 的启动失败。
- 实机取证曾在 caiman 升级迁移的 custom `+4°C` 配置上复现 ThermalHAL invalid-components；修复后的生产生成器对 pro/xl、`-2/0/+2/+4/+6` 全组合完成 JSON 与严格约束复核。
- caiman 实机 A/B 隔离证明 Control 与活动 MetaModule 组合时，post-mount 动态 bind `/vendor` 会触发卡第二屏；修复方案改为安装阶段写入 canonical target，重启后只做有效路径/hash 复读，并拒绝覆盖残留 content image。
- 若检测到旧 Control content image，安装器拒绝原地覆盖并要求 clean reinstall + reboot，避免旧 thermal/UECap 文件残留。
- APatch/KernelSU 安装前通过 `scripts/metamodule_compat.sh` 对已知 MetaModule hook 做版本/形状门禁；不匹配时拒绝安装，不把未知 context 行为带入启动链。
- 活动 MetaModule 下，WebUI 的 UECap 档位和自定义温控接口返回 `409 Conflict` 并要求重新安装；禁止把只写 metadata 目录的假成功状态带入下一次启动。
- MetaModule adapter 固定 `meta-overlayfs 1.3.1 / versionCode 13100` 的原始 hook hash，并在安装失败时恢复 hook；content 提交使用隔离目录、canonical `vendor_configs_file`/`vendor_fw_file` context、hash readback 和 `/vendor` lowerdir readback。
- 启动期不再同步等待 telephony registry 的 radio snapshot；UECap receipt 先提交 content 合同，radio 观察延后，避免 late_start 阻塞 WebUI。

## 构建证据

- 候选 ZIP：`pixel9pro_control_v4.6.00-rc1.zip`
- SHA-256：`ad17c757d807ce4fc4ee7cd3ac14433db6236d9c741e3e81270fbc68b5450f65`
- source fingerprint：`bcf528ad8aab521ab928c630b3c4205cddd2e969ebefe0be26f6cbbafcaf3840`
- entries：78
- uncompressed bytes：3544801
- 双次构建：一致
- payload devices：`caiman, komodo`
- 预激活 UECap target：0
- thermal overlay/stock entry：0

## 回滚

- 回滚 ZIP：`pixel9pro_control_v4.5.09_rollback.zip`
- SHA-256：`6a0342204990356dc97b23567aeb5b2ffeca5580c2e81d91ebf4de2ab2ea7adb`
- source fingerprint：`aabad08a65e014ac5691bb4419c82075d3597a233443a119cef03e7287c36904`
- 来源：Git commit `1966613`，使用当前确定性构建器重建；不是旧 Release 原文件。

## 已验证

- Shell/Node/Python parser 与源码合同。
- caiman (Pixel 9 Pro) APatch + `meta-overlayfs 1.3.1` stage4 实机启动：`sys.boot_completed=1`，`/system`/`/vendor` KSU overlay 存在，Control/Meta 无 disable/remove。
- 实机 effective thermal 为 stock hash `1cbfbe13aa6e4a498b79b741039a964e28aebb12cbb0d65b8e772cbfaeeb1111`、`vendor_configs_file`，Meta content 无 thermal 文件；Thermal AIDL `Ready=true`，无新 thermal AVC/SIGABRT。
- 实机 UECap balanced 的 source/content/effective hash 均为 `2870ba9c94145930ad75f1666c6ec2755ac207a7efc0aa4277bdde13cabaae0c`，content/effective 均为 `vendor_fw_file`；新 readback helper 返回 `verified`，JSON receipt 输出 `backend/content_hash/effective_hash/context`。
- 安装日志无 `chcon: invalid context`；WebUI `127.0.0.1:6210` HTTP 200，热控服务 `HAL Ready=true`。
- system/custom 温控事务与缺失 stock fail-closed。
- scheduler capability、off 五层门禁和 WebUI 交互。
- caiman/komodo 跨 SKU 拒绝及 candidate→stock 回滚。
- VM system/disabled no-write 分支。
- 日志脱敏、轮转、HTTP error contract。
- 功耗导出 schema、原子目录、Top 归因和逐文件 hash。
- 375/768/1280px WebUI 关键状态，无横向溢出。
- 确定性双构建和完整 ZIP 元数据审计。

## 未验证

- `[unverified]` PRO XL 实机安装。
- `[unverified]` PRO XL candidate modem load/readback。
- `[unverified]` PRO XL 重启持久化、IMS/VoLTE/VoNR 与 stock rollback。
- `[unverified]` KernelSU/APatch MetaModule 在 komodo 的有效 `/vendor` readback。
- `[unverified]` Android SELinux 下日志权限、长周期轮转和 `/sdcard/Download` 导出。

本版本不得创建稳定 tag、稳定 GitHub Release 或稳定版资产。
