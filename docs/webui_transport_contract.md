# WebUI 请求与运行态接口合同

## 结论

网络能力、温控和调度接口的 CGI 合同没有被按钮事件直接改坏。当前设备回读显示这些接口均返回合法 JSON；问题来自前端把不同耗时等级的读取同时放入同一个 Request Hub 队列，并给慢接口使用了过短的端到端 deadline。

## 请求链

`app.js` 负责页面生命周期，领域模块只负责自己的状态和渲染，`common.js` 的 Request Hub 负责 GET 合并、最多三个活动请求、优先级和队列 deadline。CGI 只接受 loopback；GET 是只读，POST 需要 `application/json` 和 WebUI token。POST 的成功状态必须再由 GET readback 确认。

页面刷新现在分两级：CPU、温度、内存先读取；网络和系统信息随后读取。网络页内部又分为短读阶段（NR、NTP、待机守护）和慢读阶段（UECap、基带状态）。这样不会让一个 modem 检查耗尽其他接口的队列 deadline。

## 网络接口

| 接口 | 方法 | 返回事实 | 前端 deadline | 说明 |
|---|---|---|---:|---|
| `/cgi-bin/nr_switch.sh` | GET/POST | NR 开关、slot mode、实际 RAT、时序合同 | 12s | POST 后必须复读 GET |
| `/cgi-bin/uecap.sh` | GET/POST | UECap mode contract、requested/active、hash、modem receipt、无线观察 | 30s | GET 会执行 modem/runtime 检查；切换后最多 60s 轮询确认 |
| `/cgi-bin/check_baseband.sh` | GET | 基带模块 source/effective/content/receipt 合同 | 20s | 只读观察，不由 Control 负责挂载或修复 |
| `/cgi-bin/standby_guard.sh` | GET/POST | 后台观测、SIM2、suspend 失败设备与人类可读原因 | 12s | POST 后必须复读 GET |
| `/cgi-bin/ntp.sh` | GET/POST | NTP 服务器、自动同步、设备时间 | 12s | 切换和同步后必须复读 GET |

UECap 读取超时时保留上一次已确认的合同和按钮，页面只显示“本次读取未完成”；没有任何已确认合同时才显示错误占位。超时不等于后端状态已丢失，也不允许把旧状态当作当前确认结果。

## 温控接口

| 接口 | 方法 | 返回事实 | 前端 deadline |
|---|---|---|---:|
| `/cgi-bin/thermal.sh` | GET | Thermal HAL 实时热区；普通读取优先使用 worker cache | 10s |
| `/cgi-bin/thermal.sh?fresh=1` | GET | 绕过缓存的实时热区 | 15s |
| `/cgi-bin/thermal.sh?history=1` | GET | 模块温度历史点 | 由 history 请求窗口决定 |
| `/cgi-bin/thermal.sh` | POST `{"action":"clear"}` | 原子清除异常缓存 | 15s |
| `/cgi-bin/set_thermal.sh` | GET | policy、offset、mount/effective hash、transaction、thermal contract | 15s |
| `/cgi-bin/set_thermal.sh` | POST | staging、repair 或 cancel transaction | 30s；随后 15s GET readback |
| `/cgi-bin/thermal_burst.sh` | GET/POST | 前台临时采样标记 | 8s |

温控 POST 的 staged 响应只证明 journal 已提交；`effective_state`、pending id 和重启要求仍以随后 GET 为准。温度读取失败会先走 fresh，再按异常次数尝试清缓存；不会用无效值覆盖上一条有效温度。

## 调度接管与协调接口

| 接口 | 方法 | 返回事实 | 前端 deadline |
|---|---|---|---:|
| `/cgi-bin/status.sh` | GET | 三个 CPU cluster 的频率、governor、sched_pixel 观察值 | 10s |
| `/cgi-bin/profile.sh?compact=1` | GET | owner、policy、profile、boot/health 摘要 | 12s |
| `/cgi-bin/profile.sh` | GET | 外部 scheduler 探测、CPU contract、boot/health 全量合同 | 60s，后台低优先级 |
| `/cgi-bin/profile.sh` | POST | profile、policy、owner、handoff、retry/cancel 事务 | 15–45s，按动作既定合同 |
| `/cgi-bin/owner_arbiter.sh` | POST `{"action":"tick"}` | fas-rs owner tick 结果 | 20s |

全量 profile GET 会扫描外部 scheduler，实测比 compact GET 慢；它不能与网络慢读共用旧的 6–8 秒 deadline。按钮提交后仍按 POST → compact GET → 必要时 full GET 的顺序确认，任何超时都只报告“未确认”，不伪造成功。

## 变更根因与修复边界

前一轮为提升按钮响应，把原先串行的页面刷新改成了跨领域 `Promise.allSettled`。在当前设备上，UECap、基带、info、profile 全量读取分别约需 11.2s、4.9s、6.5s、8.9s；它们进入三槽 Request Hub 后，原有 UECap/基带 6s deadline 会在 CGI 返回 HTTP 200 前过期。`eb7083f` 增加 POST 后同步 readback 后，请求数量进一步增加，放大了同一队列问题。CGI HTTP 400 并非由成功的 GET 或按钮 DOM 事件生成，真正的 400 仍表示请求体、字段或状态合同校验失败。

本次修复只改变前端调度、deadline、错误回显和重复读取，不改变 UECap、thermal journal、scheduler owner 或基带模块的所有权。

## 证据边界

- `SOURCE_AUDIT`：当前 source 显示上述接口、字段、锁和 readback 顺序。
- `DEVICE_READBACK`：同一 boot 下已对网络和温控 GET 做 HTTP 状态、JSON、耗时回读；调度接口的 POST 只在用户实际点击时改变状态，未以诊断请求代替真实变更验收。
- `BUILD`：待本次 source 合并后重新打包并读取安装后的 WebUI 版本。
- `UNVERIFIED`：浏览器实际点击后的视觉状态和设备进入深度 suspend 的同 boot 验收仍需安装新包后手动复现。
