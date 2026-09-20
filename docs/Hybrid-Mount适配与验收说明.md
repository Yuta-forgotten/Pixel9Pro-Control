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
