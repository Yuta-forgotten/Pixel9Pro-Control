# Pixel9Pro-Control 设计决策

## 1. 目标与 ownership

本模块负责 Pixel 9 Pro / Pixel 9 Pro XL 的温控配置、Pixel 调度、ZRAM/VM、NR 息屏策略、SIM2 管理、后台限制、WebUI，以及在允许的 root/挂载后端上管理 UECap。

运营商配置由独立的 `pixel9pro_baseband_trial` 提供。两个模块可以独立安装；Control 不重新打包或接管 standalone 的 CarrierSettings/APN/MCFG/IMS overlay。

UECap ownership 按 SKU 固定：

- caiman：Control 管理 `PLATFORM_9055801516233416490.binarypb` 的 `balanced`、`special`、`universal` 三档；
- komodo：Control 保持 `external/stock`，不写入 `PLATFORM_6287228797510365516.binarypb`。

这意味着安装框架、状态机、WebUI、通用 contract 可以复用，但 UECap filename、payload、hash、MCFG、firmware、`mcfg_hw`、Saipan 和 SKU-specific thermal stock 必须分别确认。

## 2. UECap 状态模型

UECap 状态不能只用“文件存在”表示。Control 分开记录：

- desired：用户或启动流程请求的档位；
- bound/effective：目标文件是否已经按 hash bind 到有效路径；
- modem load：是否有独立的 modem load/readback 证据；
- radio observed：当前电话注册与 RAT 观察；
- functional：是否达到可验证功能态；
- receipt freshness：receipt 是否属于当前 boot 和当前 source/target。

`pre_modem_bind` / `modem_load_unconfirmed` 是诚实的中间状态，不把 VFS bind hash 夸大成 modem 已加载 profile 的证明。切换失败必须执行恢复并复读旧 payload；不使用 airplane-mode toggle，避免同时撕裂 Wi-Fi、Bluetooth 和 connectivity。

## 3. 调度与事务

CPU response、cpuset、uclamp cap 与 vendor scheduler L2 属于同一 profile transaction。Pixel 与 UGT 是重启后选择的日常 baseline；fas-rs 只在有效游戏 lease 内成为临时 external owner，退出后恢复进入 lease 前的同一 baseline。

所有有副作用的路径遵循：

`前置验证 → 主写入 → 权威复读 → desired/effective marker 提交 → 失败回滚 → 回滚复读`

周期 worker 遇到锁、外部 owner、稳定状态或 terminal failure 时必须 no-op/defer，不重放参数。自动 mutation 使用有界重试与 terminal state；独立 health 只读，不用持续抢写修复外部调度器或 ThermalHAL 已接管的状态。

## 4. 温控与系统策略

温控配置从当前机型 stock JSON 生成。目标 sensor 允许有限 offset，数值型 SHUTDOWN 保留 stock `55/59°C`；同时检查严格递增和下一档 `HotHysteresis` overlap，不能只检查固定间隔。

NR 息屏降级、SIM2、后台限制和功耗采样是使用层策略，不裁剪设备能力表。当前 caiman 已有 `NR_SA`/n41 实机证据，NSA 仅保留兼容解析；LTE 快照不能单独证明 Control 失效。

## 5. WebUI 与后端 contract

WebUI 是 presentation layer。参数、默认值、能力边界和状态字段由 shell/backend contract 提供，前端不复制 ownership 或硬编码安装状态。基带卡片展示 active/pending、content/effective、contract/hash、runtime receipt 和 radio observed 的分层结果；“目录存在”与“本次启动已验证”必须视觉上区分。

写请求要求 loopback、随机 token、JSON body、CORS preflight 和 `X-PIXEL9PRO-TOKEN`。mutation 返回 compact verified response，前端随后读取 full state；请求超时不能被渲染成成功。

## 6. 验证与已知限制

源码 gate、PowerShell/Android shell parser、contract/failure injection、WebUI 资源与 Chromium 回归、设备 TestLab、shadow、确定性 ZIP 和 entry/权限审计按变更影响范围执行。当前 Control source gate 与逻辑 gate 已通过，UECap/NR contract 为 `59/59`，当前源码 fingerprint 和 ZIP 状态以根级审查文档为准。

截至 2026-08-31，caiman/APatch 已完成前一份功能等价候选 ZIP 的安装、重启与 `NR_SA`/n41 复核；当前源码对应 ZIP 已重建并审计，但尚未重新安装。komodo 的 Control UECap 三档和完整实机闭环仍未声明完成；Magisk 下 UECap 三档继续禁用。

## 7. 变更历史

- `v4.5.05`：完成 Pixel/UGT reboot-selected baseline、fas-rs 双侧 lease、owner/health bounded transaction。
- `v4.5.07`：将 UECap 与 standalone baseband runtime state 分离，补齐 schema 3 receipt、source/content/effective contract、SKU 边界和 NSA/SA 状态语义。
