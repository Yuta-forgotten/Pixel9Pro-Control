# Pixel 9 Pro Control

[![Release](https://img.shields.io/github/v/release/Yuta-forgotten/Pixel9Pro-Control)](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases)
![Device](https://img.shields.io/badge/Device-caiman%20%7C%20komodo-2f6feb)
![Root](https://img.shields.io/badge/Root-APatch%20%7C%20KernelSU%20%7C%20Magisk-2da44e)

面向 Google Pixel 9 Pro（`caiman`）与 Pixel 9 Pro XL（`komodo`）的 Tensor G4 控制模块。温控、CPU 调度、ZRAM/VM 和网络待机策略可分别配置，并通过本机 WebUI 查看实际状态。

首次安装默认沿用系统温控与内存参数，关闭 NR 息屏降级。CPU 调度、UECap、SIM2 和校时各有独立默认值，音量键向导会在安装前汇总本次选择。

## 兼容性

### 支持机型

| 机型 | 代号 | 实机验证 |
| --- | --- | --- |
| Pixel 9 Pro | `caiman` | Android 17 QPR2 Beta 7.1，APatch 0.13.8 + Hybrid Mount |
| Pixel 9 Pro XL | `komodo` | 代码适配，无 XL 验证测试 |

### Root 与挂载方式

APatch / KernelSU 通过 MetaModule 挂载配置，KernelSU 的代码适配范围为 0.9+。

- 使用 **Hybrid Mount** 时，温控和 UECap 可在 WebUI 更改，重启后生效。
- 使用 **meta-overlayfs** 时，两项配置在安装时选择，更换档位可能需重装 Control。
- 使用 **Magisk v27+** 时，安装时可选温控，UECap 沿用系统配置。

**独立基带模块（仅供 Pixel 9 Pro设备）** `pixel9pro_baseband_trial` 提供运营商配置、APN、China MCFG 和 IMS 属性，单独安装与升级。

---

## 核心功能与技术说明

### 1. 温控策略

| 档位 | 阈值偏移 | 效果 |
| --- | --- | --- |
| 系统温控（默认） | 未修改 | 保持设备默认温控表 |
| 提前介入 | −2°C | 更早触发温控 |
| 轻度放宽 / 中度放宽 / 最大放宽 | +2 / +4 / +6°C | 逐档延后介入，接近关机阈值时收窄偏移 |

自定义档位基于本机原始配置生成，作用于 `VIRTUAL-SKIN` 及 HINT、SOC、CPU、GPU 等 8 组相关传感器。各档保留原厂关机阈值和恢复温差（`HotHysteresis`），具体介入温度随系统构建而定。

Hybrid Mount 下，WebUI 保存后显示**待重启**，同一次启动内可撤销。重启后，模块核对系统实际可见的配置文件、权限和 SELinux 上下文。

### 2. CPU 调度与外部调度器协同

| Pixel 档位 | 前台应用 `top-app` | 小 / 中 / 大核响应时间 | `uclamp.min` 上限 |
| --- | --- | --- | --- |
| 均衡 | CPU 0–6 | 16 / 64 / 240 ms | 0 |
| 省电 | CPU 0–6 | 16 / 96 / 320 ms | 0 |
| 默认升频响应 | CPU 0–7 | 读取内核 `response_time_ms_nom` | 1024 |

未启用 UGT 且调度节点齐全时，首次安装默认选**均衡**。默认升频响应仍由模块管理核心分配，频率上下限保留给系统温控与 Power HAL。选择**自动**后，亮屏时按机身温度切换均衡与省电。放电达到 38.8°C、充电达到 39.8°C 并持续 60 秒时进入省电，降至 37.5°C 并持续 120 秒后回到均衡。充电时系统温控等级达到 2 也会触发省电。

- **基础调度**可由 Pixel 或 Uperf Game Turbo（UGT）承担。首次安装检测到已启用的 UGT 时沿用 UGT。切换基础调度需重启；APatch 可从 WebUI 暂存，KernelSU / Magisk 通过各自管理器启停 UGT。
- **游戏临时接管**由 fas-rs 承担。启用接管且命中白名单进程时让出调度，退出后恢复原基础调度。控制台分别显示所选基础调度和当前实际接管者。

### 3. ZRAM 与内存管理

| 操作 | 内容 | 生效时间 |
| --- | --- | --- |
| 临时应用 | 单独调整交换区容量、压缩算法或四项 VM 参数 | 本次启动。在线重建需满足内存余量、回写状态和平台接口要求 |
| 保存开机设置 | 保存所选参数及「开机自动应用」开关，默认关闭 | 启用后在系统初始化 ZRAM 前提交容量与算法，系统就绪后应用 VM 参数 |
| 恢复原始参数 | 重新读取本机构建的原始配置，核对容量、算法及 VM 参数 | 按页面回执确认当前结果；开机设置另行保存 |

模块预设取本机原始容量和算法，`swappiness` 设为 `80`，`min_free_kbytes` 设为 `65536`，其余两项沿用原始值。MMD 扩展按实际 `mmd_setup`、设备节点和内核算法开放。控制台分别显示保存值、实际参数和交换区是否已启用。

### 4. 网络与待机控制

#### UECap 载波组合

| 机型 | 可选配置 | 首次默认 |
| --- | --- | --- |
| `caiman` | **中国载波组合**（`balanced`，原厂基础上增加 25 组）、**扩展载波组合**（`special`，增加 52 组）、**Google 默认**（`universal`） | 中国载波组合 |
| `komodo` | **Pro XL 原始配置**（`stock`）、**Pro XL 测试配置**（`candidate`，来源构建未确认） | Pro XL 原始配置 |

UECap 描述手机向基站上报的载波组合。两款设备使用各自的 `PLATFORM_*.binarypb` 文件。保存选择、重启后核对系统文件、确认基带已加载是三个不同状态；实际接入制式还取决于运营商和无线环境。Magisk 下停用 UECap 覆盖，以规避基带读取与挂载时序冲突。

#### NR 息屏降级与待机

- **NR 息屏降级**默认关闭。开启后，息屏满 300 秒并满足冷却条件时，后台在下一次检查中临时调整首卡移动网络制式，优先 LTE。开启热点时不执行本项设置。检测到亮屏后恢复模块改过的设置，并保留其他卡槽和用户后续修改。
- **待机设置**随后台策略应用，开启自适应连接和系统网络建议，关闭 Wi-Fi 下蜂窝数据常驻及 Nearby Sharing 相关开关。
- **SIM2 空槽管理**默认开启。开机及亮屏检查确认主卡就绪、副卡为空时，请求切为单卡。副卡锁定或仍在初始化时不会按空槽处理；关闭管理可恢复由模块停用的双卡实例。
- **网络校时**可选阿里云（默认）、华为云、小米或 Google。系统页分别反馈服务器保存结果和网络时间获取结果。**系统 DNS 缓存**可从网络页手动清理。

### 5. 后台应用限制、温度历史与审计日志

- **后台应用限制**由用户按需添加，仅作用于主用户（`user 0`），最多保存 32 个应用。列表显示上次核对结果，未完成的变更可在页面恢复。
- **温度历史**亮屏约每 60 秒采样，息屏约每 900 秒读取机身或电池温度，系统休眠可延后记录。关闭模块后台总开关会暂停采样、启动恢复及自动策略。手动操作、已有历史查询与导出仍可使用。
- **模块运行日志**保存在 `/data/adb/pixel9pro_control/logs/events.log`。单份约 256 KiB，保留 3 份轮转历史。事件记录版本、机型、阶段、结果和耗时等摘要；本页操作记录另行展示，可筛选并导出。

---

## 安装与升级

### 前置条件

确认设备代号与 Root 方案。APatch / KernelSU 需要先启用对应的 MetaModule 并重启；Magisk 使用其模块管理器。安装包见 [GitHub Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases)。

### 首次安装

1. 在 Root 管理器中选择 Control ZIP。向导使用**音量上切换、音量下确认**，30 秒无输入保留当前项。
2. 依次核对温控、CPU、UECap、NR、SIM2、ZRAM/VM 与网络校时。向导按当前机型和能力提供选项。内存预设仅在原始参数与开机接口均可用时提供；选择系统管理可在安装后继续手调。
3. 在末尾摘要核对选择，继续或取消安装。管理器显示安装完成后重启，打开控制台核对版本、温控和网络配置的实际状态。

### 升级与挂载后端差异

支持 `updateJson` 的管理器可读取仓库的 `update.json` 检查更新。覆盖升级迁移已有选择和历史；旧版若有未完成的温控、内存或后台限制事务，请先按旧版控制台提示处理。此前关闭的模块调度在节点可用时可于升级向导选择重新启用，默认保留关闭。

Hybrid Mount 使用常规模块文件，更改温控或 UECap 后重启核对。内容镜像适配已识别的 meta-overlayfs 1.3.1 安装接口。检测到旧 Control 内容时，按**卸载 Control → 重启 → 安装新版 → 重启**处理，并在首次安装向导选择目标档位。独立基带模块按其发行说明升级。

---

## WebUI 控制台

APatch / KernelSU 可从支持异步 `spawn` 的管理器打开。或从受支持的本机浏览器访问 `http://127.0.0.1:6210`，服务通过回环连接的 UID 和浏览器包身份建立会话。连接中断后可点**重新连接**。

控制台分为**状态、性能与温控、网络、系统**四页。状态页可打开「日志分析与导出」，系统页可开关模块后台任务。温控提交后可关闭弹窗，再次打开时查看回读结果。

---

## 故障排除与恢复

| 现象 | 处理方式 |
| --- | --- |
| 安装后停在开机动画 | 使用当前 Root 管理器的安全模式禁用模块，进入系统后在管理器卸载 Control 并重启。重新安装时先选系统温控 |
| 页面提示须重新安装或存在旧内容镜像 | 使用 meta-overlayfs 时先卸载旧 Control 并重启，再安装并选择目标配置 |
| 重启后页面仍显示旧版本 | 先核对管理器中的已安装版本，再刷新或用 `http://127.0.0.1:6210/?r=1` 重新打开；可更换参数值绕过页面缓存 |
| 显示「待重启」或「基带加载未知」 | 前者表示选择已保存，后者表示尚无基带加载证据；可在网络页查看当前文件及无线状态 |

---

## 本地测试

在仓库根目录按需运行。浏览器回归使用 Playwright，温控测试使用 Windows PowerShell。

```sh
npm ci
npm run test:webui:contract
npm run test:webui
npm run test:thermal
```

## 致谢

- [Sun_Dream（酷安）](https://www.coolapk.com/u/1281808) — `cpuset`、`sched_pixel` 调度思路及基带模块 PLMN / CarrierSettings 设计。
- [nr5g.cz](https://web.archive.org/web/20251127161227/https://www.nr5g.cz/posts/binarybp_edit.html) — Pixel 9 UE 能力文件编解码与 5G 载波聚合教程。
- [pixel9-EU-combos](https://github.com/etnperlong/pixel9-EU-combos) — Shannon NR 能力文件的 Protobuf 定义。
- [NXij / pixel-pb](https://github.com/NXij/pixel-pb) — UECap 配置编辑与打包工具。
- [DYSBRT（酷安）](https://www.coolapk.com/u/22128139) — Pixel 5G CA 配置指导。
- [Uperf Game Turbo](https://github.com/yinwanxi/Uperf-Game-Turbo) / fas-rs — 外部调度器项目。

## 免责声明

放宽温控阈值可能增加发热，调度与内存参数会影响响应和稳定性，蜂窝网络策略可能影响连接。使用者自行评估并承担安装及使用风险。Pixel、Android、Tensor 和 Material Design 为 Google LLC 的商标，本项目与 Google LLC 无关联。
