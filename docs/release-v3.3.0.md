# Release Notes — v3.3.0

**标题**：`v3.3.0 — WebUI 重构 + ZRAM lz77eh`

---

## 新增

### ZRAM / 内存优化
- **lz77eh 硬件压缩**：切换 Tensor G4 内置 Emerald Hill 压缩引擎，压缩率 29.5%
- **扩容至 11392MB**：从默认 50% RAM (~8GB) 扩展至 75% RAM
- **VM 参数调优**：swappiness 150→100，min_free_kbytes 27→64MB，vfs_cache_pressure 100→60

### WebUI v3.3 重构

**状态页重设计**
- Hero 卡显示当前 CPU 模式 · 温控档位 · VM 优化
- 实时监控区：机身温度 + CPU 频率+ ZRAM/内存摘要

**性能页**
- 长按 CPU 频率状态卡查看 sched_pixel 完整参数（cpuset 分配、resp_time、down_rate、governor）

**温控页**
- 长按节流档位卡片查看各阈值详细说明及背景

**优化页**
- 长按 ZRAM 卡片查看 lz77eh / swappiness / min_free_kbytes / vfs_cache_pressure 说明

**交互与体验**
- WebUI 自身内存占用显示（httpd RSS，实测 ~132KB）

---

## 已知限制
- 游戏模式（cpu0-7 全核）未经长时间测试，全核高频功耗较高，建议短时使用
- 未添加深色模式

