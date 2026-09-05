## v4.1.0 — 支持Pixel 9Pro XL （未经测试） + 温控修复 + NR 调整

### 新功能
- **Pixel 9 Pro XL (komodo) 支持**：安装时自动检测机型，刷入对应温控配置

### Bug 修复
- **温控档位首次点击失败 (B11)**：busybox httpd 杀死 CGI 进程时锁残留，导致首次切换返回 409。现已增加 PID 过期检测，自动回收 stale lock
- **温控偏移目标不完整**：新增 `VIRTUAL-SKIN-CPU-HIGH` 和 `VIRTUAL-SKIN-GPU` 两个传感器到偏移目标，此前遗漏了这两个 Pro/Pro XL 共有的节流传感器

### 调整
- **NR 息屏冷却**：恢复 NR 后冷却时间 10 分钟，减少频繁亮灭场景下的网络模式切换
- **customize.sh 重写**：安装时自动应用已保存的温控偏移量，升级后无需手动重选档位
- 顶栏滚动自动收起
- NTP 服务器选择功能 (阿里云/华为云/小米/Google)


### 安装

1. 下载 zip 附件
2. APatch / KernelSU → 模块 → 从存储安装
3. 安装器自动识别 Pro (caiman) 或 Pro XL (komodo) 并刷入对应温控
4. 重启

### 兼容性
- Pixel 9 Pro (caiman) ， Pixel 9 Pro XL (komodo)（未经测试）
- Android 17 Beta 3+ (SDK 37)
- APatch 0.10+ / KernelSU
