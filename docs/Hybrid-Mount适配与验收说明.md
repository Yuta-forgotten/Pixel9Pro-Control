# Hybrid Mount 适配与验收说明

状态：源码适配阶段；尚未在真实设备安装 Hybrid Mount 验收
日期：2026-09-21

## 为什么从 meta-overlayfs 分支拆出

KernelSU 官方说明 regular module 不需要为 MetaModule 写专用挂载代码，MetaModule 负责安装和挂载；`metainstall.sh` 是可选的 regular module 安装钩子。当前 Control 过去针对现场 `meta-overlayfs 1.3.1` 做了 hook patch 和 ext4 content image gate，这是该实现的兼容补丁，不是所有 MetaModule 的通用要求。

Hybrid Mount 的官方模型是：regular module source 目录保持只读输入，由 Hybrid Mount 在下一次 boot 根据模块级/路径级规则选择 OverlayFS、Magic Mount 或 VFS；配置变更在重启后生效。参考：[Hybrid Mount README](https://github.com/Hybrid-Mount/meta-hybrid_mount)、[KernelSU MetaModule 文档](https://kernelsu.org/guide/metamodule.html)。

## 本次源码变化

### backend detection

`uecap_profile.sh` 现在识别活动 MetaModule 是否为 Hybrid Mount。检测采用：

- `metamodule=1|true`；
- module id/name 或 Hybrid Mount binary；
- `/data/adb/hybrid-mount/config.toml` 存在；
- `disable/remove/skip_mount` 不存在。

检测到 Hybrid Mount 后，`UECAP_BACKEND=hybrid_mount`。未知 MetaModule 仍走已有 `metamodule_content` gate，避免把未知布局误判为 Hybrid。

### regular source staging

Hybrid backend 不 patch `metainstall.sh`，不读取 `modules.img`，也不要求 `/data/adb/metamodule/mnt/<id>` content 目录为空。UECap 文件写入：

```text
/data/adb/modules/pixel9pro_control/system/vendor/firmware/uecapconfig/<target>
```

Thermal custom 仍写入：

```text
/data/adb/modules/pixel9pro_control/system/vendor/etc/thermal_info_config.json
```

两者都在安装或 WebUI staging 阶段设置 `vendor_fw_file` / `vendor_configs_file`，重启后由 Hybrid Mount 处理。

### readback contract

Hybrid readback 检查：

1. source staging hash/context；
2. effective `/vendor` hash/context；
3. `/vendor` OverlayFS lowerdir 是否包含 module source，或当前 canonical target 是否有 Hybrid Mount 文件挂载；
4. `source_hash == effective_hash`；
5. receipt 使用 `backend=hybrid_mount`、`mount_observed=hybrid_mount`、`reinstall_required=false`。

Hybrid UECap 改档返回 `reboot_required=true`，不会伪装为当前 boot 已完成。重启后 `post-mount.sh` 和 `service.sh` 复读结果并提交 same-boot receipt。

## 与 meta-overlayfs 的分支

| 条件 | `meta-overlayfs` backend | `hybrid_mount` backend |
|---|---|---|
| source 内容 | 安装期复制到 content image | regular module source |
| hook | 使用已审计的 `metamodule_compat.sh` | 不修改外部 hook |
| 旧 content gate | 必须 clean reinstall | 不检查 ext4 content image |
| UECap 修改 | 安装期 content staging + reboot | regular source staging + reboot |
| effective 验收 | content/effective hash/context + lowerdir | source/effective hash/context + Hybrid mount topology |
| 运行期动态 bind | 禁止 | 禁止 |

## Hybrid Mount 实机验收门禁

切换前需要保存 rollback ZIP，并按 Hybrid Mount 官方 Manager 流程安装、重启。然后确认：

```sh
adb shell su -c 'cat /data/adb/metamodule/module.prop'
adb shell su -c 'cat /data/adb/hybrid-mount/config.toml'
adb shell su -c 'grep -E " /system | /vendor " /proc/self/mountinfo'
adb shell su -c 'ls -lZ /data/adb/modules/pixel9pro_control/system/vendor/firmware/uecapconfig/'
adb shell su -c 'ls -lZ /vendor/firmware/uecapconfig/'
adb shell su -c 'cat /data/adb/modules/pixel9pro_control/.uecap_runtime_receipt'
adb shell su -c 'dumpsys thermalservice | grep -E "HAL Ready|AIDL|Thermal Status"'
```

必须分别验收 OverlayFS、Magic Mount 和 VFS 配置；VFS 不是真实 mount，不能直接套用 lowerdir 判断。若 Hybrid 规则选择 `ignore` 或 VFS 对 UECap/thermal path，readback 必须失败并保持 stock。

## 尚未完成

- 未在当前 Pixel 9 Pro `caiman` 上安装 Hybrid Mount；
- 未确认该设备 Hybrid Mount 版本和 `config.toml` 中的实际 path rule；
- 未验证 Magic Mount/OverlayFS 两种模式的 vendor SELinux context；
- 未验证 UECap early firmware 在 Hybrid Mount 下的启动时序；
- 未重新生成 Hybrid backend 的 release ZIP 并完成冷启动。

因此当前源码适配完成只代表代码路径具备 Hybrid backend 分支，不能宣称 Hybrid Mount 实机通过。

## v4.4.41 与当前实现的差异边界

`v4.4.41` 的 ZIP 不能作为当前 Hybrid/MetaModule 的安全基线。该版本没有 `metamodule=1` 的外部挂载契约：温控 JSON 和 UECap 候选文件直接随普通模块 source 放在 `system/vendor`，`service.sh` 在 late-start 通过动态 bind 切换 UECap；Magisk 分支则在安装时删除 UECap 覆盖。这样绕过了当前 `meta-overlayfs` ext4 content image，因此不会形成“旧 image 目录残留 → 错误 SELinux label → ThermalHAL 早期读取崩溃”的同一故障链，但并不代表旧方案没有风险。

旧方案仍有两个不可继承的问题：运行期替换 early firmware 可能与 `vendor.cbd` 的早期打开或 `mmap()` 竞争，温控文件热替换和 ThermalHAL 重启也没有 source/effective hash、context 和跨重启 receipt 闭环。当前版本引入 MetaModule 后，UECap/thermal 的最终可见路径由挂载后端决定；`meta-overlayfs`、Hybrid Mount 和 Magisk 不能共用一套写入代码。

因此当前卡二屏应分层归因：

1. `v4.4.41` 的直接 bind/source 路径与当前 `meta-overlayfs` content image 残留不是同一实现；不能用旧版“曾经能启动”证明当前 MetaModule hook 正确。
2. APatch 和 KernelSU 是 root/执行环境，不是同一个挂载后端。两者使用同一类 MetaModule 或同一份错误 hook 时，都可能遇到 stale image、错误 context 或 clean reinstall 缺失问题；Hybrid Mount 则必须按自己的 source/promote/mount topology 单独验收。
3. 修改 MetaModule 脚本时不必重新设计 UECap 选择算法，但必须复核 UECap 的挂载时序和 readback。UECap binarypb 在 `/vendor/firmware`，可能早于普通 WebUI/service 被读取；如果后端从 content image 改成 regular source，变化的是 staging/promotion/readback 适配，不是 caiman/komodo 的 payload、档位和 canonical filename 合同。

当前实现采用后端分层：MetaModule content backend 保留 clean reinstall 与现有 hook gate；Hybrid backend 使用 module-private pending/A-B slot，在 Hybrid Mount 扫描前由 `post-fs-data.sh` promotion，挂载后由 `post-mount.sh` 复读；Magisk 继续停用 managed UECap。任何后端都不能仅凭 WebUI 200、文件存在或命令退出码声称 UECap/thermal 已经生效。

## 2026-09-21 首次 caiman/APatch/Hybrid 实机证据

候选 ZIP `pixel9pro_control_v4.6.00-rc1-hybrid-ab-20260921e.zip` 已通过干净 LF 源树的 `build_module.py --validate-only`、确定性构建和 ZIP 审计；本地与设备传输 SHA-256 为 `4869af6e6b7e9f7310e94a4c7a863a786ec256f3d72dc9527808a12945ffef76`。APatch `apd module install` 成功，安装器生成了当前 Build 的 UECap pending manifest，记录 `caiman`、`CP41.260814.003.B1`、`vendor_fw_file` 和 source hash `2870ba9c94145930ad75f1666c6ec2755ac207a7efc0aa4277bdde13cabaae0c`。

重启后 `post-fs-data.sh` 已真实执行并把 pending payload promotion 到 `/data/adb/modules/pixel9pro_control/system/vendor/firmware/uecapconfig/`；但 Hybrid Mount 6.2.0 的 `scan.ret` 将 `pixel9pro_control` 判为 `mode=ignore`，实际 `/vendor` OverlayFS 的 `overlay_modules` 只有 `pixel9pro_baseband_trial`。因此 effective UECap 仍是 stock hash `c4a3a51002c542b89e6a4b65f4351ce2f889b1157ceede41af0f81f5059dfb44`，UECap receipt 正确标为 `metamodule_effective_readback_failed`；没有把 source hash 当成 effective 成功。

同一 boot 的温控仍为 stock：`thermal_runtime_receipt=status=verified`、effective context 为 `u:object_r:vendor_configs_file:s0`、ThermalHAL `HAL Ready=true` 且 AIDL 3 connected。该结果证明 A/B promotion 和失败闭环已到达设备，但不能证明 Hybrid Mount 的 Control 模块规则已经启用。下一条最小外部验证是通过 Hybrid Mount Manager 为 `pixel9pro_control` 选择 `overlay`（或已验证的 `magicmount`）并重启；在规则仍为 `ignore` 时禁止继续声称 UECap/thermal Hybrid 生效。
