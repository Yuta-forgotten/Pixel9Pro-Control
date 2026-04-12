# Pixel 9 Pro 温控调度控制台

> **APatch / KernelSU 模块** | Pixel 9 Pro (caiman · Tensor G4) | Android 15 / 16 / 17 Beta

一个用于 Pixel 9 Pro 的温控节流阈值调整 + CPU 调度档位切换模块，附带一个**完全没有技术含量、画蛇添足的 WebUI**。  
100% Vibe Coding（AI 生成），基于 [WZL203/Pixel-8-pro-thermal-SOC-Charging-controlnl](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-controlnl) 的模块结构原理。

---

## 功能

| 功能 | 说明 |
|------|------|
| 温控节流阈值 | VIRTUAL-SKIN 性能链路 +0 / +2 / +4 / +6°C，WebUI 在线切换，通常无需重启 |
| CPU 调度档位 | 游戏 / 平衡 / 省电 / Google 原版，调节 sched_pixel 调速器参数与 cpuset |
| WebUI | 本地 HTTP 服务器（busybox httpd），端口 6210，Tab 栏界面 |
| 实时温度 | 从 `dumpsys thermalservice` 读取 VIRTUAL-SKIN（HAL 虚拟传感器） |
| 实时频率 | 每 3 秒轮询三簇 CPU 频率，页面隐藏时自动停止 |

**WebUI 访问方式：**
```
# ADB 端口转发后在 PC 浏览器访问
adb forward tcp:6210 tcp:6210
http://127.0.0.1:6210

# 或在手机 Chrome 直接访问
http://127.0.0.1:6210
```

---

## ⚠️ 已知问题

### APatch Manager「打开」按钮无法直接启动 WebUI

APatch Manager 的「打开」按钮以 `file://` 协议在内置 WebView 中加载页面，此时所有 `fetch()` 请求均失败。模块已加入 intent:// 跳转兜底：

```javascript
if (location.protocol === 'file:') {
  location.href = 'intent://127.0.0.1:6210#Intent;scheme=http;end';
}
```

实测在部分 APatch 版本上可正常跳转到 Chrome，但**不保证所有版本均有效**。如跳转失败，请手动在 Chrome 输入 `http://127.0.0.1:6210`。

---

## 安装

1. 从 [Releases](../../releases) 下载最新 `Pixel9Pro_Control.zip`
2. 在 APatch / KernelSU 中安装模块
3. 重启手机
4. 访问 `http://127.0.0.1:6210`

---

## 自行构建

```bash
# 1. 从设备拉取原版热控配置
adb pull /vendor/etc/thermal_info_config.json etc/

# 2. 构建 ZIP
python build.py

# 3. 推送到手机
adb push Pixel9Pro_Control.zip /sdcard/Download/
```

---

## ⚠️ 重要安全提醒

以下是实际踩坑总结，**忽略任何一条都可能导致 bootloop**：

### 1. HotThreshold 必须严格单调递增
`thermal_info_config.json` 中每个传感器的 `HotThreshold` 数组（忽略 `"NAN"`）必须**严格单调递增**。相邻两档值相等会导致 `thermalserviced` 崩溃，触发 APatch Safe Mode / bootloop。

```
❌ 错误：["NAN", 43.0, 43.0, 45.0, ...]   ← [1] == [2] → bootloop
✅ 正确：["NAN", 43.0, 47.0, 49.0, ...]   ← 全档整体平移，间距不变
```

### 2. 不要碰充电链路传感器
- `VIRTUAL-SKIN-CHARGE-PERSIST`：**绝对不能修改**，改动直接导致 thermal service 拒绝启动（XDA 实测）
- `VIRTUAL-SKIN-CHARGE-WIRED`：建议不改，除非确认安全

### 3. 不要包含辅助温控文件
只覆盖主文件 `thermal_info_config.json`，不包含：
- `thermal_info_config_charge.json`
- `thermal_info_config_lpm.json`  
- `thermal_info_config_bg_tasks_throttling.json`

### 4. ZIP 必须用 Python 打包
PowerShell `Compress-Archive` 生成**反斜杠路径**，Android unzip 无法识别，文件不存在。必须用 `build.py`（Python zipfile 模块）打包。

### 5. service.sh 中不能过早写 cpufreq
开机约 0~5s 内 ACPM 协处理器未完成初始化，此时写高 `min_freq`（尤其 cpu7 > 1700 MHz）会触发硬件保护重启。`service.sh` 中必须等待 `sys.boot_completed=1` 后再额外 `sleep 20`。

### 6. module.prop 必须是 LF 换行
Windows 编辑器默认 CRLF，APatch 解析会乱码。本仓库已通过 `.gitattributes` 强制 LF。

### 7. APatch Safe Mode 取证方式
若安装后卡第二屏，不要去 fastboot，直接等系统进 Android 后用 ADB 拉日志：
```bash
adb logcat -b all -d > safe_mode_logcat.txt
adb exec-out su -c cat /data/adb/ap/log/locat.log > ap_locat.log
```

---

## 温控改动范围

| 传感器 | Stock 第1档 | +4°C 默认 | 说明 |
|--------|------------|-----------|------|
| VIRTUAL-SKIN | 39°C | **43°C** | 主控传感器 |
| VIRTUAL-SKIN-HINT | 37°C | **41°C** | 性能提示节流 |
| VIRTUAL-SKIN-SOC | 37°C | **41°C** | CPU+GPU+TPU |
| VIRTUAL-SKIN-CHARGE-* | — | **不修改** | 充电链路，不碰 |

所有档位整体平移（+0/+2/+4/+6°C），严格保持单调递增。

---

## CPU 调度档位

| 档位 | 小核 max | 中核 max | 大核 max | cpuset |
|------|---------|---------|---------|--------|
| 游戏 | 1950 MHz | 2600 MHz | 3105 MHz | 全核 |
| 平衡 | 1548 MHz | 全速 | 全速 | 前台 App 独享 cpu4-7 |
| 省电 | 1200 MHz | 1795 MHz | 1885 MHz | 默认 |
| 原版 | 系统默认 | 系统默认 | 系统默认 | 默认 |

> 只修改 sched_pixel 调速器参数，不修改 `scaling_min_freq`（避免 ACPM 冷启动崩溃）

---

## 参考

- [WZL203/Pixel-8-pro-thermal-SOC-Charging-controlnl](https://github.com/WZL203/Pixel-8-pro-thermal-SOC-Charging-controlnl) — 模块结构参考
- [APatch bootloop rescue](https://apatch.dev/rescue-bootloop.html)
- [KernelSU module guide](https://kernelsu.org/guide/module.html)
- XDA [[MOD] Thermal-Throttling-Modifier [Pixel 9/Pro/XL]](https://xdaforums.com/t/mod-thermal-throttling-modifier-pixel-9-pro-xl.4690006/)

---

## 免责声明

本模块修改了设备热节流阈值，设备会在更高温度下才开始降频，持续高负载时机身温度将高于原版。+4°C 偏移在 XDA 社区有验证先例，**风险由使用者自行承担**。

作者：Yuta | 100% Vibe Coding
