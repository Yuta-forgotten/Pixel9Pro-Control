# Pixel 9 Pro / XL Baseband Trial

> **当前源码**：`v1.1.0-rc3`，支持 Pixel 9 Pro (`caiman`) 与 Pixel 9 Pro XL (`komodo`)。本模块只提供 CarrierSettings、APN、China MCFG 与 IMS properties；UECap 不再由本模块携带或写入。该版本作为独立 GitHub Release `v1.1.0-rc3` 发布，不与 Control `v4.5.07` 合并。此前功能等价候选已在 caiman/APatch 完成安装、重启和有效路径复核；当前发布 ZIP 已完成源码、确定性构建和 ZIP 结构审计，但尚未重新安装。当前 ZIP 的体积、SHA256 和 source fingerprint 统一记录在根级审查文档与日志索引中，不在模块 README 内自引用，避免源码 fingerprint 与 ZIP digest 形成循环漂移。
> **本轮边界**：普通基带模块可以直接升级；只有升级后 MetaModule content image、effective overlay 或同一 boot 的 runtime receipt 无法验证时，才需要 clean reinstall。升级 APatch Manager 本身不等于必须卸载 APatch Manager。

## 功能

两个机型共用：

- `persist.dbg.volte_avail_ovr=1`（VoLTE）；
- `persist.dbg.wfc_avail_ovr=1`（Wi-Fi Calling）；
- CarrierSettings（3210 个运营商配置）；
- APN 配置；
- China MCFG metadata overlay（移动/联通/电信/广电）。

UECap 按设备分工：

| 设备 | UECap 行为 |
|---|---|
| Pixel 9 Pro (`caiman`) | UECap 由 `pixel9pro_control` 管理 `PLATFORM_9055801516233416490.binarypb` 的三档配置 |
| Pixel 9 Pro XL (`komodo`) | 当前按 external/stock 处理；系统/外部原生路径负责 `PLATFORM_6287228797510365516.binarypb`，本模块不携带、不校验、不写入该文件 |

`PLATFORM_9055801516233416490.binarypb` 与 `PLATFORM_6287228797510365516.binarypb` 是不同 SKU 的文件，不能交叉替换。通用安装框架、CarrierSettings、APN、IMS properties 和 MCFG 逻辑可以复用，但 UECap binarypb、MCFG、modem firmware、Saipan、`mcfg_hw` 与 stock thermal 资源必须按 SKU 单独确认。

## 安装门禁与 MetaModule 契约

安装器按以下顺序执行：

1. 读取 `ro.product.device`，失败时回退 `ro.build.product`；
2. 只接受 manifest 中的 `caiman` / `komodo`；
3. 识别 APatch、KernelSU 或 Magisk，未知 root 直接拒绝；
4. 本模块不 staging、bind 或校验任何 UECap binarypb；
5. APatch/KernelSU 安装前确认活动 MetaModule contract；内容迁移由 root 框架的 `metainstall.sh` 完成；
6. 只在旧普通基带模块的迁移收据不完整、content image 为空或 effective overlay 未验证时，提示卸载旧普通基带模块并重启后重装；
7. 任一检查失败都不发布成功态。模块不自行 mount、复制或写入 MetaModule image。

APatch 11224 与 KernelSU 的 `system/product`、`system/vendor` 覆盖都依赖活动 MetaModule。安装后必须重启；`post-mount.sh` 和 `service.sh` 会复读 source、MetaModule content image、effective path、mount 和同一 boot 的 runtime receipt，并将结果写入模块 `.runtime_status`。仅看到 `modules_update/`、模块目录或安装器退出码不能证明已经生效。

Magisk 继续使用自身 Magic Mount，不要求 MetaModule；CarrierSettings/APN/MCFG/IMS props 可继续安装。Magisk、APatch 和 KernelSU 的有效路径要求不同，不能用某一种 root 的成功条件替代另一种。

### 普通基带模块升级判定

新版普通基带模块不应默认要求用户先卸载 APatch Manager。Manager、APD、KernelPatch 与普通模块是不同层次；更新 Manager 本身不等于必须删除 Manager 或清空模块环境。

- **允许直接升级**：旧模块的 active source、enabled state、pending update、MetaModule content image、effective overlay、source/content/effective hash 和同一 boot 的 runtime receipt 均可读且一致；安装新版后仍需重启，并重新复读这些状态。
- **必须 clean reinstall**：MetaModule content image 缺失/为空/不可读，effective overlay 未生效，active 与 pending 冲突，runtime receipt 缺失/过期/跨 boot/失败，hash 不一致，或 migration state 无法确认。
- **clean reinstall 顺序**：Root Manager 卸载旧的普通基带模块 → 重启 → 安装新版 → 再重启 → 复读 active module、MetaModule content image、effective path、mount、hash 和 runtime receipt。

本模块永远不删除 `/data/adb/modules`，不删除或修改 `modules.img`，不写
`/data/adb/metamodule/mnt`，不自行 mount/bind MetaModule，也不通过 Recovery 安装 APatch 模块。

## 与 pixel9pro_control 的关系

- 两个模块共用 module-aware device 边界，但运行职责不同；
- caiman UECap 仍只由 Control 管理；
- komodo 当前为 external/stock，不提供三档写入或 WebUI 控制；
- baseband 模块不负责温控、CPU 调度、ZRAM 或 WebUI。

当前 caiman 设备已经观察到 `NR_SA` / n41；本轮不再修复 SA。NSA parser 仅用于识别其它运营商、地点或漫游下的 LTE anchor/EN-DC，未确认 NSA 小区时应记录 `NOT_APPLICABLE`，不能把它判定为模块失败。当前一直是 LTE/4G 也只代表当前无线观察结果，不单独证明 Control 失效。

## 主机验证

在 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-BasebandModule.ps1'
```

门禁覆盖双机白名单、unknown root/非法 manifest 拒绝、UECap payload 禁止进入 standalone、APatch/KernelSU MetaModule contract、content-image relocation、source/content/effective hash、runtime receipt freshness、mount failure injection、3210 个 CarrierSettings、5 个 China MCFG、Shell parser 和共享构建器 source validation。

## 历史可下载版本

已发布的 `v1.0.1` 是历史 caiman-only 回滚版本，不代表当前双机源码：

- [pixel9pro_baseband_trial_v1.0.1.zip](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases/download/v4.3.11/pixel9pro_baseband_trial_v1.0.1.zip)

上一轮 RC2 的包和设备记录只作为历史证据。此前 RC3 功能等价候选已完成本地门禁、确定性构建、ZIP 审计和 caiman/APatch 安装重启复核；重启后的 source/content/effective contract、runtime receipt 与 migration marker 均 PASS，并观察到中国广电 NR_SA n41。当前 v1.1.0-rc3 发布 ZIP 已再次完成确定性构建和结构审计，但尚未重新安装；komodo 实机闭环仍未完成。旧 v1.0.1 可作为明确回滚件保留，不应与 RC3 混装。

## 不要叠刷

- `5G+Pixel56789TenVoLteVo5G-Global.zip`；
- `pixel_uecap_special_apatch_magisk_2026.04.03.zip`；
- 其它会覆盖 `/product/etc/CarrierSettings/`、China MCFG 或同一 UECap target 的模块。
