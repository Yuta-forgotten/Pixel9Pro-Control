# Pixel 9 Pro Control v4.4.8 ADB 实机审查问题与修复方案

审查日期: 2026-06-08  
审查对象: `pixel9pro_control` v4.4.7 实机刷入态  
目标设备: Pixel 9 Pro `caiman`, Android 17 / SDK 37, APatch root  
修复版本: v4.4.8 / versionCode 72

## 1. 审查结论

v4.4.7 的核心功能已在实机运行: WebUI 绑定 loopback, 温控 overlay、ZRAM/VM、UECap balanced、基带模块检测和后台 worker 均可读到有效状态。

但本次 ADB 审查发现 4 类需要进入 v4.4.8 的问题:

1. WebUI token 通过 unauthenticated loopback GET 返回, 对本机恶意 App 不是有效授权边界。
2. 当前设备未检测到 Uperf, 但 `.cpu_sched_owner=external` 时本模块完全跳过 CPU 节点写入, 导致旧/系统高 boost 状态残留。
3. Android 17 热点桥接接口为 `ap_br_wlan2`, 旧 NR 降级热点检测漏掉 `ap_br_wlan*`。
4. NR 状态文件、settings raw value 和 telephony 实际 RAT 存在口径分裂; `.profile_history` 旧 9 列记录也未迁移到带 `sched_owner` 的 10 列证据链。

v4.4.8 的目标是最小修复上述问题, 不引入新的后台循环, 不改变温控/UECap/ZRAM 的既有策略。

## 2. ADB 证据摘要

### 2.1 模块与 WebUI

- `/data/adb/modules/pixel9pro_control/module.prop`: `version=v4.4.7`, `versionCode=71`
- WebUI 进程: `busybox httpd -p 127.0.0.1:6210`
- `.webui_token`: `0600`
- `.webui_httpd.pid`: `0666`
- `.locks`: `0777`
- 无 token POST 到 `profile.sh` 返回 `403 missing token`

结论: 写接口 token 闸门存在, 但 token 本身由 `info.sh` GET 返回, 本机 App 可主动获取后调用 root CGI。

### 2.2 CPU / Uperf

- Uperf 探测: `detected=no`
- `profile.sh`: `sched_owner=external`, `uperf_detected=false`
- CPU 节点:
  - `sched_util_clamp_min=1024`
  - `ug_bg_uclamp_max=1024`
  - `ug_bg_group_throttle=308`
  - `response_time_ms=13/56/170`

结论: 当前不是 v4.4.7 balanced 的 `16/40/200 + cap=0 + bg 200/100`, external 无人接管时会保留残留高 boost。

### 2.3 NR / Hotspot

- `nr_switch.sh` GET: `nr_switch=off`, `current_mode=9,27`, `saved_nr_mode=27,27`
- `dumpsys telephony.registry`: 当前注册为 `NR_SA`, display network 为 `NR`
- `dumpsys tethering`: `ap_br_wlan2 - TetheredState`
- `/sys/class/net/ap_br_wlan2/operstate`: `up`

结论: WebUI raw setting 不等于实际 RAT; 旧热点检测白名单漏掉当前 Android 17 真实热点桥接接口。

### 2.4 profile history

实机 `.profile_history` 末行仍为旧 9 列:

```text
1780654181,auto,balanced,service_start,0,35760,0,0,16/24/160
```

结论: v4.4.6/v4.4.7 虽然新增 `sched_owner` 字段, 但 `ensure_profile_history_baseline()` 遇到旧非空文件直接返回, 未追加新 10 列 baseline。

## 3. 修复策略

### 3.1 WebUI token 配对

变更:

- `info.sh` 不再返回 `webui_token`, 只返回 `auth_required:true`。
- 前端支持 `#token=<token>` 会话配对。
- 若用户未配对 token 而执行 POST, WebUI 通过 prompt 请求输入。
- token 仅保存到 `sessionStorage`, service 重启轮换后旧 token 失效并自动清除。

安全影响:

- 普通网页 CSRF 仍由 JSON POST + token 防护。
- 本机 App 不能再通过 unauthenticated `info.sh` 直接获取 token。
- 能读取 `/data/adb/modules/.../.webui_token` 的 root 攻击者仍不在本模块防护边界内。

### 3.2 external 无 Uperf 的安全底座

变更:

- `cpu_profile.sh` 新增内部 `force` 参数, 仅供 service/CGI 做一次性安全清理。
- boot 阶段若 `.cpu_sched_owner=external` 且未检测到 enabled Uperf:
  - 写回 balanced response/cap/cpuset。
  - 写回 L2 后台限制 `ug_bg_uclamp_max=200`, `ug_bg_group_throttle=100`。
  - 追加 `external_no_scheduler_sanitized` history。
- WebUI 切到 external 时同样先做一次 sanitize。

行为边界:

- sanitize 不是周期性调度接管。
- sanitize 后仍保持 `.cpu_sched_owner=external`; profile/auto/enforce 继续暂停。
- 若检测到 enabled Uperf, 不执行 sanitize, 维持真正外部接管。

### 3.3 NR 状态和热点修复

变更:

- worker 启动时从 `preferred_network_mode` slot0 推断 `_nr_state=lte/5g`, 不再固定为 `5g`。
- 热点检测加入 `/sys/class/net/ap_br_wlan*` 与 `/sys/class/net/ap_br_softap*`。
- `nr_switch.sh` GET 返回:
  - `current_mode`: raw setting
  - `current_slot0`: slot0 setting
  - `actual_rat`: telephony display RAT
- `nr_switch.sh` POST 关闭功能时立即写回 `.nr_saved_mode`。
- WebUI 展示优先使用 `actual_rat`, 同时保留 raw setting。

### 3.4 profile history 迁移

变更:

- 新增 `profile_history_has_owner_field()`。
- 若 `.profile_history` 不存在、为空或末行列数小于 10, service 启动时追加一条 10 列 `service_start` baseline。
- 旧 9 列记录不删除, 方便历史回溯。

### 3.5 状态文件权限硬化

变更:

- service 创建 `.locks` 后设置 `0700`。
- CGI `acquire_lock()` 每次确保 lock base 为 `0700`。
- `.webui_httpd.pid` 写入后设置 `0600`。
- `.webui_token` 继续保持 `0600`。

## 4. v4.4.8 验证清单

刷入 v4.4.8 后建议执行:

```sh
cat /data/adb/modules/pixel9pro_control/module.prop
ls -ld /data/adb/modules/pixel9pro_control/.locks
ls -l /data/adb/modules/pixel9pro_control/.webui_token /data/adb/modules/pixel9pro_control/.webui_httpd.pid
```

预期:

- `version=v4.4.8`
- `.locks` 为 `drwx------`
- `.webui_token` 与 `.webui_httpd.pid` 为 `rw-------`

WebUI token:

```sh
cat /data/adb/modules/pixel9pro_control/.webui_token
```

打开:

```text
http://127.0.0.1:6210/#token=<上面读到的 token>
```

CPU external 无 Uperf:

```sh
cat /data/adb/modules/pixel9pro_control/.cpu_sched_owner
sh /data/adb/modules/pixel9pro_control/scripts/cpu_profile.sh status /data/adb/modules/pixel9pro_control
tail -n 5 /data/adb/modules/pixel9pro_control/.profile_history
```

预期:

- 无 Uperf 且 external 时, 节点应回到 balanced 安全底座。
- history 应出现 10 列记录, reason 可为 `external_no_scheduler_sanitized`。

NR / Hotspot:

```sh
dumpsys tethering | grep -E 'TetheredState|ap_br'
/data/adb/ap/bin/busybox wget -q -O - http://127.0.0.1:6210/cgi-bin/nr_switch.sh
```

预期:

- 有 `ap_br_wlan*` tethered 时, NR 息屏降级不会触发。
- WebUI 显示实际 RAT 和 raw setting 两种口径。

## 5. 未纳入本次修改的边界

- 已有 root 权限或能读取 `/data/adb` 的攻击者不在 WebUI token 防护边界内。
- `settings put global preferred_network_mode*` 在 Android 17/运营商策略下可能被 telephony 框架解释或覆盖; 因此 v4.4.8 展示 raw setting + actual RAT, 不再把 raw setting 当唯一事实。
- `bg_restrict` 对系统豁免包可能只能做到 AppOps 部分限制; WebUI 继续显示“部分限制”。
