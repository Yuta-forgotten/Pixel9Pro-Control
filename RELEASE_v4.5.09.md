# v4.5.09 — mmd ZRAM 容量请求与 VM 手动调节修复

## 用户可见变化

- WebUI 可提交 `persist.vendor.zram_swap_size_v2` 的 bytes/百分比请求；返回 `pending_reboot`，由 mmd 在下一次开机应用，不在线 reset zram。
- 容量输入采用移动端 Disclosure + 有界 number 控件；范围、步进和当前请求由后端 contract 动态注入，不在 HTML 中硬编码。
- WebUI 显示 ZRAM 实际容量、开机请求值、owner、active swap 和 `SwapTotal`；sysfs 有值但 swap 未注册时显示“异常：未启用”。
- VM 手动调节真实支持四个 sysctl，并执行范围校验、权威 readback、custom 持久化和失败回滚。
- 修复 mmd-owned ZRAM 被模块重复 reset/resize 导致 swap 归零的问题。

## 当前 Build 证据

- caiman / `CP41.260814.003.B1`：mmd 读取 `persist.vendor.zram_swap_size_v2`。
- 受控实验请求 `11945377792` 后重启，实际 `disksize=11945377792`、`SwapTotal=11665404 kB`，连续采样稳定。
