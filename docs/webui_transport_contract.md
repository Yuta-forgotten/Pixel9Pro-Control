# WebUI 请求与运行态接口

## 1. 文档范围

本文档描述 Pixel9Pro-Control WebUI 的浏览器端请求层、CGI 边界和运行态状态合同，供前端、CGI、后台 worker 和问题定位使用。文档以当前源码中的 endpoint、字段和状态机为准，不记录某一次设备读回、发行包或安装环境的临时结果。

接口没有独立的 `/v1` URL 前缀；`webroot/js/runtime.js` 中的 `API` 对象是路径注册表，CGI 脚本是字段和状态的最终校验者。新增字段应保持已有字段含义不变；改变字段含义或状态迁移规则时，应同步更新本文档和对应前端解析逻辑。

## 2. 运行时拓扑

```text
WebView
  └─ app.js                 页面生命周期、标签页刷新、前后台切换
      └─ feature modules    network / thermal / profile / analytics / memory
          └─ common.js      Request Hub、认证、超时、取消、错误解析
              ├─ 管理器资源页 → ksu.spawn → scripts/cgi_dispatch.sh
              └─ 普通浏览器 → loopback httpd :6210
                  └─ webroot/cgi-bin/*.sh（两条路径共用）
                      └─ Android settings / dumpsys / sysfs / module state
```

### 2.1 组件职责

| 组件 | 职责 | 不负责 |
|---|---|---|
| `app.js` | 初始化、标签页切换、前后台生命周期、分阶段刷新 | 解释领域字段、直接拼接 CGI 请求 |
| `common.js` | WebUI token、GET 合并、请求队列、优先级、deadline、取消、JSON/HTTP 错误转换 | 领域状态提交和 readback 判断 |
| 领域模块 | 参数映射、状态机、DOM 渲染、提交后 readback | 修改其他领域的后端状态 |
| CGI | loopback/token 校验、JSON 字段校验、资源锁、原子写入、后端 readback | 依赖浏览器维护回滚状态 |
| service/worker | 低频采样、历史写入、待机策略和 receipt | 依赖 WebView 保持运行 |

## 3. HTTP 边界

### 3.1 地址和认证

- HTTP server 只监听 `127.0.0.1:6210`；CGI 通过 `REMOTE_ADDR` 拒绝非 loopback 请求。
- GET 与 POST 都要求有效会话 token；普通浏览器通过 `X-PIXEL9PRO-TOKEN` 传递，管理器调用映射到同名 CGI 环境字段。
- POST 必须同时满足 `Content-Type: application/json`、有效 `Content-Length` 和 `X-PIXEL9PRO-TOKEN`。
- JSON body 必须是对象，并受各 CGI 的字节上限约束；缺失、截断或超限分别返回 `400` 或 `413`。
- 回环地址不是客户端身份。`auth.sh` 必须携带已有 token，仅返回会话有效性。管理器资源页保留在其可信资源 origin，通过异步 `ksu.spawn` 读取固定 token 并调用白名单 CGI；不把带 root bridge 的页面跳到本地 HTTP listener。APatch 的 `exec(...callback)` 仍有同步 Job.exec，不能仅凭 callback 把它当非阻塞接口。
- `cgi_dispatch.sh` 选择 root 管理器 BusyBox，固定入口、变量单独 shell quote。GET 有 60 秒命令上限，前端排队/正文另有预算；已发出的写事务不因关闭页面或前端超时被杀。原生命令同时最多 3 个，取消后丢弃输出，仅保留有界 exit 回调，收到退出才释放实际槽位。
- 普通浏览器默认以同源 JSON POST `auth.sh action=bootstrap` 一次性自动建立会话。后端从 BusyBox `REMOTE_PORT` 与内核 `/proc/net/tcp{,6}` 的连接四元组取客户端 UID，用 PackageManager 对应 `config/webui_browsers.tsv` 的 user 0 可信浏览器包；同时检查 Host、Origin、bootstrap header 和 Fetch Metadata。User-Agent 不作身份。没有手动 token UI、守护或定时配对。身份不能读取时返回明确错误，页面仅保留“重新连接”按钮，失败不后台循环。

### 3.2 状态码和错误对象

成功读取或成功提交使用 HTTP `200`。错误响应统一为：

```json
{"ok":false,"error":"错误原因","error_code":"HTTP_503"}
```

常见状态码：

| 状态码 | 含义 | 前端处理 |
|---:|---|---|
| 400 | JSON 字段缺失、值非法或 action 不支持 | 显示参数错误，不重试 |
| 403 | 非 loopback 或 token 无效 | 清除失效 token；禁止把请求当作业务失败重试 |
| 404 | CGI 或运行时文件不存在 | 显示安装/版本不匹配 |
| 409 | 事务冲突、owner 不可写、需要重启或当前状态不允许 | 保留后端状态，先 GET readback |
| 415 | POST 不是 `application/json` | 修正请求构造 |
| 422 | 参数通过语法校验但无法生成目标配置 | 显示后端字段，不重试相同请求 |
| 500 | 后端操作或回滚失败 | 显示错误并记录运行日志 |
| 503 | 依赖的 receipt、配置或运行时服务不可用 | 显示依赖状态，允许用户稍后读取 |

HTTP `200` 只表示 CGI 返回了成功响应；对 mutation 而言，前端还必须检查 `ok`、事务字段和随后 GET readback，不能只依据 HTTP 状态或文件存在判断生效。

后端已在锁内写入、复读并提交的回执可以结束弹窗等待；独立补充 GET 在后台核对，失败保留领域提示，不自动重发 POST。关闭弹窗与撤销事务是两个不同操作。调度取消和温控取消遵循相同规则。

### 3.3 配置、历史与恢复

- `state_io_lib.sh` 为小状态文件提供私有随机临时文件、拒绝 symlink/非普通文件、mode、原子替换和复读；它在 subshell 内运行，不覆盖调用者 trap/变量。原子可见性不代表任意断电情况下 fsync 持久性。
- profile history 使用同一有界 writer lock；worker 清理回执对应 `boot|pid|start_ticks` 的本次 run，不能复用旧 run 的成功。
- NR 临时降级在写 Settings 之前保存 before/applied/key；恢复时比较 slot0，保留其它 SIM。持久 Settings 的恢复依据跨重启保留，没有 lease 时不把 33 当捕获的原值。没有额外轮询或新的驻留进程。
- BG 策略固定 device owner user 0，最多 32 个包；CGI、worker、启动应用共用锁。POST 前捕获实际 bucket/AppOps 和受影响文件，失败恢复请求前值；中断 journal 要求显式 recover。自动 worker 遇到未完成 journal 暂停该策略，升级遇到未处理事务拒绝覆盖。
- BG GET 只返回同 boot 的最后一次已验证观察并标注 `last_verified/observed_at`，不逐包调用 Binder/dumpsys。刷新是只读；恢复是单独显式 action。页面不得把保存成功、历史停止记录或旧观察显示为当前已生效。
- 温度 GET 无本次有效样本返回 503；历史读取失败不是空历史。诊断仅展示同 boot/worker 的采样和 kernel last-failure 事实，不从设备名/errno推定 AOD、网络或基带根因。
- 模块卡片 description 是从保存配置派生的单行摘要，仅在启动恢复和配置请求后更新，保留其它 module.prop 字段。`updateJson` 由维护者提供有效清单，APatch 不自动生成；当前未配置在线更新地址。

## 4. 浏览器请求调度

### 4.1 Request Hub

`common.js` 中的 Request Hub 对所有 `apiFetch()` 请求统一调度：

- 最多同时运行 3 个请求。
- 排队最多 24 个；超限返回 `REQUEST_QUEUE_FULL`，不自动重试写入。重复 GET 合并在容量检查之前进行。
- 普通慢诊断 `diagnostic` GET 最多 1 个在途，避免同时占满通信槽；交互 readback 不受此限流影响，仍受全局并发和独立 deadline 约束。
- 无 mutation 的 GET 默认可按完整 URL 合并；带自定义 `controller` 或 `dedupe:false` 的请求不合并。
- `interactive` GET 优先级为 90，`interactive` POST 为 100，`normal` 为 50，`background` 为 10。
- mutation 同时按 `scope` 和 CGI pathname 串行并保持同资源的入队次序；写前取消同资源旧 GET、清除其去重项，写后的 GET 等先前写入终态，避免复用旧状态；失败修改不自动重试。
- mutation 到达时取消可中断的低优先级 GET；已提交 mutation 不因页面隐藏而取消。
- 共享请求类型为 `snapshot/thermalHistory/thermalLive/diagnostic/mutation/lifecycle`，领域可显式传 `requestClass`，不按按钮另建通信队列。兼容已有 `timeoutMs/priority/scope` 覆盖。
- `queueTimeoutMs` 独立限制排队；真正发出后获得完整 `timeoutMs`，覆盖 HTTP header、body 和 JSON 解析。收到 header 不会提前解除 body 限时。
- 队列超时返回 `REQUEST_QUEUE_TIMEOUT`；网络/body 超时为 `REQUEST_TIMEOUT`；主动取消为 `REQUEST_CANCELLED`，替换/隐藏页面保留各自取消码。

### 4.2 页面刷新顺序

全量刷新分为两阶段：

1. CPU、温度、内存等本地状态读取并行。
2. 网络、后台限制和系统信息在第一阶段结束后启动。

网络页内部再次分为：

1. NR、NTP、待机守护短读阶段。
2. UECap、基带状态慢读阶段。

领域模块使用 `runFeatureTask()` 合并同一功能的重复刷新。页面隐藏会停止轮询、温度历史和临时 burst；恢复可见后重新读取当前标签页。

自动读取连续失败时按领域指数退避，最长为基础周期与 60 秒中的较大值；成功后恢复原周期。主题保存只保留一个在途快照和最新未发送选择。提示仅保留一个活动项及有界定时器；连续相同异常合并计数，本页日志最多 80 条。

### 4.3 前端 deadline

以下数值是当前前端的请求 deadline，表示“前端最多等待多久”，不是 CGI 的服务端 SLA：

| 领域 | 读取 | mutation / readback |
|---|---:|---:|
| NR | 12s | 30s，包含后端 IPC 与失败回滚预算；GET 12s |
| UECap | 30s | 30s；切换校验总窗口 60s，轮询间隔 2s |
| 基带状态 | 20s | 只读 |
| 待机守护 | 12s | POST 30s，GET readback 12s |
| NTP | 12s | POST 30s，GET readback 12s |
| Thermal HAL | 14s | `fresh`/clear 同属 thermalLive；HAL 最多 6s + 1s kill grace，失败回退 sysfs |
| 温度历史 | 8s | 只读本地文件，不触发 HAL、Binder 或采集 |
| Thermal contract | 15s | transaction 30s，readback 15s |
| CPU status | 10s | — |
| Profile compact | 12s | mutation 后用于确认 |
| Profile full | 60s | 后台低优先级读取 |
| Owner arbiter | 20s | POST `tick` |

## 5. 通用状态模型

所有可变领域都区分以下状态：

```text
desired       用户或安装向导要求的值
effective      当前系统或挂载层已经确认的值
pending        已写入事务，但需要后续动作（重启、modem reload 或 readback）
degraded       状态存在，但 source/effective/receipt 校验不完整
error          本次请求失败；不得覆盖上一次 confirmed 状态
```

mutation 的标准流程：

```text
按钮事件
  → 前端校验当前 contract
  → POST + scope lock
  → CGI 校验 body、取得后端锁、原子写入
  → 返回 committed/staged/pending 字段
  → 前端 GET readback
  → confirmed / pending / degraded / error
```

如果进程在原子写入前退出，旧状态保持不变；如果在 journal 写入后退出，下一次 GET 必须依据 journal、boot id、hash 和 effective readback 恢复状态。前端本地的 `prev` 只用于显示，不是回滚依据。

## 6. 网络接口

### 6.1 NR 息屏降级：`/cgi-bin/nr_switch.sh`

| 方法 | 请求 | 主要响应字段 |
|---|---|---|
| GET | 无 | `nr_switch`、`current_mode`、`current_slot0`、`actual_rat`、`saved_nr_mode`、`screen_off_delay_s`、`restore_cooldown_s`、`lte_recheck_s`、`lte_mode` |
| POST | `{"action":"toggle"}` 或 `{"action":"set","enabled":"on\|off"}` | `ok`、`nr_switch`；失败返回错误对象 |

POST 先取得 `nr_switch` 锁，并与 worker 共用 `nr_policy` 事务锁；worker 取锁后复读总开关与 NR 选择，不能在用户关闭后继续提交旧的 LTE 决定。关闭策略时只恢复保存的 slot 0，保留当前 slot 1；恢复失败时回滚并返回 `500`。已关闭策略再次关闭不会改写用户手动选择。前端只有 GET 回读一致时才显示成功。

### 6.2 UECap：`/cgi-bin/uecap.sh`

| 方法 | 请求 | 主要响应字段 |
|---|---|---|
| GET | 无 | `uecap_contract`、`policy`、`requested_mode`、`active_mode`、各 mode hash、`target_hash`、`runtime_receipt`、`backend`、`reinstall_required`、无线观察字段 |
| POST | `{"policy":"managed_profiles\|single_candidate","mode":"..."}` | `ok`、`reloading`、`applied`、`reboot_required`，以及最新状态对象 |

`uecap_contract.mode_order` 和 `default_mode` 决定前端可显示的按钮，前端不得硬编码 SKU 可用档位。POST 返回：

- `ok:true`：配置请求接受；若 `reloading:true`，前端轮询 GET 直到 requested、active 和 hash 一致。
- `ok:true,reboot_required:true`：Hybrid Mount staging 已提交，重启后才可确认 effective `/vendor`。
- HTTP `500` 且 `applied:true`：目标配置已写入，但 modem reload 失败；前端显示待复查，不回滚为旧选择。
- HTTP `409`：运行期不可写，例如 content image backend 要求卸载、重启和重新安装。

Hybrid staging 的 binary source、baseline、content/backend 及选择/原因/重启 markers 使用同一快照事务。后续任一写入失败恢复并复读旧 source 和状态；回滚不完整时保留 journal 并明确返回错误，不让 HTTP 失败悄悄改变下次启动的配置。

### 6.3 基带状态：`/cgi-bin/check_baseband.sh`

GET 只读独立基带模块的 `source`、`effective_path`、content image、hash、mount、receipt、CarrierSettings、MCFG 和 IMS properties。Control 不在此接口挂载、复制、修复或接管基带模块。`installed` 表示目录存在；`runtime_verified` 只有在当前 boot 的 receipt、effective contract 和必要 content 状态全部满足时才为 true。

### 6.4 待机守护：`/cgi-bin/standby_guard.sh`

GET 返回 `sim2_auto_manage`、`idle_isolate_mode`、低频 worker 快照，以及 `/sys/power/suspend_stats` 的最近失败设备、errno、step、分类码和人类可读原因。POST 接受 `sim2_auto_manage`、`idle_isolate_mode` 的 `on/off` 字段。

`idle_isolate_mode=on` 保留旧字段的反向语义：后台总开关关闭，温度记录和所有自动策略均暂停；`off` 表示允许后台工作。此接口不控制第三方模块或已经挂载的静态配置。

POST 使用 `standby_guard` 锁，保存意愿后调用共享生命周期管理器。`background_enabled` 是用户意愿；`background_state=starting/running/stopping/paused/stopped` 是经 boot ID、PID、start ticks 核对的实际进程状态；`final=false` 表示尚未达到目标终态。停止先 TERM 并有界等待，允许当前事务完成验证/回滚，不发送 KILL。启动失败恢复旧意愿与生命周期；前端 GET readback 校验开关值和终态，不能只按标志文件宣布成功。

`background_cleanup=ok/failed/none` 单独说明当前 boot 的停止收尾。进程已停但 NR/组播临时策略恢复失败时返回 HTTP 500、`committed=true`，保留暂停意愿并显示恢复失败，不为了掩盖失败而重新开启后台。

### 6.5 NTP：`/cgi-bin/ntp.sh`

| 方法 | 请求 | 主要响应字段 |
|---|---|---|
| GET | 无 | `ntp_server`、`default_server`、`auto_time`、`device_time`、`servers[]` |
| POST | `{"server":"允许列表值"}` 或 `{"action":"sync"}` | `ok`、`ntp_server`、`refreshed`、`device_time` |

服务器必须来自后端 allowlist。更新系统设置后会立即复读；持久化失败时恢复旧系统值和模块保存值。`refreshed:false` 表示服务器已切换但即时同步未完成，不等同于切换失败。

GET 保留实际的未托管 host，`ntp_server_allowed` 表示是否在目录中。未设置显式服务器时 `ntp_server` 为空、`ntp_server_source=system_default`；目录默认值仍单独位于 `default_server`，不得当成已读回的系统实际值。

## 7. 温控接口

### 7.1 实时温度：`/cgi-bin/thermal.sh`

- `GET` 返回热区数组 `[{"zone":"...","temp":整数毫摄氏度}]`；普通读取优先使用 worker 维护的 `.thermal_cache.json`。
- `GET ?fresh=1` 绕过有效缓存执行一次 Thermal HAL 读取。
- `GET ?history=1&sensor=module|battery&start_ts=epoch&end_ts=epoch` 只读本地温度历史，区间最长 7 天；兼容 `minutes=1..10080`。
- 历史响应返回 `ok/schema/sensor/points[]/raw_samples/valid_samples/coverage_sec/coverage_ratio/gap_count/quality/updated_at/data_revision/recording_enabled/recording_state/time_unit/temperature_unit`。每点含 `ts/temp_mc/sensor/source/screen/expected_interval_sec/boot_id/session_id/quality/valid`。单位为毫摄氏度和 Unix 秒；机身与电池不混合计数。
- 实时读取成功时仅在后台总开关允许时通过共享写入器记录，每传感器至少间隔 60 秒；复用缓存沿用实际测量时间，不把旧值改成新采样。总开关关闭不隐藏旧历史，也不禁止明确的手动实时读取。
- `POST {"action":"clear"}` 在 `thermal_cache` 锁内清除缓存，随后在同一请求内执行有界实时读取；它是显式认证操作，不是 GET 失败的自动修复路径。

前端只接受温度在有效范围内且包含 `VIRTUAL-SKIN` 或 `SKIN` 的响应。一次普通刷新只发一次 GET，失败保留上次确认读数并显示错误；不隐式发 fresh 或 POST clear。前台温度读取和 contract retry 在页面隐藏时取消/停止；mutation 后的交互 readback 使用独立任务和优先级，不能被普通在途 GET 当作旧缓存合并。

### 7.2 温控状态与 transaction：`/cgi-bin/set_thermal.sh`

GET 返回 `policy`、`offset`、`thermal_contract`、`mount_backend`、`source_hash`、`effective_hash`、`source_context`、`effective_context`、`pending`、`pending_id`、`cancel_supported`、`reboot_required`、`effective_state`、`repair_required` 和 `reinstall_required`。

POST 请求：

| body | 作用 |
|---|---|
| `{"policy":"system"}` | 移除 overlay，使用系统温控配置 |
| `{"policy":"custom","offset":整数}` | 按 contract 生成并 staging 自定义配置 |
| `{"action":"repair_system"}` | 清理可验证的旧状态并恢复 system 基线 |
| `{"action":"cancel_pending","pending_id":"..."}` | 同一 boot 且基线有效时撤销 staged transaction |

`effective_state` 的含义：

| 值 | 含义 |
|---|---|
| `effective` | 当前 policy 与 effective path/hash/context 已确认 |
| `pending_reboot` | journal 已 staging，等待重启后由挂载层生效 |
| `restored_pending_readback` | 撤销已提交，下一次 GET 仍需完成 effective readback |
| `repair_pending` | 修复已提交，需重启或后续 GET 确认 |
| `degraded` | 有状态或 journal，但当前有效路径未完成确认 |

第二次温控 mutation 在 pending transaction 存在时返回 `409 pending_change_exists`。取消只能使用后端返回的当前 `pending_id`；跨 boot 或 baseline/hash 不一致时后端拒绝撤销。

取消恢复本身也保存取消前的 desired source 和 markers；恢复或清理失败时补偿回原 desired 状态，保留可重试 journal。补偿失败明确返回 rollback incomplete，而不是把部分恢复当成完成。升级缺少同 build stock provenance 时拒绝从仍受覆盖的 vendor 路径重采；disable 标记不代表挂载已卸除。

温控 POST 已在后端完成 source/marker 恢复与提交后，前端立即反馈并关闭等待；独立 GET 只在后台补充状态，不作为关闭条件。事务处理中允许关闭弹窗、返回和切换页面，仅禁止重复提交同一动作。回读失败保留状态说明，不强制重新打开弹窗、不重复 POST。若 POST 响应丢失，用户重试先 GET 判断当前 journal，再决定是否提交。补充读取绑定 mutation revision，旧响应不能覆盖新操作或关闭另一领域的弹窗。

用户关闭保存进度后，后台完成不得自行重开弹窗。温控页提供待处理变更入口，用户可主动重新查看保存、撤销进度或待重启变更。

### 7.3 后台限制提交

`bg_restrict.sh` POST 在事务提交后返回 compact `ok/committed/enabled/action`，不在响应末尾重新做完整 per-package Binder/pm 扫描。前端在独立 GET 完成前显示“已提交，回读未确认”并暂停继续写入；刷新只读回，不重复 POST。首次隐藏加载时，应用恢复可见后补完未完成的初始化数据阶段，不重复绑定 UI 事件。

## 8. 调度与 owner 接口

### 8.1 CPU 观察：`/cgi-bin/status.sh`

GET 返回 cpu0、cpu4、cpu7 三个 cluster 的 `cur`、`min`、`max`、`gov`、`sched_pixel_available`、`resp_ms`、`down_us` 及对应可用性字段。`resp_ms_text` 和 `down_us_text` 用于区分 `N/A` 与数值 0；前端不得把不可用字段渲染成有效的零值。

### 8.2 Profile 与 scheduler owner：`/cgi-bin/profile.sh`

GET 不带 `compact=1` 返回完整状态：profile、policy、desired/effective owner、外部 scheduler 探测、CPU contract、`scheduler_boot`、`scheduler_health` 和 profile transition。`GET ?compact=1` 只返回 mutation readback 所需的 profile/owner、boot 和 health 摘要。

POST 接受 profile、policy、`sched_owner`、`game_handoff`、`scheduler_mode=off`、`scheduler_action=retry|cancel_pending`。响应使用以下字段描述异步程度：

- `ok`：本次后端事务是否成功结束。
- `accepted`：请求是否已经被事务接受。
- `final`：本次响应是否已经到达终态；`false` 时必须等待后续 readback。
- `reboot_required`：是否必须重启才能完成 owner 或 scheduler mode 变更。
- `scheduler_boot.phase`：当前启动模式事务阶段。
- `scheduler_health.status`：当前控制面健康状态；`deferred` 表示 owner transition lock 正在保护状态。

profile/策略 POST 已在锁内提交并复读后，前端依据回执立即结束等待，compact/full GET 在后台补充，不作为按钮完成条件。full GET 被取消或超时不应覆盖已经确认的 mutation state。

### 8.1 CPU策略与owner请求预算

- CPU 自动/手动切换在同一策略下幂等返回；仅目标 profile 不同时应用一次 CPU 事务。不因策略切换修复系统后续合法回写。历史不再同步等待 Thermal HAL dump，history/description 的附加工作均脱离 CGI 标准流，提交确认不依赖第二次 GET。
- `sbm_load_state/stg_load` 对每个文件单次 Shell read 解析；禁止重新退回每字段多进程 sed/head/tr 热路径。helper parser 变量不得覆盖上层 transition key。
- `scheduler_action=retry`、`game_handoff` 与手动 owner tick 返回 `accepted=true/final=false`，由 `scheduler_async_worker.sh` 完成一次有限任务；不是常驻轮询。`scheduler_operation` 包含 id/kind/phase/pending/result_code。UI 显示已接受并允许离开，由既有 compact GET 查询结果；同一任务进行中拒绝新调度 mutation。
- `queued/running` 绑定 boot 与实际 process owner，已死/重启后的任务显示 unconfirmed，不能伪完成或自动重放；success/failed/deferred 为可观察结果。失败/延后需要用户结合当前状态决定下一步。
- Pixel/UGT staging/取消保留同步的持久状态事务；前台 APD 采用单次有界尝试，list/set 分别 2s/3s，回滚仍需读回。重新验证内部的90s观察预算不再计入前台请求等待。
- POST 的 `duration_ms` 和低频策略事件用于定位用户真实点击；不自动反复切换策略来产出性能数字。参数未改变与历史缺测必须分别表示，不能把 exit 0 当权威 runtime。

### 8.3 fas-rs owner tick：`/cgi-bin/owner_arbiter.sh`

POST `{"action":"tick"}` 需要 token、owner arbiter lock、fas-rs 检测结果及有效游戏 handoff 或 lease。返回 `ok/accepted=true`、`final=false` 与 `scheduler_operation`，亮屏检查和协调在一次性后台任务执行。非交互态任务记为 deferred，不执行 owner mutation；未检测到 fas-rs 或没有 handoff/lease 仍为 `409`。结果通过既有 profile GET 读取，不增加专门轮询。

## 9. 温度历史生命周期

历史页面仅使用 7.1 的温度历史接口，不读取功耗、BatteryStats 或软件排行。总开关开启时，worker 在亮屏约每 60 秒、息屏约每 900 秒尝试采样；内核休眠允许延后。前台新测量值也通过同一总开关和写入器记录，避免长睡眠阻塞首次亮屏记录。关闭总开关停止 worker 及历史写入；只读 httpd 仍可服务查询与手动操作。

共享写入器按传感器限频，使用无等待目录锁，失效锁在跨 boot 或超时后回收；不持 wakelock、不注册 alarm。历史读取不请求 Binder、不遍历归因快照、不启动采集器。兼容旧两列 CSV 及第 11 列存采样周期的旧记录；不可用的传感器保持缺失。

worker 和历史写入器共用 boot ID/PID/start ticks 身份校验。关闭总开关还会等待已在途的前台历史写入结束；不能只看到 worker 已退出就发布 paused/final=true。GET 完成时先移除去重项再通知消费者，后续 readback 必须得到新响应。各层刷新在 await 后重新检查页面前台状态，不在页面隐藏后开启新的自动读取阶段。

### 9.1 运行代码职责

| 文件 | 直接消费者 | 责任与边界 |
|---|---|---|
| `runtime_defaults_lib.sh` 等现有领域库 | installer/service/领域 CGI | 继续维护原有默认值、NR、VM、调度、温控事务；不重写既有安全机制 |
| `background_tasks_lib.sh` | service、standby CGI、历史写入器 | 唯一最高开关、共享进程身份、启停和收尾状态；无自身循环 |
| `control_worker_lib.sh` | `service.sh --background-worker` | 从 service 提取的自动工作体；不是新增第二个服务或通用库框架 |
| `thermal_history_lib.sh` | thermal CGI、worker | 代替已删除的功耗 telemetry 混合写入路径；唯一限频温度追加器，无独立进程 |
| `common.js` | 所有前端领域模块 | 继续复用原有 Request Hub；分类 admission/deadline/取消/认证/错误统一处理 |
| `analytics_model/view/analytics.js` | 温度历史页 | 分别负责纯分析/导出、呈现、生命周期；不另造请求框架 |

没有新增第三方依赖。`tests/` 中进程/温度 fixture 是受控反例，不是生产库；实际 `tools/release_contract.py` 明确排除 tests/tools/logs/tmp。发行必需条目与上述新共享组件和退役功耗条目同步，避免入口删掉但打包仍要求旧文件。

### 9.2 温度导出

前端 `analyticsModel.exportHistory(payload, format)` 仅序列化已确认响应，支持 `csv/json`；不另发采集请求或恢复后台。CSV 为 UTF-8、CRLF、逗号分隔，列名自带时间/温度单位，引用含逗号/引号/换行的字段并防止公式注入。JSON schema 为 `pixel9pro.temperature_history.v1`，包含单位、UTC 时间、查询边界、采样策略、记录开关、revision、采样均值和 points。两种格式均保留来源、屏幕状态、boot ID、有效性和 `gap_before_sec`。缺测不补零、不补线；暂停时允许导出已有数据，空窗口允许导出空文档/表头。

## 10. 维护规则

1. 新增字段先在 CGI 输出和前端解析处定义，再补充本文档；未知字段必须可被旧前端忽略。
2. 改变状态含义、锁范围、readback 顺序或 timeout 时，同时更新对应领域模块和本文件。
3. 任何 mutation 都必须有后端 owner、原子写入或 journal、失败恢复路径和可验证 readback。
4. 日志记录 endpoint、phase、result、reason code 和耗时；不得记录 token、请求体、ADB 地址、IMEI/IMSI、完整 fingerprint 或原始 dumpsys。
5. 源码审查、构建审查和设备回读分别记录；HTTP `200`、静态构建成功或 ADB 已连接都不能单独证明运行态功能已生效。

## 11. 配置、运行态和日志的保存边界

- `install_state_lib.sh` 是升级保留清单的唯一入口，将 preferences、recovery、history 分开；领域值、默认值与校验仍由原有领域库负责，不维护第二份参数表。
- 升级逐文件在 staging 目录内原子复制并比较原始字节，拒绝 symlink、非普通文件、未知高版本 schema 和异常大文件；失败中止 staging，保留旧 active 目录。当前支持的 performance 用户选择不降级。
- token、锁、PID、worker readiness、effective receipts 不迁移。恢复用旧状态只作 recovery 输入，不能冒充本 boot 的 effective 事实。温度历史有七天及行数双重边界，低频小文件同样执行过期清理。
- 本轮保留现有模块路径 ABI 与管理器升级迁移入口，没有将所有文件搬入 `/dev`，也没有绕开 Hybrid Mount 改写当前 `/vendor`。有界原子 rename 防止读取半文件，不承诺任意断电下的完整持久性；常规策略/日志不执行全盘 `sync`。
- `audit_log_lib.sh` 统一 event、clear、snapshot 的有界锁；锁身份包含 boot ID/PID/start ticks。私有目录 0700、文件 0600，单文件默认 256KiB、保留 3 个当前轮转及 4 个有大小上限的日期归档，单个字段与查询行数也有上限。
- 审计接口普通 tail 最多 100 行，`all=1` 最多 2000 行。读取保持路径逐个引用；轮转、清理和读取使用同一锁，繁忙或无法读取返回 503，不回假空记录。
- lifecycle、domain transaction、HTTP failure 使用受控 reason code；不写 raw request、token 或设备标识。CGI 补充审计及 reboot 子进程在外层重定向全部标准流，避免继承 HTTPD 管道而拖延响应。
- `post-fs-data` 保持只读观测，不等待 Android framework、用户解锁或 WebUI；`service` 的开机等待是非阻塞启动阶段的有界等待。HTTPD 端口冲突不报成功，也不阻断独立后台策略；不强制 SELinux permissive、不修改根 cgroup 或 OOM 优先级。
