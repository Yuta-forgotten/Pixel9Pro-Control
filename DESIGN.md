# Pixel9Pro-Control 设计决策

## 1. 目标与 ownership

本模块负责 Pixel 9 Pro / Pixel 9 Pro XL 的温控配置、Pixel 调度、ZRAM/VM、NR 息屏策略、SIM2 管理、后台限制、WebUI，以及在允许的 root/挂载后端上管理 UECap。

运营商配置由独立的 `pixel9pro_baseband_trial` 提供。两个模块可以独立安装；Control 不重新打包或接管 standalone 的 CarrierSettings/APN/MCFG/IMS overlay。

UECap ownership 按 SKU 固定，但挂载后端必须先满足启动安全边界：

- caiman：Control 管理 `PLATFORM_9055801516233416490.binarypb` 的 `balanced`、`special`、`universal` 三档；
- komodo：Control 默认保持 stock，只在用户显式选择时绑定独立 `PLATFORM_6287228797510365516.binarypb` candidate。

APatch 无 MetaModule 时不提供 managed UECap。活动 MetaModule 下，安装器在确认同 ID content image 为空后，把当前 SKU 的 canonical target 写入 `system/vendor/firmware/uecapconfig` staging，由 MetaModule 在重启前挂载；检测到旧 content image 时拒绝原地覆盖并要求 clean reinstall + reboot。post-mount 只复读有效路径/hash，不再执行动态 bind `/vendor`。

Hybrid Mount 是另一条 MetaModule backend：它把 regular module source 作为只读输入，在下一次 boot 按 overlay/magic/vfs 规则建立挂载。Control 检测到 Hybrid Mount 时不执行 `meta-overlayfs` hook patch、不检查 ext4 content image，也不要求卸载 Control；UECap/thermal 只写 regular module staging，重启后由 Hybrid Mount 复读有效 `/vendor`。该 backend 必须先在真实设备确认当前规则选择的是可接受的 `overlay` 或 `magic`，未知/失败仍 fail closed。

安装前还必须通过 `scripts/metamodule_compat.sh` 的 hook contract；它只接受已知的 MetaModule metainstall 形状，并修正错误的 mode/context 参数。未知或不兼容 hook 直接拒绝安装。

MetaModule content image 在安装阶段提交后，运行期 WebUI 不直接写 metadata 目录来假装改变有效 `/vendor`。UECap 档位和自定义温控请求会返回 `409 Conflict` 并要求重新安装；system 温控请求只有在 content image 不含任何旧 thermal 文件时才提交状态。这样不会出现“接口成功、重启后仍使用旧 image”的假状态。

启动期的 radio snapshot 只做诊断，不参与 content 合同验收；`service.sh` 不同步等待 telephony registry，避免 modem binder 阻塞 late_start 和 WebUI。receipt 的 content/effective hash、SELinux context 与同 boot freshness 仍是权威状态。

发布 ZIP 同时携带两机私有 staging payload，但设备合同只能解析当前 `ro.product.device` 的 source/target/hash。komodo candidate 为用户提供文件，来源 build 未知、SHA-256 为 `f2c0bc1dc1409b1780dbdf57e56ebfef15cf7f889e76315343d2ae139cb19090`；未完成实机验证前不得升级为 verified。

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

`scheduler_mode=off` 高于 profile、policy 和 owner：off 时所有 CPU profile、auto、reconcile、repair、health mutation 和 owner arbiter 写入都必须在入口处 no-op/拒绝，不能只在 WebUI 隐藏。重新启用前必须重新完成 capability verify，并通过重启启动 worker。

所有有副作用的路径遵循：

`前置验证 → 主写入 → 权威复读 → desired/effective marker 提交 → 失败回滚 → 回滚复读`

周期 worker 遇到锁、外部 owner、稳定状态或 terminal failure 时必须 no-op/defer，不重放参数。自动 mutation 使用有界重试与 terminal state；独立 health 只读，不用持续抢写修复外部调度器或 ThermalHAL 已接管的状态。

## 4. 温控与系统策略

温控只保留 `system` 与 `custom` 两种策略。默认 `system` 在 UI 中显示为“不修改温控（不添加配置）”：发布包和默认安装都不携带或生成 `thermal_info_config.json` overlay，也不停止系统 Thermal HAL。只有用户显式选择 `custom` 时，才从当前设备真实 vendor 文件或已验证的模块私有 stock snapshot 生成配置。

custom 目标 sensor 只展示真正改变阈值的 `-2/+2/+4/+6°C`，0°C 仅保留为旧状态兼容值而不作为入口。数值型 SHUTDOWN 保留 stock `55/59°C`；同时检查严格递增和下一档 `HotHysteresis` overlap，并保留 `0.1°C` 严格间隔，不能只检查固定间隔。WebUI 继续使用既有 Material 3 profile card，不引入新的颜色、间距或交互组件。

NR 息屏降级、SIM2、后台限制和功耗采样是使用层策略，不裁剪设备能力表。当前 caiman 已有 `NR_SA`/n41 实机证据，NSA 仅保留兼容解析；LTE 快照不能单独证明 Control 失效。

VM/ZRAM 默认 `system`，service 不写 sysctl、dirty 参数、ZRAM property 或设备节点；`optimized` 才允许这些 mutation，`disabled` 保留只读状态但禁用模块写入口。

## 5. WebUI 与后端 contract

WebUI 是 presentation layer。参数、默认值、能力边界和状态字段由 shell/backend contract 提供，前端不复制 ownership 或硬编码安装状态。基带卡片展示 active/pending、content/effective、contract/hash、runtime receipt 和 radio observed 的分层结果；“目录存在”与“本次启动已验证”必须视觉上区分。

写请求要求 loopback、随机 token、JSON body、CORS preflight 和 `X-PIXEL9PRO-TOKEN`。mutation 返回 compact verified response，前端随后读取 full state；请求超时不能被渲染成成功。

所有关键 mutation 同时写入隐私安全结构化审计日志；日志值经过受控 token 边界，不允许原始请求、用户路径、账号/号码、设备标识或完整系统 dump。失败响应必须同时满足非 200 HTTP status 与 `ok=false`。

功耗导出采用原子目录合同：人读报告、schema 1 JSON、功耗/温度原始 CSV 和受限 Top 归因分离；每个文件返回 bytes/hash。ODPM、batterystats 和采样 coverage 必须分别标注来源与可信边界，未知值不得伪装为 0。

### 5.1 WebUI shared primitives 与分析入口

WebUI 统一使用 `page-hero`、`surface-card/preference-card`、`summary-grid`、`disclosure`、`inline-alert` 和 `analytics-sheet` 六类共享 primitive。按钮只分为 Filled（当前主要动作）、Tonal（次要动作）、Text（低强调操作）和 Icon（无文字图标动作）四级；触控目标至少 `44px`，卡片选择统一使用 `primary-container` 与文字状态，不再由功能页各自定义强调色。

样式按职责拆分：`app.css` 只保留入口注释；`css/tokens.css`、`layout.css`、`components.css`、`controls.css`、`surfaces.css`、`modal.css`、`settings.css`、`analytics-legacy.css`、`analytics.css` 和 `diagnostics.css` 分别承载 token、布局、组件、控制项、表面层、Sheet 壳、设置页、旧统计兼容层、统一分析界面和诊断状态。所有文件均由 `index.html` 以同一版本占位加载，避免继续把业务样式堆回单一文件。运行记录实现位于 `diagnostics.js`，功耗趋势实现位于 `analytics_model.js` / `analytics_view.js`；`common.js` 与 `energy.js` 只保留请求协调和兼容代理。

温度历史与功耗统计共用 `analytics-sheet`：固定标题、单一范围选择、Hero 摘要、Canvas 趋势、构成卡片、更多统计和导出动作。自定义范围只允许最近 1–7 天，并按小时或分钟聚合；前端限制必须由 telemetry CGI 的 7 天边界再次兜底。Sheet 可收起为贴边状态条，收起期间仍允许轻量请求原位更新；来源切换优先复用缓存，后台再刷新，避免重复 status 请求阻塞趋势首屏。功耗趋势接口只读取模块低频历史，不触发 `batterystats`；系统总账、软件耗电排行和系统分项在完整快照到达后分层渲染，电荷计无正向差分时不绘制 0 值假曲线。

操作记录、错误详情、后台任务状态和过夜隔离分层表达：操作记录保留短摘要，失败项可展开脱敏错误；后台任务状态显示“最近一次 worker 快照”与用户可读的亮屏/息屏采样节奏，原始 worker 分支和循环计数只作为技术字段；过夜隔离明确是一次性对照实验，验证后关闭。

记录会话不启动新的高频常驻 worker。点击“开始低功耗记录”只标记导出起点并复用现有后台采样：亮屏温度约 15 秒、息屏停止温度采样，功耗亮屏约 60 秒、息屏约 10 分钟。导出包固定包含 `power.csv`、`thermal.csv`、`summary.json`、`attribution.csv` 和 `report.md`，并在报告中标明缺测区间、数据来源和可信边界。

## 6. 验证与已知限制

源码 gate、PowerShell/Android shell parser、contract/failure injection、WebUI 资源与 Chromium 回归、设备 TestLab、shadow、确定性 ZIP 和 entry/权限审计按变更影响范围执行。当前 Control source gate 与逻辑 gate 已通过，UECap/NR contract 为 `59/59`，当前源码 fingerprint 和 ZIP 状态以根级审查文档为准。

截至 2026-08-31，caiman/APatch 已完成前一份功能等价候选 ZIP 的安装、重启与 `NR_SA`/n41 复核；当前源码对应 ZIP 已重建并审计，但尚未重新安装。komodo 的 Control UECap 三档和完整实机闭环仍未声明完成；Magisk 下 UECap 三档继续禁用。

## 7. 变更历史

- `v4.5.05`：完成 Pixel/UGT reboot-selected baseline、fas-rs 双侧 lease、owner/health bounded transaction。
- `v4.5.07`：将 UECap 与 standalone baseband runtime state 分离，补齐 schema 3 receipt、source/content/effective contract、SKU 边界和 NSA/SA 状态语义。
- `v4.6.00`：统一分析 Sheet、运行记录与错误详情入口；增加轻量功耗趋势读取、可收起详情与温度 Sheet 导出入口。息屏唤醒复查仍由原有 30 秒恢复契约控制，避免牺牲亮屏恢复时效。
- `v4.6.00-ui`：恢复统一分析页的软件耗电排行，收紧自定义历史范围与采样粒度，修正功耗无证据时的 Canvas 坐标和假曲线；运行记录将清除动作移入后台日志工具栏，并支持脱敏后台日志导出。
