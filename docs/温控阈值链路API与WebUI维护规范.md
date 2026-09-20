# Pixel9Pro-Control 温控/阈值链路 API 与 WebUI 维护规范

状态：当前源码维护契约，不是稳定版认证
适用模块：`pixel9pro_control`
适用设备：`caiman`、`komodo`（按 SKU contract 分流）
适用后端：`hybrid_mount`、`metamodule_content`、Magisk read-only UECap
维护原则：先读当前 contract 和运行态，再改 consumer；禁止让 UI、CGI、installer 各自维护一份阈值或状态定义。

## 1. 目的与范围

本文是温控阈值链路的代码维护入口，供后续 WebUI、CGI、installer、A/B slot 和设备验收使用。它定义：

- 温控参数与 stock 基线的唯一来源；
- `thermal_profile.sh`、`thermal_policy_lib.sh`、`slot_transaction_lib.sh` 的函数契约；
- installer、`post-fs-data.sh`、Hybrid Mount、`post-mount.sh`、service 的生命周期边界；
- `set_thermal.sh`、`thermal.sh`、`reboot.sh` 的 HTTP 输入输出和错误语义；
- WebUI `thermal.js`、`common.js`、`ui.js` 的状态、轮询和重启确认约束；
- source、pending、active slot、effective `/vendor`、receipt 五层状态的显示规则；
- failure injection、设备 smoke 和发布前检查清单。

本文不授权直接修改设备 `/vendor`、MetaModule image、Hybrid Mount 外部配置或 SELinux policy。需要设备变更时，仍须遵守项目 `AGENTS.md` 的 preflight、写入、权威复读、持久 marker、失败回滚和回滚复读流程。

## 2. 真值与所有权

### 2.1 真值优先级

冲突时按以下顺序判断：

1. 当前 boot 的 effective `/vendor`、mountinfo、SELinux context、ThermalHAL、same-boot receipt；
2. 当前源码 contract 和生产测试；
3. installer staging、A/B manifest、模块状态文件；
4. `module.prop`、`versions.prop`、构建器和 ZIP 审计；
5. README、历史复盘和旧版本行为。

“文件存在”“生成成功”“ZIP hash 一致”“HTTP 200”“命令 exit 0”都不能单独表示温控已经生效。

### 2.2 所有权边界

| 对象 | 唯一 owner | 允许 consumer | 禁止行为 |
|---|---|---|---|
| 温控 offset/policy contract | `scripts/thermal_profile.sh` + `thermal_policy_lib.sh` | installer、CGI、WebUI、tests | 在 JS/README/installer 复制数值表 |
| 当前设备 stock thermal | 当前 Build 的 `/vendor/etc/thermal_info_config.json`，或经过校验的模块私有 snapshot | generator、readback | 使用旧 Build、另一 SKU 或旧候选作为 stock |
| Hybrid pending/slot | `slot_transaction_lib.sh` | `set_thermal.sh`、installer、post-fs-data、post-mount | WebUI 直接写 `/vendor` 或 active slot |
| 有效 thermal `/vendor` | Hybrid/MetaModule 挂载后实际路径 | post-mount、status、receipt | 把 module source 当 effective |
| UECap payload | `uecap_profile.sh` + `config/uecap_*.tsv` | installer、post-mount、UECap CGI、WebUI | 改名跨 SKU、复用 baseband payload |
| 后台结构化日志 | `scripts/audit_log_lib.sh` | CGI、service、WebUI 导出 | 写 token、原始 body、IMEI、serial、完整 logcat |

## 3. 端到端状态机

温控 custom 的标准路径：

```text
用户选择 policy/offset
  -> WebUI POST /cgi-bin/set_thermal.sh
  -> loopback + token + JSON + lock
  -> 从当前 SKU stock snapshot 生成 candidate
  -> JSON/传感器/threshold/hysteresis 校验
  -> 写 inactive slot payload/manifest
  -> 原子提交 pending=slot-a|slot-b
  -> 返回 pending_reboot
  -> 用户确认后调用 POST /cgi-bin/reboot.sh
  -> post-fs-data.sh 在 Hybrid Mount 扫描前 promotion
  -> Hybrid Mount 按外部规则选择 ignore/overlay/magicmount/VFS
  -> post-mount.sh 读取 source/effective/context/mount topology
  -> verified: active + last-good + receipt=current_boot
  -> failed: rollback_pending + receipt=unverified
  -> 下一次启动恢复 last-good；新的 pending 可覆盖旧失败 marker
```

### 3.1 五层状态不可混淆

| 层 | 典型路径 | 含义 | UI 语义 |
|---|---|---|---|
| source | `/data/adb/modules/pixel9pro_control/system/vendor/etc/thermal_info_config.json` | regular module source 当前文件 | `source ready` |
| pending | `/data/adb/pixel9pro_control/slots/thermal/pending` | 下一次启动要 promotion 的 slot | `待重启` |
| active slot | `slots/thermal/active` | 最近一次 promotion 的 slot | `active slot` |
| effective | `/vendor/etc/thermal_info_config.json` | ThermalHAL 实际读取的文件 | `当前有效` |
| receipt | `.thermal_runtime_receipt` | 当前 boot 的 readback 结论 | `verified/failed` |

只有 effective context、effective hash、mount backend 和 receipt 同时通过，才可显示“已生效”。

## 4. 参数 Contract

### 4.1 `scripts/thermal_profile.sh`

当前 contract 常量：

```text
THERMAL_ALLOWED_OFFSETS = -2 0 2 4 6
THERMAL_UI_OFFSETS      = -2 2 4 6
THERMAL_DEFAULT_OFFSET  = 2
THERMAL_ALLOWED_POLICIES = system custom
THERMAL_DEFAULT_POLICY = system
THERMAL_TARGET_SENSOR_COUNT = 8
THERMAL_SEVERITY_SLOT_COUNT = 7
THERMAL_SHUTDOWN_SLOT = 7
THERMAL_MIN_SEVERITY_GAP_C = 0.5
THERMAL_STRICT_MARGIN_C = 0.1
```

`0` 保留为 runtime/legacy 合法值，但不作为独立 custom UI card；UI 的 stock 入口是 `policy=system`。如果以后要把 `0` 重新显示为卡片，必须同步 contract、WebUI、CGI、installer、测试和 README，不能只改 JS。

目标 sensor 只能是：

```text
VIRTUAL-SKIN
VIRTUAL-SKIN-HINT
VIRTUAL-SKIN-SOC
VIRTUAL-SKIN-CPU-LIGHT-ODPM
VIRTUAL-SKIN-CPU-MID
VIRTUAL-SKIN-CPU-ODPM
VIRTUAL-SKIN-CPU-HIGH
VIRTUAL-SKIN-GPU
```

### 4.2 函数参考

| 函数 | 输入 | 输出/副作用 | 维护要求 |
|---|---|---|---|
| `thermal_is_valid_offset` | offset 字符串 | `0` 合法，非零非法 | 只读，不写状态 |
| `thermal_normalize_offset` | value、fallback | 打印合法 offset | fallback 也必须属于 contract |
| `thermal_print_ui_contract_json` | 无 | 打印 policies/default/offsets JSON | WebUI 只能消费该输出 |
| `thermal_format_offset` | offset | 打印人类可读温度 | 未知值必须失败，不猜默认 |
| `thermal_profile_name` | offset | 打印稳定档位名 | 不在 JS 复制名字作为状态来源 |
| `thermal_generate_config` | stock path、output path、offset | 生成候选 JSON；失败返回非零 | 从 stock 每次重建，不在旧 output 上累加 |

### 4.3 生成器硬门禁

`thermal_generate_config` 必须同时证明：

- source 文件存在且属于当前 SKU/Build baseline；
- JSON 保留合法的字符串 `"NAN"`，禁止裸 `NaN`；
- 8 个目标 sensor 全部出现且只出现一次；
- 每个目标 sensor 的 `HotThreshold` 和 `HotHysteresis` 有 7 个槽位；
- 数值槽位严格递增；
- 最后数值 shutdown 槽位保持 stock；
- `previous_threshold < next_threshold - next_hysteresis`；
- 生成失败不留下 output 或半成品 tmp；
- `mv` 前先完成 hash/结构检查，不能把旧 output 当成功结果。

## 5. Stock 基线与 policy library

文件：`scripts/thermal_policy_lib.sh`

| 函数 | 作用 |
|---|---|
| `thermal_policy_init(root)` | 设置 `.thermal_policy`、`.thermal_offset`、thermal overlay 路径 |
| `thermal_policy_is_valid(policy)` | 只接受 `system/custom` |
| `thermal_policy_read()` | 读取持久 policy；非法值返回 system |
| `thermal_policy_snapshot_path(device)` | 返回 `payloads/thermal/<device>/stock.json` |
| `thermal_policy_validate_stock(path)` | 用 offset=0 的生产 generator 校验 stock |
| `thermal_policy_capture_stock(source,target)` | 校验、复制、权限收紧为 0600、原子提交 snapshot |
| `thermal_policy_prepare_snapshot(device,old_root,allow_vendor)` | 按当前设备优先建立 stock baseline |
| `thermal_policy_remove_overlay()` | 删除模块 source 下的 thermal overlay 及空父目录 |

snapshot 来源顺序必须可审计：

1. 已存在且通过 generator 的当前模块 snapshot；
2. 旧模块中同 SKU 的 verified snapshot；
3. 旧模块的 legacy stock 文件；
4. 明确允许时读取当前 `/vendor/etc/thermal_info_config.json` 并校验后保存。

不可接受的来源：另一 Build、另一 SKU、旧 custom output、未通过完整 generator 的 JSON。

## 6. A/B Slot API

文件：`scripts/slot_transaction_lib.sh`

根目录默认：

```text
/data/adb/pixel9pro_control/slots/
  thermal/
  uecap/
```

每个 component 使用：

```text
slot-a/payload
slot-a/remove       # mode=remove 时的 tombstone
slot-a/manifest
slot-b/...
active
pending             # 可选；值为 slot-a 或 slot-b
last-good           # 通过 effective readback 的 slot
rollback_pending    # 复读失败，要求下一次启动恢复 last-good
promoted            # promotion 记录，成功验证后删除
```

### 6.1 Manifest 字段

```text
component=thermal|uecap
slot=slot-a|slot-b
mode=staged|remove
relative=system/vendor/...
device=caiman|komodo
build=<ro.build.fingerprint>
context=vendor_configs_file|vendor_fw_file
hash=<sha256>|none
created_boot=<boot id>
```

`context` 可以在 manifest 中使用短 contract 名，但 promotion 必须归一化为完整 SELinux context：

```text
vendor_configs_file -> u:object_r:vendor_configs_file:s0
vendor_fw_file      -> u:object_r:vendor_fw_file:s0
```

### 6.2 函数参考

| 函数 | 作用 | 成功条件 |
|---|---|---|
| `slot_init` | 创建 slot root/权限 | root 存在且 0700 尽可能成功 |
| `slot_hash(file)` | SHA-256 | 输出单个 digest |
| `slot_atomic_write(file,value)` | tmp + sync + rename + readback | 文件内容与 value 相同 |
| `slot_lock/slot_unlock` | component 级写锁 | 不能留下无 PID 的永久锁 |
| `slot_current_value(component)` | 读取 active | 只返回 slot-a/slot-b/空 |
| `slot_pending_value(component)` | 读取 pending | 只返回 slot-a/slot-b/空 |
| `slot_inactive_value(component)` | 根据 active 选择另一 slot | active 无效时默认 slot-a |
| `slot_stage_file(component,source,relative,mode,device,build,context)` | 写 inactive payload/manifest 并提交 pending | hash、manifest、pending 全部可复读 |
| `slot_promote_pending(component,target)` | 在 pre-mount promotion source | hash/context/rename/active 全部成功 |
| `slot_mark_verified(component)` | 写 last-good 并清理 promoted/rollback_pending | readback 成功后才调用 |
| `slot_mark_rollback_pending(component)` | 标记本 boot failed | 不修改 active/effective |
| `slot_rollback_pending(component)` | 检测失败 marker | 只读 |
| `slot_rollback_last_good(component,target)` | 恢复 last-good source | 恢复后需再次验证 |

重要规则：

- 只有 `pending` 存在时才拒绝新的同 component mutation；单独的 `rollback_pending` 不得永久阻塞新提交；
- 新的有效 `slot_stage_file` 必须清除旧 `rollback_pending`；
- `slot_mark_verified` 必须清除 `rollback_pending`；
- active slot 只读，不能原地覆盖；
- system policy 也要提交 `mode=remove`，否则旧 custom 文件可能留在 source；
- slot 库不能 mount、bind、写有效 `/vendor` 或修改 Hybrid Mount 外部配置。

## 7. 生命周期脚本

### 7.1 `customize.sh`

installer 负责：

1. 识别 device/root/backend；
2. 初始化并校验 stock baseline；
3. 读取/migrate 用户 policy/offset；
4. 生成 custom candidate 或删除 system overlay；
5. Hybrid 下调用 `slot_stage_file thermal ...`；
6. Hybrid 下调用 UECap staging；
7. 写入 `.thermal_policy`、`.thermal_offset` 和 install receipt；
8. 不依赖本次 boot 的 effective `/vendor` 结果；
9. 不在 installer 里启动长期 worker 或 HTTP server。

### 7.2 `post-fs-data.sh`

只做 Hybrid pre-mount promotion：

```text
读取 pending
→ 若 rollback_pending，恢复 last-good
→ 否则 promotion inactive slot
→ 不 mount、不 bind、不启动 ThermalHAL
```

### 7.3 `post-mount.sh`

只读复核：

- thermal source/effective hash；
- thermal source/effective context；
- UECap source/effective hash；
- Hybrid `scan.ret`/`state.json`；
- current boot receipt。

失败时写 `rollback_pending`，不能把 source hash 当成 effective success。

### 7.4 `service.sh`

service 负责 late-start 业务和 WebUI。WebUI 启动必须早于非关键 telephony/scheduler/VM 初始化，并且：

- service singleton lock 防止多实例；
- httpd 启动有界重试和 PID 复读；
- `dumpsys telephony.registry` 最多 5 秒；
- radio/scheduler 失败只写 deferred/warning，不阻塞 HTTP；
- 不在 service 中修改 thermal JSON 或 `/vendor`；
- 不把 UECap modem load unconfirmed 写成 functional success。

## 8. CGI API 规范

所有 CGI 都必须：

- 只允许 loopback；
- mutation 使用 token；
- POST body 限长且必须是 JSON object；
- 使用 `acquire_lock`，结束时 `release_lock`；
- 错误返回正确 HTTP status 和 `ok=false`；
- 结构化 audit log 不记录原始 body、token、serial、IMEI 或完整 logcat。

### 8.1 `GET /cgi-bin/set_thermal.sh`

用途：读取当前 policy、offset、mount backend 和 UI contract。GET 不 mutation，不要求用户确认。

成功字段：

```json
{
  "policy": "system|custom",
  "offset": -2,
  "overlay_present": false,
  "custom_available": true,
  "metamodule_active": true,
  "mount_backend": "hybrid_mount|metamodule_content|dynamic_bind",
  "reinstall_required": false,
  "thermal_contract": {
    "policies": ["system", "custom"],
    "default_policy": "system",
    "offsets": [-2, 2, 4, 6],
    "default_offset": 2
  }
}
```

`thermal_contract` 缺失或字段类型错误时，WebUI 必须保留旧 contract，不能清空已有档位；首次加载可有限重试。

### 8.2 `POST /cgi-bin/set_thermal.sh`

请求：

```json
{"policy":"custom","offset":4}
```

或：

```json
{"policy":"system"}
```

Hybrid custom/system 均采用 pending slot，不在当前 boot 直接替换 `/vendor`。

成功 pending：

```json
{
  "ok": true,
  "policy": "custom",
  "offset": 4,
  "restarted": false,
  "reboot_required": true,
  "effective_state": "pending_reboot",
  "mount_backend": "hybrid_mount"
}
```

错误语义：

| HTTP | 场景 |
|---|---|
| 400 | policy/offset/body 无效 |
| 403 | token 无效 |
| 409 | 仍有未处理的 pending slot、后端只读、当前 backend 不允许 mutation |
| 500 | stock 缺失、generator 失败、slot/manifest 写失败、回滚不完整 |

只有 `reboot_required=true` 才打开前端重启确认框；HTTP 200 不表示 effective 已生效。

### 8.3 `POST /cgi-bin/reboot.sh`

请求：

```json
{"action":"reboot","confirm":true}
```

此接口只负责提交重启，不负责验证 thermal/UECap。返回 JSON 后延迟执行 reboot；前端不可在后台轮询中自动 reload 页面或销毁确认框。

### 8.4 `GET /cgi-bin/thermal.sh`

用途：读取 thermal cache/live zones。它不是阈值 policy API。

- 普通 GET 优先返回 `.thermal_cache.json`；
- `fresh=1` 请求生产 fresh read；
- POST `{ "action":"clear" }` 清除异常 cache；
- 不得把当前温度或 Thermal Status 当作阈值配置已生效证明。

### 8.5 `GET/POST /cgi-bin/audit_log.sh`

GET 返回已脱敏的结构化审计行；`?all=1&limit=2000` 返回保留窗口内日志。

POST：

```json
{"action":"clear"}
```

只能清理模块后台审计日志，不清理当前 WebUI session log、thermal history 或设备系统 logcat。

## 9. WebUI 维护契约

### 9.1 运行时常量与 API

`webroot/js/runtime.js` 是 API path、thermal presets、轮询间隔和 UI contract 常量入口。阈值数值、offset allowlist 和 policy 不得在 `thermal.js` 另写第二份。

### 9.2 `thermal.js` 函数

| 函数 | 责任 |
|---|---|
| `updateThermalRuntimeGuard(data)` | 读取 `metamodule_active/reinstall_required` |
| `applyThermalContract(data)` | 校验结构化 policies/offsets/default 类型 |
| `renderThermalCards()` | 依据 backend contract 生成 system/custom cards |
| `loadThermalPreset()` | 读取 policy contract；失败保留旧 contract 并有限重试 |
| `applyThermalSelection(policy,offset)` | POST mutation；只把 pending 显示为待重启 |
| `cancelThermalChange()` | 提交上一状态，不绕过 CGI/slot contract |
| `rebootDevice()` | 只由用户点击确认后调用 reboot CGI |
| `refreshThermal()` | 读取温度 zones；发现 contract 缺失时补加载 |
| `syncThermalUi()` | 显示 current policy/effective presentation，不自行推导 backend 状态 |

前端状态必须区分：

```text
contract_loaded
current_policy
current_offset
pending_reboot
effective_verified
readback_failed
```

`pending_reboot` 不能显示成“已生效”；`readback_failed` 不能隐藏成默认 stock；后端返回 409/500 必须保留当前有效显示并展示失败原因。

### 9.3 轮询与 reload

WebUI 使用单个递归 `setTimeout`，根据 tab、可见性和 idle 状态调整间隔。必须保留：

- `document.visibilityState`/`pagehide` 暂停；
- modal 打开时降低轮询，不销毁 modal；
- 每个请求 AbortController timeout；
- 不允许后台版本检查调用 `location.reload()`；
- 版本变化只记录或提示，不能破坏 pending reboot/cancel 状态。

## 10. 失败矩阵

| 失败 | 允许保留 | 必须禁止 |
|---|---|---|
| contract GET 超时 | 旧 contract/旧卡片 | 清空档位并永久不恢复 |
| generator 失败 | 旧 active/stock | 提交半成品 candidate |
| slot write 失败 | 旧 active | 写 pending 指针 |
| promotion hash/context 失败 | last-good/stock | 更新 active 为失败 slot |
| effective readback 失败 | rollback_pending | 写 verified receipt |
| WebUI POST 409 | 当前有效状态 | 把 pending 显示为已生效 |
| reboot CGI 失败 | pending 状态 | 清除 pending 或伪报 reboot |
| Hybrid mode=ignore/VFS | stock effective | 把 source hash 当 effective |
| stale lock | 经过 PID/start_ticks 复核后回收 | 无条件删除活跃锁 |

## 11. 维护与验证清单

每次修改温控链路至少执行：

### 静态

```sh
sh -n scripts/thermal_profile.sh
sh -n scripts/thermal_policy_lib.sh
sh -n scripts/slot_transaction_lib.sh
sh -n webroot/cgi-bin/set_thermal.sh
sh -n webroot/cgi-bin/thermal.sh
sh -n post-fs-data.sh
sh -n post-mount.sh
node --check webroot/js/thermal.js
node --check webroot/js/common.js
```

### Contract/fixture

- system → custom；
- custom → custom；
- custom → system；
- 失败 promotion → rollback_pending；
- verified → 清理 rollback_pending；
- stale lock PID/start_ticks；
- contract GET 一次超时后恢复；
- 重启确认框打开期间版本变化不 reload；
- thermal UI contract 只从 backend offsets 渲染。

### 设备

```sh
adb devices -l
adb -s <serial> shell getprop sys.boot_completed
adb -s <serial> shell su -c 'grep -E " /system | /vendor " /proc/self/mountinfo'
adb -s <serial> shell su -c 'ls -lZ /vendor/etc/thermal_info_config.json'
adb -s <serial> shell su -c 'cat /data/adb/modules/pixel9pro_control/.thermal_runtime_receipt'
adb -s <serial> shell su -c 'dumpsys thermalservice | grep -E "HAL Ready|AIDL|Thermal Status"'
```

必须分别记录：

```text
source hash/context
pending/active/last-good/rollback_pending
Hybrid scan.ret/state.json
effective hash/context
receipt freshness/current boot_id
ThermalHAL status
WebUI PID/6210 listener
```

## 12. 已知边界

- Hybrid Mount 的 `ignore`、`overlay`、`magicmount`、VFS 规则由外部模块管理；Control 不能仅靠 source promotion 改变它。
- UECap early firmware 的 modem functional load 不能仅由文件 hash 证明；receipt 中 `modem_load_state=unknown` 必须保持未确认。
- 当前 UI custom offsets 不含独立 `0°C` 卡片；改变该 UX 需要同步 backend contract 和测试。
- WebUI contract retry 只解决短暂 GET/启动竞态，不替代 CGI 后端故障修复。
- 任何设备刷入、重启、卸载、Hybrid 规则切换都必须单独归档，不得把静态 ZIP audit 当作 runtime proof。
