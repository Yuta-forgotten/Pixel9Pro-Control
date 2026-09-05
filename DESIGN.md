# pixel9pro_baseband_trial 设计决策

## 1. 目标与职责

本模块为 Pixel 9 Pro (`caiman`) 与 Pixel 9 Pro XL (`komodo`) 提供运营商配置层的补充，不承担 modem firmware、NV item 或 UECap 能力表的写入。当前职责是：

- `CarrierSettings` framework 配置；
- APN 配置；
- China `mcfg_sw` metadata；
- VoLTE/WFC debug properties；
- 安装后 source → MetaModule content image → effective overlay → runtime receipt 的一致性复读。

UECap ownership 明确分离：caiman 的三档 UECap 由 `pixel9pro_control` 管理，komodo 由系统/外部 stock 路径负责。本模块不得成为第二个 UECap writer。

## 2. 关键决策与权衡

### 2.1 让 MetaModule 成为唯一内容迁移 owner

APatch/KernelSU 的 `system/`、`product/`、`vendor/` 内容由活动 MetaModule 的 `metainstall.sh` 迁移和挂载。本模块只检查活动 MetaModule contract，不自行 mount、bind、loop、修改 `modules.img` 或写入 `metamodule/mnt`。

这样牺牲了安装器直接“修好”挂载的能力，但避免不同模块同时管理 OverlayFS lower/upper 层，也能把“安装命令成功”和“有效路径已经生效”区分开。Magisk 使用自身 Magic Mount，不强制要求 MetaModule。

### 2.2 普通模块升级采用条件式直升

不是所有用户都必须先卸载旧普通基带模块。只有以下证据全部成立时才允许直接升级：active source、enabled、无 pending conflict、content image、effective overlay、source/content/effective contract/hash，以及属于当前 boot 的 schema 3 runtime receipt。

任一层缺失、为空、冲突、失败、跨 boot 或无法确认时，安装器 fail closed，并提示用户按“卸载旧普通基带模块 → 重启 → 安装新版 → 再重启 → 全量复读”执行 clean reinstall。这里的卸载对象不是 APatch Manager。

### 2.3 effective merged tree 允许 lower-layer extra files

OverlayFS 的有效目录是合并视图，effective tree 可能比模块 source 多出 lower layer 文件。因此 correctness 以声明 contract 中的关键路径、文件数量下限、关键 hash、mount 和 receipt 为准；不把 aggregate tree hash 或“effective 必须与 source 文件总数完全相等”当作硬门禁。

### 2.4 receipt schema 3 才能成为当前运行证据

schema 2 及更旧 receipt 即使包含看似匹配的 boot/source/target 字段，也不能提升为当前 verified。schema 3 必须同时记录 boot、source/content/effective contract、mount/effective 状态、migration 状态与 freshness，避免把历史或 partial receipt 当作实际生效证明。

## 3. 设备与内容边界

| 内容 | caiman | komodo |
|---|---|---|
| CarrierSettings/APN/China MCFG/IMS properties | 当前模块按 manifest 提供 | 当前模块按 manifest 提供，但目标 build 仍需单独验证 |
| UECap | Control 管理 `PLATFORM_9055801516233416490.binarypb` | 系统/外部 stock 管理 `PLATFORM_6287228797510365516.binarypb` |
| `mcfg_hw` / Saipan | 不从 XL 资源推导 | 不因存在候选就盲刷 |
| modem firmware / NV | 不修改 | 不修改 |

两个 `PLATFORM_*` 文件属于不同 SKU，不能改名、互换或仅凭文件存在复用。通用安装框架、状态机、CarrierSettings/APN/IMS 逻辑和测试框架可以复用；SKU-specific UECap、MCFG、firmware、`mcfg_hw` 与 stock 资源必须分别审计。

## 4. 状态与失败闭环

安装器只负责前置检查和发布迁移意图。安装后由 `post-mount.sh` / `service.sh` 复读：

1. active module 与版本；
2. 活动 MetaModule 和 content image；
3. `/product`、`/vendor` effective path 与 mount；
4. source/content/effective contract 与关键 hash；
5. schema 3 runtime receipt、boot ID、freshness 和 migration state。

失败时保持明确的 `FAIL` / `clean_reinstall_required`，不能只凭安装退出码发布成功态，也不能由模块自行删除旧目录或清理系统挂载层。

## 5. 验证与限制

主机门禁覆盖双机 manifest、unknown root、MetaModule 组合、无 UECap payload、21 项 runtime failure injection、安装器 17 项 failure/upgrade cases、3210 个 CarrierSettings、5 个 China MCFG、Shell parser、source validation 和确定性 fingerprint。

截至 2026-08-31，caiman/APatch 已完成前一份功能等价候选 ZIP 的安装、重启、有效路径复读，并观察到中国广电 `46015` 的 `NR_SA`/n41。当前源码 ZIP 已重新构建并审计，但尚未重新安装；komodo 尚未完成同 build 实机闭环。NSA parser 只用于其它运营商、地点或漫游下的 LTE anchor/EN-DC 分类，不作为当前 caiman SA 的修复目标。

## 6. 变更历史

- `v1.0.1`：历史 caiman-only 基带配置与回滚件。
- `v1.1.0-rc2`：加入 APatch 11224 MetaModule relocation 兼容边界与有效路径复读。
- `v1.1.0-rc3`：加入 caiman/komodo manifest、schema 3 runtime receipt、条件式直升级/clean reinstall 判定，并移除 standalone 内全部 UECap payload。
