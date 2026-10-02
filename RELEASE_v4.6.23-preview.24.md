# Pixel9Pro-Control v4.6.23-preview.24

## 发行说明

优化：网络能力、温控和调度接管在按钮交互或全量刷新后出现的读取失败、超时和状态回显不一致。
优化内核待机问题

### 修复

- 修复 UECap 读取使用 6 秒 deadline 导致合法的慢速 modem 诊断被前端提前取消的问题；切换后的运行态校验延长为 60 秒，并保留上一次已确认状态。
- 修复网络页把 NR、NTP、待机守护、UECap、基带五组读取同时压入 Request Hub，造成慢接口排队超时的问题；改为短读与慢读分阶段调度。
- 修复温控合同、实时 Thermal HAL、缓存清理、温控 transaction readback 在队列繁忙时使用过短超时的问题。
- 修复调度 owner、fas-rs 协调、CPU 状态和全量 profile 读取的 deadline；保留 POST → compact GET → full GET 的确认顺序。
- 删除 `loadInfo` 对基带状态的重复读取，避免启动和网络页刷新重复占用通信槽。
- 全量刷新现在把领域函数返回的 `false` 作为失败回显，避免接口未完成时仍提示“已刷新”。

### 接口与交互

- 网络能力诊断超时不再清空已有 UECap 按钮；页面明确显示“本次读取未完成”，不把旧数据伪装成当前确认。
- NR、NTP、待机、基带读取显示 HTTP 状态或超时阶段，便于区分后端错误、排队超时和设备状态未确认。
- 温控和调度 mutation 要求 GET readback；提交成功、staged、pending reboot、effective 和 degraded 状态继续由后端合同决定。
- 统一记录网络、温控和调度的接口字段、耗时边界和 Request Hub 分阶段策略。

### 验证边界

- `DEVICE_READBACK`：本预览版需在设备端重新安装后再确认当前 WebUI 版本（必要时可以刷新浏览器缓存）。
- `UNVERIFIED`：本预览版安装后的浏览器点击回归、远程 ADB 长时间在线状态和 Linux kernel 深度 suspend 仍需手动复现。
