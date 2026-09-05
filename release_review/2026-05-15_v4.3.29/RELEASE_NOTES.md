# v4.3.29 Release Notes — 待审阅草案

> 当前状态：GitHub Release v4.3.29 已转 **Draft**，tag 已在远端（指向 commit `516713a`）。
> Latest 仍是 v4.3.27。待小宝审阅本文 + README 草案后再 publish。
>
> 修改命令：`gh release edit v4.3.29 --notes "$(cat <新文件>)"`
> 发布命令：`gh release edit v4.3.29 --draft=false`

---

## 新增 — Magisk 适配


### 根因

`/vendor/firmware/uecapconfig/*.binarypb` 被 Pixel modem `vendor.cbd` 在 init 早期 `mmap()` 加载，而 Magisk 的 **Magic Mount** 在 `post-fs-data` 阶段才接管，两者存在 inode race → cbd crash loop → 卡 boot。


### 适配方案

| Root 实现 | 行为 |
|---|---|
| **APatch** | 完整功能（含 UECap 三档基带切换） |
| **KernelSU + metamodule** | 完整功能（含 UECap 三档基带切换） |
| **Magisk** | 安装时自动剔除 `system/vendor/firmware/uecapconfig/` 与 UECap 切换逻辑，规避 race。其他功能（温控/调度/L1-L3 功耗/SIM2/NR 降级/WebUI）未修改 |


### 完整变更

- `customize.sh`：检测到 `ROOT_IMPL=Magisk` 时自动删除基带 binarypb + 跳过 UE 三档菜单 + 强制 `.uecap_policy=disabled`
- `webroot/cgi-bin/uecap.sh` / `check_baseband.sh`：CGI 开头自检 disabled 状态，返回 stub JSON
- `module.prop`：v4.3.28 → v4.3.29，versionCode 62 → 63



### 安装
root manager (APatch / KernelSU / Magisk) 刷入 `pixel9pro_control_v4.3.29.zip` 即可。首次安装会用音量键交互选择温控偏移 / CPU 调度 / NTP / NR 息屏降级；升级会自动迁移已有配置。


