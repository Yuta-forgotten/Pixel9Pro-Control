# v4.6.00-rc1-hybrid3 — UI 第一轮候选 / Hybrid Mount 风险警告

## 发行警告

**此版本的温度阈值修改有问题。APatch/KernelSU + MetaModule 方案下，运行期修改温控 source 可能造成 stale OverlayFS、source/effective hash 不一致、SELinux context 不一致或重启后卡第二屏。**

## 曲线救国策略

1. 卸载 Pixel 9 Pro Control。
2. 重启设备。
3. 重新安装本 ZIP。
4. 在安装向导中选择新配置；温控建议先选择系统默认。
5. 再次重启。
6. 检查安装 receipt、运行 receipt、`/vendor` effective hash、source/effective hash 以及 SELinux context。

在上述复读通过前，不要在 WebUI 中再次修改 Hybrid Mount 下的 custom thermal 配置。

## 本 RC 内容

- WebUI 第一轮分析/诊断/后台日志改动。
- 最近 1–7 天自定义统计与小时/分钟粒度。
- 无有效功耗差分时不绘制假曲线。
- 软件耗电排行与后台日志导出入口。
- Hybrid Mount regular source readback receipt 改进。

本 RC 不是稳定版；
