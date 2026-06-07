# Pixel 9 Pro Control 模块完整审计报告

审计日期: 2026-06-08  
审计对象: `pixel9pro_control_v2` 主模块、WebUI CGI、开机服务、CPU 调度脚本、UECap 管理、独立基带子模块入口  
关联对象: `Uperf-Game-Turbo` 本地审计结果与共存边界

## 结论摘要

本模块整体架构清晰，主链路是“安装期配置 + 开机服务守护 + WebUI CGI 控制 + 前端状态展示”。高风险 root 操作大多有输入枚举、loopback、token、锁和状态文件约束，未发现明显的远程未授权写入入口，也未发现主模块存在 `rm -rf /data`、直接改 system 分区、乱改权限等不可逆高危动作。

本次已补齐 `Uperf Game Turbo / 外部调度接管模式`: `.cpu_sched_owner` 支持安装向导、旧版升级刷入、WebUI 性能页三处开关。开启 external 后，本模块停止写入 CPU 调度相关节点，包括 `sched_pixel response_time_ms`、`sched_util_clamp_min`、`/dev/cpuset/*/cpus`、`/proc/vendor_sched/ug_bg_*`，让 Uperf 或其它外部调度模块接管 CPU。

v4.4.7 在 v4.4.6 审计硬化基础上补齐 Uperf Game Turbo 探测与调度接管语义：安装向导与 WebUI 共用 `scripts/scheduler_detect_lib.sh` 扫描 `/data/adb/modules_update` 与 `/data/adb/modules`。检测到 Uperf 时提示“本模块覆盖接管 / 不覆盖”，未检测到时提示“启用 / 不启用本模块 CPU 调度”，不再给出安装外部模块的暗示。

v4.4.6 已按本审计修复可闭环余患: 后台限制会记录 `.bg_restrict_baseline` 并按原 bucket/appops 恢复，`.profile_history` 增加 `sched_owner` 字段，`energy.sh` cache lock 增加 stale 回收，WebUI httpd 改用 pid 文件定位本模块实例，WebUI token 改为每次 service 启动轮换。

仍需保留的主要风险是: WebUI token 通过本机 loopback GET 引导给前端，能防普通网页跨站，但无法彻底防本机恶意 App 主动访问 `127.0.0.1:6210`; UECap bind mount 与 modem restart 属于设备敏感操作; thermal service 在线重启依赖服务名和当前系统状态。

## 功能与入口图谱

| 模块区域 | 入口文件 | 作用 | 审计结论 |
|---|---|---|---|
| 安装期配置 | `customize.sh` | 机型识别、Magisk 自适应、温控偏移、CPU 档位、调度接管/Uperf 覆盖关系、UECap、NR、NTP、迁移旧配置 | 已加入旧版升级调度接管开关; Magisk 下剔除 UECap 覆盖是合理止血 |
| 开机服务 | `service.sh` | WebUI token/httpd、UECap 应用、待机设置、SIM2、后台限制、ZRAM、CPU profile、统一 worker | 逻辑完整; 外部接管时已跳过 L2/L3 CPU 写入; httpd 已改 pid 文件定位 |
| CPU 调度 | `scripts/cpu_profile.sh` | 4 个 profile、status、vendor_sched enforce | 不写 `scaling_min/max`; 外部接管时 no-op |
| WebUI 安全底座 | `webroot/cgi-bin/_common.sh` | loopback、token、JSON POST、锁 | 基础完备; loopback 不是本机 App 隔离边界 |
| 温控配置 | `set_thermal.sh` + thermal JSON | 改写模块 overlay 内 `thermal_info_config.json` 并尝试重启 thermal | 输入枚举安全; 在线重启存在系统版本适配风险 |
| 温度读取 | `thermal.sh` / `_thermal_cache.sh` | thermalservice + sysfs 缓存与历史 | 低频缓存合理; 解析依赖 dumpsys 文本格式 |
| UECap | `uecap_profile.sh` / `uecap.sh` | binarypb bind mount、hash 校验、modem restart | APatch/KSU 可用; Magisk 禁用合理; 属敏感操作 |
| 待机网络 | `nr_switch.sh` / `standby_guard.sh` | NR 息屏降级、SIM2 空槽、待机隔离 | 使用 `cmd phone set-sim-count` 比旧 radio power 更稳 |
| 后台限制 | `bg_restrict.sh` + `scripts/bg_restrict_lib.sh` | App Standby + AppOps 列表管理 | 输入包名有白名单; v4.4.6 起保存 baseline 并按原值恢复 |
| 内存 | `swap.sh` + service boot | ZRAM lz77eh、VM sysctl | 可回退; `swapoff` 失败时保留现状 |
| 功耗详情 | `energy.sh` | batterystats + 模块会话 + ODPM | 口径说明清晰; v4.4.6 已补 cache lock stale 回收 |
| 前端 | `webroot/app.js` / `index.html` / `app.css` | Material WebUI、状态轮询、操作按钮 | 已支持 Uperf 接管状态与禁用 profile 卡片 |

## 审计范围说明

本次功能/代码审计覆盖运行时有效文件，不把 `dist/_build_*` 旧构建产物作为当前逻辑依据。二进制配置文件仅做路径、加载时序和覆盖关系审查，不反编译 `binarypb` / `pb` 内容。

当前主要源码规模:

| 文件 | 行数级别 | 角色 | 审计重点 |
|---|---:|---|---|
| `webroot/app.js` | 约 2470 行 | 前端单页控制台 | 状态同步、轮询、POST 契约、UI 禁用态 |
| `service.sh` | 约 1200 行 | 开机服务与统一 worker | 启动顺序、调度状态机、待机唤醒、root 写入 |
| `webroot/app.css` | 约 1060 行 | UI 样式 | 视觉状态、禁用态、移动端可用性 |
| `index.html` | 约 500 行 | WebUI DOM | 控件挂载点、CSP、资源缓存 |
| `customize.sh` | 约 370 行 | 刷入安装向导 | 首装/升级迁移、机型分支、Magisk 兼容 |
| `energy.sh` | 约 355 行 | 功耗详情 | batterystats 解析、缓存锁、会话口径 |
| `profile.sh` | 约 200 行 | CPU profile CGI | profile/policy/owner 三状态契约 |
| `cpu_profile.sh` | 约 185 行 | CPU 节点写入 | Pixel 调度与外部接管 no-op |
| `uecap_profile.sh` | 约 160 行 | UECap bind mount | hash、bind、modem reload |

## 详细功能逻辑审计

### 1. 安装与升级逻辑

安装主流程:

1. 检测 root 实现: APatch / KernelSU / Magisk / Unknown。
2. Magisk 下删除 UECap binarypb 覆盖与 CGI 实体，避免 Magic Mount 与 modem cbd 早期 mmap race。
3. 根据 `ro.product.device` 选择 `caiman` / `komodo` 温控 stock JSON。
4. 若检测到旧模块目录，迁移状态文件。
5. 首次安装通过音量键配置温控、CPU、调度接管/Uperf 覆盖关系、UECap、NR、NTP、ZRAM。
6. 升级安装补齐缺失默认值。
7. 以 stock thermal JSON 为基准生成当前 offset 的 `thermal_info_config.json`。

审计结论:

- 首装路径完整。
- 升级迁移已覆盖 `.thermal_offset`、profile、NR/SIM2/idle、swap、NTP、UECap、后台限制、WebUI token。
- 本次已补 `.cpu_sched_owner` 迁移。
- 本次已补旧版升级场景: 若旧版本没有 `.cpu_sched_owner`，刷入新版本时会显示“新增设置 — CPU 调度接管”，由音量键选择。
- Magisk 下主动剔除 UECap 覆盖是正确的功能取舍，避免基带早期加载 race。

潜在问题:

- 升级路径只有在 `.cpu_sched_owner` 缺失时询问。若用户已有该文件，则保留既有选择，不重复询问。这符合“保留用户配置”，但若前辈希望每次刷入都强制询问，可改为始终提示。
- 安装向导依赖 `getevent` 音量键，若 recovery/root manager 环境事件不可读，可能卡在选择循环。已有同类模块常用此方式，但可考虑设置超时默认值。
- `eval "_cpu_label=\"\$_CPU_LABEL_${_cpu_cur}\""` 输入来自内部枚举，当前安全; 若未来改成外部输入需去掉 `eval`。

### 2. 开机服务顺序

`service.sh` 启动顺序:

1. 生成或复用 WebUI token，设置 0600。
2. 导出 CGI 环境变量。
3. 应用 UECap profile。
4. 应用 keep-5G 待机基础设置: mobile data always on、Nearby、Wi-Fi/BLE scan、adaptive connectivity、network recommendations。
5. 初始化 SIM2 状态、UECap/ZRAM/VM。
6. 应用 L1 后台应用限制。
7. 按 `.cpu_sched_owner` 决定是否应用 L2 vendor_sched。
8. 按 `.cpu_sched_owner` 决定是否应用 CPU profile。
9. 启动统一后台 worker。
10. 启动 BusyBox httpd loopback WebUI。

审计结论:

- 顺序基本合理: 先配置持久/半持久项，再启动 worker。
- L1/L2/L3 分层清晰。
- 本次 Uperf external owner 已覆盖 boot L2/L3 和 worker enforce/auto。
- 统一 worker 把多个旧循环合并，降低 Doze 干扰，逻辑方向正确。

潜在问题:

- `service.sh` 文件偏长，职责多，后续维护成本高。v4.4.6 已先拆出 `scripts/bg_restrict_lib.sh`，后续仍建议继续拆成 `lib_state.sh`、`lib_radio.sh`、`lib_power.sh`、`lib_webui.sh`。
- boot 阶段同时处理 UECap、ZRAM、系统设置、WebUI、worker，某个慢命令可能拖延后续步骤。当前大多静默失败，建议关键路径增加更明确的状态文件。
- WebUI httpd 已改为 `.webui_httpd.pid` 定位本模块实例，并校验 cmdline 后才 kill；若端口被其它进程占用，仅写 warning。

### 3. CPU 调度状态机

状态文件:

| 文件 | 取值 | 含义 |
|---|---|---|
| `.current_profile` | `performance/balanced/battery/default` | 当前本模块记录的 active profile |
| `.profile_manual` | 同上 | 手动模式目标 profile |
| `.profile_policy` | `manual/auto` | 自动/手动策略 |
| `.profile_auto_reason` | reason string | 最近一次自动/手动原因 |
| `.profile_history` | CSV | 最近 profile 证据 |
| `.cpu_sched_owner` | `pixel/external` | CPU 调度所有权 |

功能逻辑:

- `manual`: worker 在亮屏时确保 active profile 回到 `.profile_manual`。
- `auto`: 只在 `balanced <-> battery` 之间慢切换，永不自动进 `performance`。
- 充电与放电使用不同 VIRTUAL-SKIN hold/cool 阈值。
- 息屏路径回到 `balanced`，避免手动性能档长时间挂着。
- `external`: 本次新增，跳过 profile 写入与 enforce。

审计结论:

- 自动调度逻辑稳健，属于“慢收口”而不是高频抖动。
- `performance` 手动专用的约束合理。
- `.profile_history` 记录 cap/response/温度，便于 ADB + Scene 复盘。
- external owner 的语义清楚: 只让出 CPU 调度，不影响温控/待机/内存。

潜在问题:

- v4.4.6 起 `.profile_history` 已记录 `sched_owner` 字段。旧记录仍为 9 列，新记录为 10 列，解析时需兼容。
- external 模式下 worker 每周期写 `.profile_auto_reason=external_scheduler`，功能正确但有轻微无意义写入，可改成值变化才写。
- profile POST 与 owner POST 共用 `profile.sh`，契约清楚，但未来字段增多时建议拆分 `/profile.sh` 与 `/scheduler_owner.sh`。

### 4. Uperf / 外部调度接管逻辑

当前实现覆盖五层:

| 层 | 文件 | 行为 |
|---|---|---|
| Uperf 探测 | `scripts/scheduler_detect_lib.sh` | 扫描 `modules_update/modules` 的 `module.prop`，识别 Uperf Game Turbo 并输出 id/name/path/source/state/enabled |
| 安装/升级 | `customize.sh` | 首装与旧版升级都可选择 `pixel/external`；检测到 Uperf 时给“覆盖/不覆盖”，未检测到时给“启用/不启用本模块调度” |
| 后端状态 | `profile.sh` | GET/POST 读写 `sched_owner`，GET 返回 Uperf 探测字段，external 阻止切 profile |
| 实际写节点 | `cpu_profile.sh` | external 下所有写操作 no-op，status 仍可读 |
| 后台 worker | `service.sh` | external 下 boot/enforce/auto 都跳过 |
| 前端 | `app.js/index.html` | 性能页显示接管方，禁用手动/自动/profile 卡片 |

审计结论:

- 这是真正的“停止抢写”，不是只隐藏 UI。
- 对已安装低版本用户，升级刷入时可选择。
- WebUI 可运行时切换，不必重新刷包。
- 未检测到 Uperf 时，external 的语义是“本模块不写 CPU 调度节点，保留系统或其它外部调度现状”，不是“安装 Uperf”。

边界:

- external 模式不清理此前本模块已写过的值; 它只保证之后不再写。启用 Uperf 后，Uperf 会按自己的逻辑覆盖节点。
- 若没有启动 Uperf，仅开启 external，则 CPU 节点会停留在当前系统/上次模块状态。
- Uperf 若自身 stop/start PowerHAL 或写 thermal/power 节点，本模块无法约束。

### 5. WebUI 前端逻辑

前端状态中心 `state` 维护 profile、thermal、swap、NR、SIM2、UECap、后台限制、NTP、轮询器、弹窗状态。

审计结论:

- `apiFetch` 统一加 token，统一 timeout。
- 轮询按 tab 与 idle 状态降频，避免持续高频刷新。
- 大多数动态文本使用 `textContent`，XSS 风险低。
- UECap 切换有 hash 校验轮询，功能体验较完整。
- 温度历史弹窗有定时刷新和关闭清理。
- 本次新增 external 状态后，profile 卡片禁用、按钮 busy 状态、hero 状态同步完整。

潜在问题:

- `app.js` 已接近 2500 行，单文件承担太多视图和 API 逻辑。建议后续拆为 `api.js`、`state.js`、`render_perf.js`、`render_optim.js`。
- `openDetail(title, html)` 使用 `innerHTML` 渲染固定模板字符串。当前内容来自本地常量和内部拼接，风险可控; 但不要把未经转义的外部输入传进去。
- `location.host !== '127.0.0.1:6210'` 写死端口; 若以后 `PORT` 可配置，前端需同步。

### 6. WebUI CGI 契约

| CGI | GET | POST | 输入校验 | 功能判断 |
|---|---|---|---|---|
| `_common.sh` | - | - | loopback/token/json/lock | 公共基础可用 |
| `profile.sh` | profile/policy/owner/history | profile/policy/owner | 枚举 | 本次已补 external owner |
| `status.sh` | CPU freq/resp/down/gov | 无 | GET only | 只读安全 |
| `set_thermal.sh` | offset | offset | 0/2/4/6 | 逻辑完整 |
| `thermal.sh` | realtime/history | 无 | minutes clamp | 读取逻辑完整 |
| `thermal_burst.sh` | burst 状态 | 开启 5min burst | JSON POST + token | 逻辑简单 |
| `swap.sh` | VM/ZRAM 状态 | optimized/stock | 枚举 | 即时生效 |
| `nr_switch.sh` | NR 开关/当前模式 | toggle | token/json | 逻辑简单 |
| `standby_guard.sh` | SIM2/idle/diag | on/off | 枚举 | 能恢复 SIM2 |
| `bg_restrict.sh` | 列表/状态 | toggle/refresh/add/remove | action + package 白名单 | 功能完整 |
| `uecap.sh` | policy/mode/hash | mode/policy | 枚举; Magisk stub | 逻辑完整 |
| `ntp.sh` | server/time | server/sync | 本次补 JSON POST | 功能完整 |
| `energy.sh` | 功耗详情 | 无 | GET only | 解析复杂但口径清楚 |
| `info.sh` | 设备/版本/token/内存 | 无 | GET only | token 暴露是主要安全边界 |
| `reboot.sh` | 无 | reboot | JSON POST + token | 高危操作但受保护 |
| `check_baseband.sh` | 基带模块状态 | 无 | GET only | 只读安全 |

审计结论:

- 写接口已基本统一为 JSON POST + token。
- 参数都走枚举/白名单，命令注入面较小。
- 需要注意 `info.sh` token bootstrap 的本机 App 风险。

### 7. 温控功能逻辑

温控处理分两层:

- 安装期/切换期: 从 stock JSON 重新生成当前 offset 的 `thermal_info_config.json`。
- 运行期: WebUI 与 worker 通过 `thermalservice`/sysfs 读取温度，写入 `.thermal_cache.json` 与 `.thermal_history`。

审计结论:

- 以 stock 为基准重算比在当前文件上叠加 offset 更安全，不会重复加偏移。
- offset 只接受 `0/2/4/6`，避免任意升温。
- 历史文件有行数裁剪。

潜在问题:

- thermal JSON 用 awk 文本改写，依赖文件格式中 `Name` 与 `HotThreshold` 的结构。如果 Google 后续改变 JSON 结构，可能失效。
- 在线重启 thermal 服务的服务名列表是经验匹配，失败时必须依赖重启生效。
- 报告中应持续区分“温控阈值 overlay 生效”与“当前 thermalservice 是否已重载”。

### 8. 网络/基带功能逻辑

功能拆分:

- 主模块: UECap 三档、NR 息屏降级、SIM2 空槽管理、NTP。
- 独立基带模块: IMS props、CarrierSettings、MCFG。

审计结论:

- 主模块和独立基带模块职责边界清楚。
- Magisk 主模块禁用 UECap，但独立基带模块仍可单独管理 CarrierSettings/MCFG。
- NR 降级有热点接口检查，避免热点场景误切 LTE。
- SIM2 使用 `set-sim-count` 是当前项目规则中的正确 API。

潜在问题:

- `preferred_network_mode1` / `preferred_network_mode` 在 DSDS、系统版本、运营商配置下格式可能变化; 代码已有逗号格式处理，但仍需实机验证。
- `cmd phone restart-modem` 对通话/数据会有短断，WebUI 已表现为 reloading，但报告中需提醒。
- `set-sim-count` 是持久状态，异常退出后依赖 worker/手动关闭恢复，已有 `restore_sim2_unmanaged_state`，但仍建议在 uninstall 中恢复 DSDS。

### 9. 内存/ZRAM 功能逻辑

审计结论:

- boot 阶段检查当前算法和大小，只有不匹配才尝试重配。
- `swapoff` 失败时保留现状并 log，避免强行 reset。
- WebUI 只切 VM 参数，不在线改 ZRAM 大小，较稳。

潜在问题:

- stock 模式写死 `min_free_kbytes=27386`，这是假定 Pixel 当前 stock 值。系统更新后 stock 可能变化。
- 建议首次启动保存 stock VM 参数快照，恢复时按快照回滚。

### 10. 功耗统计逻辑

`energy.sh` 同时输出三种口径:

- 模块定义的当前放电会话。
- 模块低频采样的今日累计。
- Android batterystats 当前窗口。

审计结论:

- 口径划分正确，避免把长期 batterystats 误当成当前会话。
- ODPM modem/rffe 反推比 Pixel 9 Pro 的 `mobile_radio mAh` 系统估算更可信。
- 45s cache 能降低重复 dumpsys 的瞬时开销。

潜在问题:

- `dumpsys batterystats` 文本格式变化会导致解析偏差。
- `_core_json` 中 UID Top 应用排序依赖 batterystats 输出顺序，未重新排序; 若原输出已按功耗排列则可用，否则可能不是严格 Top。
- cache lock 已在 v4.4.6 增加 pid + timestamp stale 回收。

## 代码质量审计

### 优点

- shell 函数命名基本清晰。
- 大部分状态都有单独 dotfile，便于 ADB 复盘。
- 写操作多数有锁。
- 前端状态与 CGI 状态基本闭环。
- 关键设计决策在注释中有历史原因，不是黑箱脚本。
- 没有引入大型运行时依赖，适合 Magisk/APatch/KSU 环境。

### 主要代码债

| 位置 | 问题 | 影响 | 建议 |
|---|---|---|---|
| `service.sh` | 单文件 1200 行，启动、网络、功耗、CPU、WebUI 都在一起 | 修改风险上升，局部验证困难 | 拆分库文件，service 只编排 |
| `app.js` | 单文件约 2470 行 | 前端改动容易误伤其它 tab | 按 tab/功能拆模块 |
| 多 CGI | sed 解析 JSON | 简单字段可用，复杂输入脆弱 | 继续保持短枚举; 复杂输入引入严格解析 |
| `energy.sh` | awk 大段解析 batterystats | 维护门槛高 | 增加样例输入 fixture 与离线测试 |
| 状态文件 | profile history CSV 列含义靠代码约定 | 后续加字段容易破坏旧解析 | 写 header 或版本化 |
| 恢复逻辑 | VM 参数未保存 stock 快照；appops/bucket v4.4.6 已保存 baseline | “恢复默认”可能不是原始默认 | VM 首次启动保存 baseline |

### 回归测试缺口

当前项目缺少自动化测试。建议补三类低成本测试:

1. shell syntax: 所有 `.sh` 执行 `sh -n`。
2. CGI contract: 用环境变量模拟 `REQUEST_METHOD/CONTENT_LENGTH/REMOTE_ADDR`，对枚举输入做正反例。
3. parser fixture: 保存一份 `dumpsys thermalservice` 和 `dumpsys batterystats` 样例，离线验证 JSON 输出。

## Uperf Game Turbo 共存审计

### 是否能共存

可以，但前提是本模块的 CPU 调度权必须让出。Uperf 社区可在 Pixel 9 Pro 上运行，并不等价于“和本模块同时写调度节点也无冲突”。冲突点不在 APK/模块安装层，而在运行时 root 写节点层。

### 不开启共存时的冲突点

| 冲突面 | 本模块行为 | Uperf 行为 | 结果 |
|---|---|---|---|
| `sched_pixel response_time_ms` | profile 切换写 12/20/80、16/40/200、32/96/200 等 | Uperf 自己按 scene/配置调度 | 双方互相覆盖升频节奏 |
| `sched_util_clamp_min` | performance=1024，其它档=0 | Uperf 脚本会清理/锁定 uclamp/stune 类 boost | boost 语义冲突 |
| `/dev/cpuset/*/cpus` | top-app/fg/bg/system-bg 分配 | Uperf JSON 与脚本也管理 cpuset | 前后台核路由互抢 |
| `/proc/vendor_sched/ug_bg_*` | L2 + 15s enforce | Uperf/PowerHAL 也可能覆盖调度策略 | 后台限制互抢 |
| 自动 profile worker | 亮屏/息屏/温度变化时自动切档 | Uperf 以 input/SF/load/top-app 做 scene | 状态机互相干扰 |

### 本次实现的共存边界

`.cpu_sched_owner=external` 时，本模块停止以下动作:

- `service.sh` boot 阶段跳过 `apply_l2_vendor_sched`
- `service.sh` boot 阶段跳过 `cpu_profile.sh <profile>`
- `service.sh` worker 亮屏阶段跳过 `cpu_profile.sh enforce`
- `service.sh` worker 自动/手动 profile 状态机不再写 profile
- `profile.sh` 拒绝 profile/policy 切换，只允许恢复接管权
- `cpu_profile.sh` 对 `performance/balanced/battery/default/enforce` 直接 no-op
- WebUI 禁用手动/自动按钮和 profile 卡片

共存模式仍保留:

- 温控阈值 overlay
- WebUI
- ZRAM/VM
- NR 息屏降级
- SIM2 空槽管理
- 后台应用限制
- NTP
- UECap/APatch-KSU 管理
- 温度/功耗采样

## 本次代码变更审计

| 文件 | 变更 | 评价 |
|---|---|---|
| `scripts/cpu_profile.sh` | 新增 `SCHED_OWNER_FILE` 与 external no-op; status 输出 owner | 正确，底层兜底 |
| `service.sh` | boot L2/L3 与 worker enforce/auto 识别 external | 正确，覆盖后台回写层 |
| `scripts/scheduler_detect_lib.sh` | 新增 Uperf Game Turbo 只读探测: `id=uperf` 或 name/description 同时含 `uperf`/`game turbo` | 正确，安装期与 WebUI 共用口径 |
| `webroot/cgi-bin/profile.sh` | GET 输出 `sched_owner` 与 Uperf 探测字段; POST 支持 `pixel/external`; external 阻止 profile/policy | 正确，后端兜底 |
| `webroot/app.js` | 性能页显示探测状态和接管方，按钮按“覆盖/不覆盖/启用/停用”切换，禁用 profile 卡片 | 正确，避免误操作 |
| `webroot/index.html` / `app.css` | 新增调度接管 UI 与禁用态 | 正确 |
| `customize.sh` | 首装与旧版升级均提供 CPU 调度接管选择; 检测到 Uperf 时提示覆盖/不覆盖，未检测到时提示启用/不启用本模块调度; 迁移 `.cpu_sched_owner` | 正确，覆盖前辈指出的升级场景与无 Uperf 场景 |
| `ntp.sh` | POST 增加 `require_json_post` | 加固一致性 |
| `module.prop` / `README.md` | 升级 v4.4.7，记录 Uperf 探测与调度接管选择 | 正确 |
| `scripts/bg_restrict_lib.sh` | 新增后台限制 baseline 记录/恢复共享逻辑 | 修复 R4，避免 CGI 与 service 恢复策略分叉 |
| `energy.sh` | cache lock 增加 stale 回收 | 修复 R6 |
| `service.sh` | WebUI token 每次启动轮换，httpd pid 文件管理 | 缩短 token 暴露窗口，修复 R9 |

## 风险发现

| 编号 | 等级 | 位置 | 发现 | 影响 | 建议 |
|---|---|---|---|---|---|
| R1 | P1 | `info.sh` + WebUI token 设计 | `info.sh` 在 loopback GET 中返回 `webui_token`，前端再用于 POST；v4.4.6 token 改为每次 service 启动轮换 | 能防普通网页跨站并缩短泄露窗口，但本机恶意 App 仍可直接访问 `127.0.0.1:6210` 获取 token 后调用 root CGI | 若威胁模型包含本机恶意 App，需要改为 Root 管理器授权 WebUI、随机一次性 URL、Unix socket/本地抽象 socket 或前端外部注入 token；BusyBox httpd 静态 CGI 难以彻底解决 |
| R2 | P2 | `uecap_profile.sh` | 对 `/vendor/firmware/uecapconfig/...binarypb` 做 bind mount 并 restart modem | APatch/KSU 下可实现能力切换，但 Android 更新、SELinux context、modem 早期加载时序变化可能引发无服务或重启循环 | 保持 Magisk 禁用; APatch/KSU 每次系统大版本更新后先手动验证 hash 与 modem restart |
| R3 | P2 | `set_thermal.sh` | 切换温控后尝试 stop/start thermal 服务 | 服务名变化或 thermal 当前状态异常时可能无法即时生效，需重启 | UI 已有重启提示; 建议记录实际命中的 service name 到状态文件 |
| R4 | Fixed v4.4.6 | `bg_restrict.sh` + `scripts/bg_restrict_lib.sh` | remove 时统一恢复 active/allow | 已新增 `.bg_restrict_baseline`，添加限制前记录 bucket/RUN_IN_BACKGROUND/RUN_ANY_IN_BACKGROUND，移除或关闭时优先按原值恢复 | 老版本已限制且无 baseline 的包仍走 legacy fallback，后续新增/重新添加的包可完整恢复 |
| R5 | P2 | `service.sh` ZRAM | boot 阶段可能执行 `swapoff /dev/block/zram0` | 高内存压力时失败会保留现状; 成功时短时影响内存管理 | 已有失败保护; 建议只在早期开机或低压状态执行重配 |
| R6 | Fixed v4.4.6 | `energy.sh` | 自建 cache lock 无 stale 回收 | 已增加 pid + timestamp stale 回收，异常退出后下一次请求可清理旧锁 | 保留旧 cache 兜底逻辑 |
| R7 | P3 | 多个 CGI | 用 sed 解析 JSON | 当前字段均白名单/短 body，风险可控; 复杂 JSON 会解析失败 | 保持字段枚举; 若将来增加复杂输入，改用 toybox/cmd 可用 JSON 工具或更严格解析 |
| R8 | P3 | `standby_guard.sh` | source `.standby_diag_state` | 文件由本模块写入，root 环境下可控; 非 root 难以写入模块目录 | 若进一步硬化，可改为逐行 key 白名单解析 |
| R9 | Fixed v4.4.6 | `service.sh` httpd | `pkill -f "httpd -p .*${PORT}"` | 已改 `.webui_httpd.pid` + cmdline 校验，仅停止本模块实例；端口被其它进程占用时只记录 warning | 若 pid 文件缺失，会按本模块 webroot/port 查找同一实例 |

## 安全面审计

### 已做得好的点

- WebUI 绑定 `127.0.0.1:6210`，不是 `0.0.0.0`
- CGI 统一 `require_loopback`
- 写接口基本都要求 token
- 写接口基本使用 `application/json` 触发 preflight，减少浏览器 CSRF
- 状态修改使用短枚举: profile、policy、owner、offset、mode、on/off
- 包名输入限制为 `[a-zA-Z0-9._]`
- 锁使用 `mkdir` 原子目录，主要写接口有互斥
- CSP 限制 `script-src 'self'`
- WebUI 前端使用 `textContent` 为主，低 XSS 风险

### 主要安全余患

本模块的 WebUI 安全边界是“本机 loopback + token”。这对浏览器跨站请求有效，但不是 Android 本机 App 级强隔离。若设备上存在恶意 App 且它可主动访问 `127.0.0.1:6210`，它可以 GET `info.sh` 拿 token，再发 POST 调用 root CGI。这不是当前补丁引入的问题，是现有 BusyBox httpd WebUI 架构的天然边界。

## 功能正确性审计

### CPU 调度

当前 Pixel 调度方案是 Pixel 9 Pro/Tensor G4 专用:

- cpu0-3: A520
- cpu4-6: A720
- cpu7: X4
- 不写 `scaling_min_freq/scaling_max_freq`
- 用 `sched_pixel response_time_ms` 控制升频响应
- 用 `sched_util_clamp_min` 作为 uclamp.min 系统级 cap
- 用 cpuset 控制 top-app/background 路由
- 用 vendor_sched L2 限制后台

调度档:

| 档位 | response | cap | top-app | 定位 |
|---|---:|---:|---|---|
| performance | 12/20/80 | 1024 | 0-7 | 手动高性能，放开动态 boost |
| balanced | 16/40/200 | 0 | 0-7 | 日常低热底座 |
| battery | 32/96/200 | 0 | 0-6 | 热平台/省电 |
| default | 16/64/200 | 0 | 0-7 | 保守回退 |

结论: 方案比直接写频率稳健，符合 Pixel PowerHAL/Thermal 会覆盖 cpufreq 的现实。与 Uperf 同时启用时必须让出调度权。

### 温控

温控只改模块 overlay 内的 `thermal_info_config.json`，以 stock JSON 为基准对目标 VIRTUAL-SKIN/CPU/GPU 热区 HotThreshold 做 +0/+2/+4/+6 偏移。安全阈值未在脚本中主动删除或降级。风险集中在 JSON 文本格式变化和 thermal 服务在线重启不稳定。

### 待机与蜂窝

NR 息屏降级采用 `settings put global preferred_network_mode*`，SIM2 空槽采用 `cmd phone set-sim-count 1/2`。这比旧的 `radio power -s 1 off` 稳定，但仍属于 modem 状态机操作，应避免在热点、双卡、下载场景默认打开过激策略。当前代码已有 tethering 检测与 SIM2 默认/恢复逻辑。

### 内存与 ZRAM

ZRAM 目标为 lz77eh + 11392MB，VM 参数为 `swappiness=100`、`min_free_kbytes=65536`、`vfs_cache_pressure=60`。失败时保留当前 ZRAM 配置，不强行破坏。风险为 boot 阶段 `swapoff` 成功时短时间影响内存; 但失败会止损。

### UECap 与基带

主模块管理 UECap binarypb，独立基带模块管理 CarrierSettings/MCFG/IMS props。Magisk 下自动剔除 UECap 覆盖以规避 Magic Mount 与 modem cbd 早期 mmap 的 race，这个判断是合理的。APatch/KSU + metamodule 场景下 bind mount 仍需实机验证。

## Uperf 调度方案可借鉴点

Uperf 的优势不是“更激进地锁频”，而是更细粒度的用户态 scene controller:

- 监听 input/touch/gesture
- 观察 top-app/cpuset 切换
- 观察 SurfaceFlinger 渲染开始、卡顿、结束
- 基于 CPU 负载与效率模型计算需求 capacity
- 对 UI/Game/Render/Worker/Background 线程做 affinity/priority 分类
- 用短 burst 而非长期高压维持响应

本项目若继续自研游戏调教，建议只借鉴思想，不移植 Uperf 的通用 root 脚本:

- 保持 Pixel 专用 `sched_pixel + uclamp cap + thermal guard`
- 增加 per-app/game profile 列表
- 增加轻量 scene 状态: `idle/touch/switch/game_boost/game_sustain/cooldown`
- 先做日志与验证，不先做 taskset/thread pinning
- 绝不引入 Uperf 脚本里的 PowerHAL/thermal 停启、cpufreq min/max、bind mask、chmod 0444 锁节点

## 验证建议

### 刷入/升级验证

1. 从 v4.4.4 或更低版本升级，确认安装期出现“新增设置 — CPU 调度接管”。
2. 选择开启后，重启进入系统，检查:

```sh
cat /data/adb/modules/pixel9pro_control/.cpu_sched_owner
sh /data/adb/modules/pixel9pro_control/scripts/cpu_profile.sh status /data/adb/modules/pixel9pro_control
logcat -d | grep pixel9pro_ctrl | grep -E 'scheduler owner=external|CPU profile skipped|L2: skipped'
```

3. 打开 WebUI 性能页，确认“调度接管”为 Uperf/外部模块，profile 卡片不可切换。
4. 刷入/启用 Uperf 后，采样 2 分钟确认本模块不再周期性改写 `response_time_ms`、`sched_util_clamp_min`、cpuset、vendor_sched。

### 恢复本模块调度验证

1. WebUI 点击“恢复本模块调度”。
2. 检查 `.cpu_sched_owner=pixel`。
3. 切换 `balanced`，确认:

```sh
cat /sys/devices/system/cpu/cpu0/cpufreq/sched_pixel/response_time_ms
cat /sys/devices/system/cpu/cpu4/cpufreq/sched_pixel/response_time_ms
cat /sys/devices/system/cpu/cpu7/cpufreq/sched_pixel/response_time_ms
cat /proc/sys/kernel/sched_util_clamp_min
cat /dev/cpuset/top-app/cpus
```

预期为 `16/40/200`、cap `0`、top-app `0-7`。

### 回归验证

- WebUI POST 必须带 `Content-Type: application/json`
- `profile.sh` external 状态下 POST profile/policy 返回 `ok:false`
- `ntp.sh` 非 JSON POST 应返回 `415`
- `set_thermal.sh` offset 仅接受 `0/2/4/6`
- `bg_restrict.sh` 包名非法字符应拒绝
- `uecap.sh` Magisk disabled 状态应返回 stub，不 source 缺失文件

## 最终判断

本模块可以与 Uperf Game Turbo 共存，但必须将 CPU 调度接管方设为 `external`，让本模块停止 CPU 调度写入。仅“社区有人能在 Pixel 9 Pro 跑 Uperf”不能证明两套调度可同时接管; 这次补丁解决的是本模块这一侧的抢写问题。外部 Uperf 模块若自身 stop/start PowerHAL 或做其它全局 root 调度操作，本模块无法替它兜底，只能通过 A/B 日志验证实际效果。

在当前代码基础上，建议优先继续做三件事:

1. 对 WebUI token bootstrap 做本机 App 威胁模型增强。v4.4.6 已做启动轮换，但 BusyBox 静态 WebUI 仍无法彻底隔离本机恶意 App。
2. 为外部调度接管增加一键诊断页，展示四类调度节点最近值和本模块是否写入。
3. 为 VM 参数增加原始值 baseline，恢复时不再依赖写死 stock 数值。
