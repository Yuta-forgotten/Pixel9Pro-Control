# ZRAM / 内存调优技术文档

> Pixel 9 Pro (Tensor G4) · Android 17 Beta 3 · 16GB RAM
> 模块版本 v3.2.3+ · 2026-04-16

---

## 一、ZRAM 基础原理

ZRAM 是 Linux 内核模块，在 RAM 中创建一个压缩块设备作为 swap 分区。当系统内存不足时，内核将不活跃的匿名页（APP 内存）压缩后存入 ZRAM，腾出物理内存给前台进程。

```
APP 内存页 (4KB)
    ↓ 内存不足, 内核触发 swap-out
压缩引擎 (lz4 / lz77eh / zstd / lzo)
    ↓ 压缩后约 1-2KB
ZRAM 设备 (存在 RAM 中)
    ↓ APP 再次访问该页 → swap-in
解压引擎 → 还原为 4KB 交还 APP
```

### 与传统 swap 的区别

| 特性 | 传统 swap (磁盘) | ZRAM (内存压缩) |
|------|-----------------|----------------|
| 存储介质 | 闪存 / HDD | RAM |
| 速度 | 慢 (受 I/O 瓶颈) | 快 (内存速度) |
| 磁盘寿命 | 消耗写入次数 | 不影响闪存 |
| CPU 开销 | 低 | 取决于压缩算法 |
| 容量 | 不占 RAM | 压缩数据占用 RAM |

### ZRAM 的代价

ZRAM 不是免费的午餐：
- **RAM 占用**：压缩后的数据仍然存在 RAM 中。如果 ZRAM 存了 5GB 原始数据，按 3:1 压缩比计算，会占用约 1.7GB RAM。
- **CPU 开销**：每次 swap-in/out 都需要压缩或解压，消耗 CPU 算力。
- **延迟**：虽然比磁盘快得多，但解压仍比直接读内存慢数倍。

---

## 二、Tensor G4 的 Emerald Hill 硬件加速

### 什么是 Emerald Hill

Emerald Hill 是 Google Tensor SoC（从 G1 到 G4 每代都有）内置的**固定功能硬件压缩引擎**。它提供 LZ77 算法的硬件加速实现，专门用于 ZRAM 的内存页压缩/解压。

在内核中注册为压缩算法 `lz77eh`（LZ77 Emerald Hill）。

### 硬件加速 vs 软件压缩

```
软件压缩 (lz4/zstd/lzo):
  APP 内存页 → CPU 核心执行压缩算法 → 消耗 CPU 时间 → 产生热量 → 写入 ZRAM

硬件加速 (lz77eh):
  APP 内存页 → Emerald Hill 专用电路执行压缩 → CPU 几乎不参与 → 极低热量 → 写入 ZRAM
```

**核心优势**：
- **CPU 零开销**：压缩/解压不占用 CPU 算力，CPU 可以去做别的事情
- **低功耗**：专用硬件功耗远低于通用 CPU 做同样的计算
- **低发热**：对 Tensor G4 这种发热敏感的芯片尤为重要
- **压缩率更优**：实测 lz77eh 压缩率 29.5%，优于 lz4 的 38.1%

### 内核页面大小条件

Tensor G4 的 init.rc (`init.zumapro.board.rc`) 根据内核页面大小选择算法：

```
# 4KB 页面内核 → 使用 Emerald Hill 硬件加速
on load_persist_props_action && property:ro.boot.hardware.cpu.pagesize=4096
    setprop mmd.zram.comp_algorithm ${persist.vendor.zram_comp_algorithm:-lz77eh}

# 16KB 页面内核 → 使用软件 lzo-rle (EH 不兼容 16KB 页面)
on init && property:ro.boot.hardware.cpu.pagesize=16384
    write /sys/block/zram0/comp_algorithm lzo-rle
```

Android 17 Beta 3 (GEC77) 使用 **4KB 页面内核**（`ro.boot.hardware.cpu.pagesize=4096`），所以硬件支持 lz77eh。

---

## 三、压缩算法对比

### 可用算法

设备 `/sys/block/zram0/comp_algorithm` 列出所有可用算法：

```
lz77eh zstd [lz4] lzo-rle lzo
```

### 实测对比（Pixel 9 Pro 实际数据）

| 算法 | 压缩方式 | 压缩率 | CPU 开销 | 发热影响 | 适用场景 |
|------|---------|--------|---------|---------|---------|
| **lz77eh** | **硬件加速** | **29.5%** | **≈0** | **最低** | **日常 + 轻度游戏** |
| lz4 | 软件 | 38.1% | 低 | 低 | 通用 |
| lzo-rle | 软件 | ~35% | 低 | 低 | 16KB 页面内核 |
| zstd | 软件 | 20-25% | 中高 | **较高** | 小内存设备 |
| lzo | 软件 | ~37% | 低 | 低 | 兼容性 |

> 压缩率 = 压缩后大小 / 原始大小。**越低越好**。
> lz77eh 的 29.5% 意味着 1GB 原始数据压缩后只占 295MB RAM。

### 算法选择建议

- **16GB 内存 + 不打重度游戏 + 关心发热**：选 `lz77eh`（最佳）
- **16GB 内存 + 通用场景**：`lz4` 也可以（出厂默认）
- **小内存设备 (4-8GB)**：`zstd` 更好（压缩率优先，牺牲 CPU）
- **16KB 页面内核**：只能用 `lzo-rle`（Emerald Hill 不兼容）

---

## 四、原厂配置分析

### 出厂 ZRAM 配置

| 参数 | 出厂值 | 来源 |
|------|--------|------|
| 压缩算法 | **lz4** | `persist.vendor.zram_comp_algorithm=lz4` |
| ZRAM 大小 | **50% RAM ≈ 8GB** | `fstab.zram.50p`（`vendor.zram.size=50p`）|
| backing_dev | `/dev/block/loop52` (1GB) | `fstab.zram.50p` 配置 |
| page-cluster | **0** | `init.zumapro.board.rc` |

### 出厂 VM 参数

| 参数 | 出厂值 | 含义 |
|------|--------|------|
| swappiness | **150** | 极度倾向换出匿名页保留文件缓存 |
| min_free_kbytes | **27386** (~27MB) | kswapd 唤醒门槛 |
| vfs_cache_pressure | **100** | 文件缓存元数据回收压力 |
| dirty_ratio | 20-40 | 脏页占比上限 |
| dirty_background_ratio | 5-10 | 后台写回触发线 |
| watermark_scale_factor | 50 | 水位线缩放 |
| watermark_boost_factor | 0 | 无水位线随机抖动 |
| overcommit_memory | 1 | 始终允许过度分配 |

### 出厂内存特性

| 特性 | 状态 |
|------|------|
| MGLRU (Multi-Gen LRU) | **已启用** (0x0003) |
| Transparent Huge Pages | **关闭** (never) |
| ZRAM idle writeback | 有 backing_dev 但**未实际使用** |
| KSM (内核同页合并) | 未启用 |

### ZRAM 大小选项（原厂 fstab 列表）

系统内含多个 fstab 变体，由 `vendor.zram.size` 属性选择：

| fstab 文件 | ZRAM 大小 | backing_dev | 适用场景 |
|-----------|-----------|-------------|---------|
| fstab.zram.2g | 2 GB | 512MB | 极小设备 |
| fstab.zram.3g | 3 GB | 1GB | 小设备 |
| fstab.zram.4g | 4 GB | 512MB | — |
| fstab.zram.5g | 5 GB | 512MB | — |
| fstab.zram.6g | 6 GB | 512MB | — |
| fstab.zram.40p | 40% RAM | 512MB | — |
| **fstab.zram.50p** | **50% RAM** | **1GB** | **Pixel 9 Pro 出厂选择** |
| fstab.zram.50p-1g | 50% RAM | 1GB | — |
| fstab.zram.50p-2g | 50% RAM | 2GB | — |
| fstab.zram.60p | 60% RAM | 512MB | — |

---

## 五、问题诊断（优化前的实测数据）

### 采集条件

- 待机 5 小时 51 分钟（USB 充电中）
- 出厂配置：lz4 + 11.12GB ZRAM + swappiness=150
- Clash Meta VPN 运行中，NR (5G) SA 连接

### 换页性能问题

| vmstat 指标 | 值 | 严重度 | 说明 |
|-------------|-----|--------|------|
| pswpout (换出) | 7,097,024 | — | 5.8h 内换出 700 万页 |
| pswpin (换入) | 3,071,966 | — | 300 万页又被读回 |
| **refault 比例** | **43%** | **高** | 换出的页面近半被立刻需要 |
| **pgmajfault** | **3,251,716** | **严重** | 每次都要 CPU 解压 |
| pgsteal_direct | 122,377 | 中 | kswapd 来不及，进程自己回收 |
| allocstall | 2,053 | 中 | 进程因等内存而阻塞 |
| oom_kill | 0 | 正常 | — |

### 根因分析

**swappiness=150** 在 16GB 设备上过于激进：
- 内核极度倾向将匿名页换出到 ZRAM（而非清理文件缓存）
- 43% 的换出页面很快又被需要（workingset_refault_anon = 3,071,941）
- 每次 refault 都要 CPU 做 lz4 解压 → 浪费算力 + 发热
- kswapd 有时来不及回收 → 进程直接回收（direct reclaim）→ 微卡顿

**min_free_kbytes=27MB** 偏低：
- kswapd 唤醒门槛（low watermark ~103MB）不够提前
- 2,053 次 allocstall 意味着进程被阻塞等待内存

**lz4 软件压缩**：
- 每次 swap-in/out 都要 CPU 压缩/解压
- 3.25M 次 pgmajfault × lz4 解压 = 大量 CPU 时间

### 内存分布（优化前快照）

```
总计 15.2 GB RAM:
├── 文件缓存 (Cached)     5.4 GB   35%
├── AnonPages              2.3 GB   15%
├── ZRAM 压缩数据          1.75 GB  11%  ← ZRAM 自身 RAM 开销
├── Slab (不可回收)        1.2 GB    8%
├── GPU                    880 MB    6%
├── ION heap               713 MB    5%
├── Free                   964 MB    6%
└── 其他 (内核栈/页表等)   ~700 MB   5%
```

---

## 六、模块优化方案

### 整体策略

| 层面 | 出厂配置 | 模块优化 | 变化效果 |
|------|---------|---------|---------|
| ZRAM 算法 | lz4 (软件) | **lz77eh (硬件加速)** | CPU 零开销、压缩率更优 |
| ZRAM 大小 | 8 GB (50% RAM) | **11392 MB (~75% RAM)** | 更多后台 APP 存活 |
| swappiness | 150 | **100** | 减少 43% 的无效换页 |
| min_free_kbytes | 27,386 | **65,536** (64MB) | 提前唤醒 kswapd、减少 allocstall |
| vfs_cache_pressure | 100 | **60** | 保留更多文件系统缓存元数据 |
| dirty_writeback_centisecs | 500 | **3000** (30s) | 减少脏页写回频率 |
| dirty_ratio | 20 | **50** | 允许更多脏页积累后批量写回 |
| dirty_background_ratio | 5 | **20** | 提高后台写回触发线 |

### 实现方式

#### ZRAM 算法 + 大小（需重启生效）

`service.sh` 在开机后执行：

```sh
# 1. 设置 persist 属性 → 后续重启 init.rc 直接用 lz77eh
setprop persist.vendor.zram_comp_algorithm lz77eh

# 2. 检查当前运行的 ZRAM 配置，不符合目标则重新配置
CURRENT_ALGO=... CURRENT_SIZE=...
if [ 不符合目标 ]; then
    swapoff /dev/block/zram0       # ① 关闭 swap，解压所有页面回 RAM
    echo 1 > reset                 # ② 重置 ZRAM 设备
    echo lz77eh > comp_algorithm   # ③ 设置硬件加速算法
    echo 11945377792 > disksize    # ④ 设置 11392MB
    mkswap /dev/block/zram0        # ⑤ 格式化
    swapon /dev/block/zram0        # ⑥ 启用
fi
```

**关键**：`persist.vendor.zram_comp_algorithm` 是跨重启保留的系统属性。设置后，init.rc 在下次开机时直接读取此属性使用 lz77eh，无需每次都做 swapoff/reset。ZRAM 大小无法通过属性设置，始终需要 service.sh 在开机后调整。

#### VM 参数（即时生效，无需重启）

直接写入 `/proc/sys/vm/` 即可：

```sh
echo 100   > /proc/sys/vm/swappiness
echo 65536 > /proc/sys/vm/min_free_kbytes
echo 60    > /proc/sys/vm/vfs_cache_pressure
```

这些参数在写入瞬间生效，但重启后恢复默认值。模块 `service.sh` 每次开机设置，WebUI 提供运行时一键切换。

---

## 七、各参数详解

### swappiness (150 → 100)

**作用**：控制内核在"换出匿名页"和"清理文件缓存"之间的倾向。

- **值越高**：越倾向换出匿名页到 ZRAM，保留文件缓存
- **值越低**：越倾向清理文件缓存，保留匿名页在 RAM

**为什么 16GB 设备不需要 150**：

Google 的 swappiness=150 是为 4-8GB 小内存设备优化的——内存紧张时必须激进换出匿名页来保留文件缓存，否则每次切换 APP 都要重新从闪存读取（冷启动慢）。

但在 16GB 设备上，Available 内存通常在 6GB 以上，有足够空间同时容纳匿名页和文件缓存。swappiness=150 导致大量不必要的换出（43% 的换出页面立刻又被需要），浪费 CPU 在无效的压缩/解压上。

swappiness=100 在 ZRAM 场景下已经比传统 swap 更积极（因为 ZRAM 远快于磁盘），同时避免了过度换页。

**数学依据**（来自 Linux 内核文档）：如果 swap 设备的随机 I/O 速度是文件系统的 2 倍，swappiness 应设为 133。ZRAM 虽然快，但不是无限快（需要压缩/解压），100 是保守但合理的值。

### min_free_kbytes (27MB → 64MB)

**作用**：内核保留的最小空闲内存量。影响 kswapd 的唤醒水位线。

水位线计算：
- **min** = min_free_kbytes（进程直接分配失败的底线）
- **low** ≈ min × 1.5~2（kswapd 唤醒线）
- **high** ≈ min × 2~3（kswapd 睡眠线）

27MB 时：kswapd 在空闲内存降到 ~100MB 才醒来，往往来不及回收，导致进程被迫做 direct reclaim（阻塞式的）。

64MB 时：kswapd 在 ~200-250MB 就醒来，提前开始后台回收，减少 direct reclaim 和 allocstall。

### vfs_cache_pressure (100 → 60)

**作用**：控制内核回收 dentry（目录项缓存）和 inode（文件元数据缓存）的倾向。

- **100**（默认）：公平回收，文件缓存元数据和普通页面以相同优先级回收
- **60**：降低回收倾向，更多地保留 dentry/inode 缓存

保留这些缓存能加速文件路径查找（`stat`、`open` 等系统调用），对 APP 启动和文件操作有明显帮助。

---

## 八、WebUI 控制

模块 WebUI (http://127.0.0.1:6210) 状态总览页的"内存调优"卡片提供：

### 显示内容

- **ZRAM 算法**：当前算法 + 是否为硬件加速 + 实时压缩率和 RAM 占用
- **ZRAM 大小**：当前大小 vs 原厂大小(8GB) vs 模块目标(11392MB)
- **VM 参数**：swappiness / min_free_kbytes / vfs_cache_pressure 当前值和状态

### 操作

- **"应用优化"按钮**：一键设置 VM 参数为优化值（swappiness=100, min_free_kbytes=64MB, vfs_cache_pressure=60），**即时生效**
- **"恢复原厂"按钮**：一键恢复 VM 参数为出厂值，**即时生效**

### 需重启 vs 即时生效

| 参数 | 修改方式 | 是否需要重启 |
|------|---------|-------------|
| ZRAM 算法 | service.sh swapoff/reset | **需要重启** |
| ZRAM 大小 | service.sh swapoff/reset | **需要重启** |
| swappiness | 写 /proc/sys/vm/ | 即时生效 |
| min_free_kbytes | 写 /proc/sys/vm/ | 即时生效 |
| vfs_cache_pressure | 写 /proc/sys/vm/ | 即时生效 |

---

## 九、诊断命令速查

### 查看当前 ZRAM 状态

```sh
# 当前算法
cat /sys/block/zram0/comp_algorithm
# → lz77eh zstd [lz4] lzo-rle lzo   (方括号=当前选中)

# 当前大小
cat /sys/block/zram0/disksize
# → 11945377792 (bytes = 11392MB)

# 压缩统计 (mm_stat)
cat /sys/block/zram0/mm_stat
# 字段: orig_data_size compr_data_size mem_used_total mem_limit
#        mem_used_max same_pages pages_compacted huge_pages huge_pages_since
```

### 查看 VM 参数

```sh
cat /proc/sys/vm/swappiness          # 目标: 100
cat /proc/sys/vm/min_free_kbytes     # 目标: 65536
cat /proc/sys/vm/vfs_cache_pressure  # 目标: 60
```

### 查看换页性能

```sh
# 关键 vmstat 计数器
cat /proc/vmstat | grep -E "pswpin|pswpout|pgmajfault|allocstall|workingset_refault"

# PSI 内存压力
cat /proc/pressure/memory
# → some avg10=0.00 avg60=0.25 avg300=0.23 total=36638781
# some: 至少有一个进程因内存而等待的时间比例
# full: 所有进程都因内存而等待的时间比例
```

### 查看 persist 属性

```sh
getprop persist.vendor.zram_comp_algorithm  # 目标: lz77eh
getprop mmd.zram.comp_algorithm              # 运行时值
getprop vendor.zram.size                     # 原厂 fstab 变体: 50p
```

---

## 十、与 Scene 的关系

本模块 **完全独立管理** ZRAM 算法、ZRAM 大小和 VM 参数，不依赖 Scene。

如果同时使用 Scene 的 SWAP Control：
- Scene 的"开机自启"可能与模块的 service.sh 冲突（两边都做 swapoff/reset）
- **建议**：关闭 Scene 的 ZRAM 开机自启，让模块全权管理
- Scene 的 VM Parameters 修改（如 swappiness）是即时写入，与模块不冲突（谁后执行谁生效）

---

## 十一、已知问题与注意事项

### 1. 快速连续 `apd module install` 可能导致温控服务崩溃

在活跃的开发/调试会话中，如果快速多次执行 `apd module install`（短时间内连续安装模块），APatch 的 OverlayFS（负责覆盖 `/vendor/etc/thermal_info_config.json`）可能出现短暂不一致。如果 `thermal-service.pixel` 恰好在此窗口重启，会读到不完整或缺失的温控配置，导致：

1. `thermal-service.pixel` 崩溃循环（Process uptime: 1s）
2. `system_server` 的 `BinderThreadMonitor` watchdog 阻塞触发（blocked for 15s）
3. `system_server` 进入 watchdog death loop（5 分钟内 4 轮重启）
4. 手机卡死在开机动画，需长按电源键强制重启（boot reason: `reboot,longkey,master_dc`）

**预防措施**：每次 `apd module install` 后等待约 5 秒，确认 OverlayFS 稳定后再进行下一次安装。这不是模块代码缺陷，而是 APatch OverlayFS 在热安装场景下的竞态问题。

### 2. SELinux 对 swap.sh 的 relabelfrom 拒绝日志

`dmesg` 中会出现类似以下的 SELinux deny 日志：

```
avc: denied { relabelfrom } for ... name="swap.sh" ...
```

这是因为 `webroot/cgi-bin/swap.sh` 是模块新增的文件，不在原厂 SELinux policy 的标签定义中。**此告警为纯日志噪音，不影响运行时功能**——swap.sh 的 CGI 调用通过 busybox httpd 正常执行，不受此 relabel 拒绝影响。

### 3. ZRAM 重配置的开机时序

`service.sh` 中的 ZRAM swapoff/reset/swapon 流程在开机第 ~48 秒执行（`boot_completed` 信号后延迟 20 秒），耗时约 0.2 秒。此时开机动画已结束、锁屏已就绪，**不会影响开机动画或解锁速度**。用户在正常使用中不会感知到这个操作。

---

## 附录：相关资源

- [Linux Kernel ZRAM Documentation](https://docs.kernel.org/admin-guide/blockdev/zram.html)
- [Arch Wiki: Zram](https://wiki.archlinux.org/title/Zram)
- [AnandTech: Tensor SoC (Emerald Hill)](https://www.anandtech.com/show/17032/tensor-soc-performance-efficiency)
- [USENIX: Adaptive Memory Reclaim for Android](https://www.usenix.org/system/files/atc20-liang-yu_0.pdf)
- [ElasticZRAM: Revisiting ZRAM for Mobile (DAC 2024)](https://dl.acm.org/doi/abs/10.1145/3649329.3655943)
