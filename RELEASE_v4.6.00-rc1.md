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

## 构建证据

- 候选 ZIP：`pixel9pro_control_v4.6.00-rc1.zip`
- SHA-256：`73c4c3734cb8efd5bfaa85965e4aa92772ade500b5b75391651546b2663957d0`
- source fingerprint：`e4361221848a92e82fe8eb00e021e588b965c8974f12229f7cfbabaaa7683fa5`
- entries：77
- uncompressed bytes：3507059
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
