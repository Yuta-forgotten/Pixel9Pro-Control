# WebUI 请求与运行态接口

## 1. 文档范围

本文档描述 Pixel9Pro-Control WebUI 的浏览器端请求层、CGI 边界和运行态状态合同，供前端、CGI、后台 worker 和问题定位使用。文档以当前源码中的 endpoint、字段和状态机为准，不记录某一次设备读回、发行包或安装环境的临时结果。

接口没有独立的 `/v1` URL 前缀；`webroot/runtime.js` 中的 `API` 对象是路径注册表，CGI 脚本是字段和状态的最终校验者。新增字段应保持已有字段含义不变；改变字段含义或状态迁移规则时，应同步更新本文档和对应前端解析逻辑。

## 2. 运行时拓扑

```text
WebView
  └─ app.js                 页面生命周期、标签页刷新、前后台切换
      └─ feature modules    network / thermal / profile / analytics / memory
          └─ common.js      Request Hub、认证、超时、取消、错误解析
              └─ loopback httpd :6210
                  └─ webroot/cgi-bin/*.sh
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
- GET 读取接口不要求 token，但浏览器会在已有会话中附带 `X-PIXEL9PRO-TOKEN`。
- POST 必须同时满足 `Content-Type: application/json`、有效 `Content-Length` 和 `X-PIXEL9PRO-TOKEN`。
- JSON body 必须是对象，并受各 CGI 的字节上限约束；缺失、截断或超限分别返回 `400` 或 `413`。
- `auth.sh` 只提供当前 WebUI token 的 loopback 读取，不承担业务状态认证之外的授权。

### 3.2 状态码和错误对象

成功读取或成功提交使用 HTTP `200`。错误响应统一为：

```json
{"ok":false,"error":"错误原因"}
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

## 4. 浏览器请求调度

### 4.1 Request Hub

`common.js` 中的 Request Hub 对所有 `apiFetch()` 请求统一调度：

- 最多同时运行 3 个请求。
- 无 mutation 的 GET 默认可按完整 URL 合并；带自定义 `controller` 或 `dedupe:false` 的请求不合并。
- `interactive` GET 优先级为 90，`interactive` POST 为 100，`normal` 为 50，`background` 为 10。
- mutation 按 `scope` 串行；同一 scope 的前一个 mutation 未释放时，后一个不能启动。
- mutation 到达时取消可中断的低优先级 GET；已提交 mutation 不因页面隐藏而取消。
- deadline 从进入队列开始计算，包含排队、HTTP header、response body 和 JSON 解析时间。
- 队列超时返回 `REQUEST_TIMEOUT`；AbortController 取消返回 `REQUEST_CANCELLED`、`REQUEST_SUPERSEDED` 或领域传入的取消原因。
- CGI body 读取也受同一 deadline 约束，不能因已收到 HTTP header 而无限占用通信槽。

### 4.2 页面刷新顺序

全量刷新分为两阶段：

1. CPU、温度、内存等本地状态读取并行。
2. 网络、后台限制和系统信息在第一阶段结束后启动。

网络页内部再次分为：

1. NR、NTP、待机守护短读阶段。
2. UECap、基带状态慢读阶段。

领域模块使用 `runFeatureTask()` 合并同一功能的重复刷新。页面隐藏会停止轮询、温度历史和临时 burst；恢复可见后重新读取当前标签页。

### 4.3 前端 deadline

以下数值是当前前端的请求 deadline，表示“前端最多等待多久”，不是 CGI 的服务端 SLA：

| 领域 | 读取 | mutation / readback |
|---|---:|---:|
| NR | 12s | 15s，提交后 GET 12s |
| UECap | 30s | 30s；切换校验总窗口 60s，轮询间隔 2s |
| 基带状态 | 20s | 只读 |
| 待机守护 | 12s | POST 15s，GET readback 12s |
| NTP | 12s | POST 15s，GET readback 12s |
| Thermal HAL | 10s | `fresh`/clear 15s |
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

POST 先取得 `nr_switch` 锁。关闭策略时先恢复已保存的 NR-capable mode，再写入状态；恢复失败时后端尝试回滚并返回 `500`。前端只有 GET 回读的 `nr_switch` 与目标值一致时才显示操作成功。

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

### 6.3 基带状态：`/cgi-bin/check_baseband.sh`

GET 只读独立基带模块的 `source`、`effective_path`、content image、hash、mount、receipt、CarrierSettings、MCFG 和 IMS properties。Control 不在此接口挂载、复制、修复或接管基带模块。`installed` 表示目录存在；`runtime_verified` 只有在当前 boot 的 receipt、effective contract 和必要 content 状态全部满足时才为 true。

### 6.4 待机守护：`/cgi-bin/standby_guard.sh`

GET 返回 `sim2_auto_manage`、`idle_isolate_mode`、`analytics_enabled`、`background_mode`、低频 worker 快照，以及 `/sys/power/suspend_stats` 的最近失败设备、errno、step、分类码和人类可读原因。POST 接受 `sim2_auto_manage`、`idle_isolate_mode` 的 `on/off` 字段。

POST 使用 policy lock；后台观测开关同时更新历史 policy 并停止或恢复 module observers。失败时恢复开关文件、历史配置和 observer 状态；前端以 GET readback 判断开关是否真正生效。

### 6.5 NTP：`/cgi-bin/ntp.sh`

| 方法 | 请求 | 主要响应字段 |
|---|---|---|
| GET | 无 | `ntp_server`、`default_server`、`auto_time`、`device_time`、`servers[]` |
| POST | `{"server":"允许列表值"}` 或 `{"action":"sync"}` | `ok`、`ntp_server`、`refreshed`、`device_time` |

服务器必须来自后端 allowlist。更新系统设置后会立即复读；持久化失败时恢复旧系统值和模块保存值。`refreshed:false` 表示服务器已切换但即时同步未完成，不等同于切换失败。

## 7. 温控接口

### 7.1 实时温度：`/cgi-bin/thermal.sh`

- `GET` 返回热区数组 `[{"zone":"...","temp":整数毫摄氏度}]`；普通读取优先使用 worker 维护的 `.thermal_cache.json`。
- `GET ?fresh=1` 绕过有效缓存执行一次 Thermal HAL 读取。
- `GET ?history=1&minutes=N` 返回 `{"points":[[epoch,temp],...]}`；`N` 的有效范围由 CGI 限制在 1–720 分钟。
- `POST {"action":"clear"}` 在 `thermal_cache` 锁内原子清除缓存，随后由下一次读取重建。

前端只接受温度在有效范围内且包含 `VIRTUAL-SKIN` 或 `SKIN` 的响应；普通读取异常时依次尝试 fresh 和缓存清理，不用空数组覆盖有效界面状态。

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

### 7.3 前台临时采样：`/cgi-bin/thermal_burst.sh`

GET 返回 `burst_active` 和 `burst_until`。POST 接受 `{"action":"start","duration_sec":60|120|300|600}` 或 `{"action":"stop"}`。该标记只允许前台亮屏采样路径使用；service 在息屏时强制忽略 burst，避免临时高频读取影响 suspend。

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

Profile mutation 的前端顺序是 POST → `profile.sh?compact=1` →（确认后）后台 full GET。full GET 被取消或超时不应覆盖已经确认的 compact mutation state。

### 8.3 fas-rs owner tick：`/cgi-bin/owner_arbiter.sh`

POST `{"action":"tick"}` 需要 token、owner arbiter lock、fas-rs 检测结果、亮屏状态以及有效游戏 handoff 或 lease。成功返回 `screen`、`screen_source`、`output` 和 `state`；未检测到 fas-rs、屏幕未亮或没有有效 lease 时返回 `409`。息屏时不执行 owner arbiter tick。

## 9. 历史与功耗接口

历史页面使用以下只读或显式提交接口：

| 接口 | 用途 | 关键约束 |
|---|---|---|
| `/cgi-bin/energy.sh` | 实时功耗摘要和模块 ledger | `?fast=1` 为快速摘要 |
| `/cgi-bin/system_history.sh` | Android BatteryStats 系统历史 | `start_ts/end_ts` 不超过 7 天；缺测返回 gap，不补零 |
| `/cgi-bin/power_rank.sh` | 软件耗电排行 | 时间窗不超过 7 天；需要有效连续快照，不能用累计总计冒充窗口归因 |
| `/cgi-bin/history_policy.sh` | 后台记录、保留和采样策略 | mutation 后必须 GET readback |
| `/cgi-bin/history_export.sh` | 导出选定窗口 | dataset、时间戳和范围由后端校验 |
| `/cgi-bin/telemetry.sh` | 前台显式低功耗记录 | 后台观测开启时拒绝冲突 session |

后台记录关闭后，service 停止历史、归因和 telemetry 写入；已经存在的文件仍可由前台读取或导出。息屏 recorder 只使用低频 sysfs 电池/温度路径，不启动 Thermal HAL、BatteryStats、Top 进程或 owner arbiter 轮询。

## 10. 维护规则

1. 新增字段先在 CGI 输出和前端解析处定义，再补充本文档；未知字段必须可被旧前端忽略。
2. 改变状态含义、锁范围、readback 顺序或 timeout 时，同时更新对应领域模块和本文件。
3. 任何 mutation 都必须有后端 owner、原子写入或 journal、失败恢复路径和可验证 readback。
4. 日志记录 endpoint、phase、result、reason code 和耗时；不得记录 token、请求体、ADB 地址、IMEI/IMSI、完整 fingerprint 或原始 dumpsys。
5. 源码审查、构建审查和设备回读分别记录；HTTP `200`、静态构建成功或 ADB 已连接都不能单独证明运行态功能已生效。
