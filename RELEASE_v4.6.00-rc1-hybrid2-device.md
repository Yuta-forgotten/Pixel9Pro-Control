# v4.6.00-rc1-hybrid2-device — 设备验收候选包

## 唯一发行警告

**此版本的温度阈值修改有问题。APatch/KernelSU + MetaModule 方案下，运行期修改温控 source 可能造成 stale OverlayFS、source/effective hash 不一致、SELinux context 不一致或重启后卡第二屏。Magisk 运行期修改也不宣称安全；只有离线更新并重启后复读才进入可验证路径。**

## 曲线救国策略

卸载 Pixel 9 Pro Control
→ 重启
→ 重新安装 ZIP
→ 向导选择新配置（建议先选系统默认温控）
→ 再重启
→ 检查 receipt、`/vendor` hash、source/effective hash 与 SELinux context

在复读完成前，不要通过 WebUI 修改 Hybrid Mount 下的 custom thermal。

## 资产边界

- 资产：最近一次完成 caiman + APatch + Hybrid Mount 实机冷启动验收的候选 ZIP。
- UECap balanced source/effective hash：`2870ba9c94145930ad75f1666c6ec2755ac207a7efc0aa4277bdde13cabaae0c`。
- Hybrid state：`/vendor`、`/vendor/firmware` overlay committed，`failed_mounts=0`。
- WebUI 12 文件第一轮改动已提交到 `main`，尚未纳入本设备验收资产；完整浏览器复核按 `docs/后续验收与发布计划-20260921.md` 执行。

本 RC 不是稳定版。Hybrid thermal A/B pending-slot 与 pre-mount promotion 仍未实现。
