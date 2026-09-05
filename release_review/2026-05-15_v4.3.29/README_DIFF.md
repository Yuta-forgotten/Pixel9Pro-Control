# README.md 更新建议 — v4.3.29

> **状态**：草案，未写入 README.md。等小宝审阅后再决定是否套用。
> **影响范围**：仅 3 处需改，其他 200 行内容原样保留。

## 改动 1 — 顶部一句话简介（line 3）

```diff
-> APatch / KernelSU 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、CPU 调度、ZRAM、待机优化和 UE 网络控制模块。
+> APatch / KernelSU / Magisk 模块。为 Pixel 9 Pro / Pro XL (Tensor G4) 设计的温控阈值、CPU 调度、ZRAM、待机优化和 UE 网络控制模块。（Magisk 下基带 UE 切换不可用）。
```

## 改动 2 — 当前版本块（line 7-9）

```diff
 ## 当前版本

-- Release: `v4.3.27`
-- versionCode: `61`
-- Asset: `pixel9pro_control_v4.3.27.zip`
+- Release: `v4.3.29`
+- versionCode: `63`
+- Asset: `pixel9pro_control_v4.3.29.zip`
 - Module id: `pixel9pro_control`
 - WebUI: `http://127.0.0.1:6210`
```

## 改动 3 — 安装步骤（line 160-168）

```diff
 ## 安装

 1. 从 [Releases](https://github.com/Yuta-forgotten/Pixel9Pro-Control/releases) 下载 `pixel9pro_control.zip` 最新版
 2. KernelSU 用户需先安装 metamodule（如 `meta-overlayfs`）并重启
-3. APatch / KernelSU → 模块 → 从存储安装
-4. **首次安装**：音量键交互向导，可选择温控偏移、CPU 调度、UECap 档位、NR 降级、NTP
+3. APatch / KernelSU / Magisk → 模块 → 从存储安装
+4. **首次安装**：音量键交互向导，可选择温控偏移、CPU 调度、UECap 档位（仅 APatch/KSU）、NR 降级、NTP
 5. **升级安装**：自动迁移已有设置，无需重新配置
 6. 重启
 7. 打开 `http://127.0.0.1:6210` 验证
```

## 改动 4 — 兼容性章节（line 170-175，建议扩充）

```diff
 ## 兼容性

 - `Pixel 9 Pro (caiman)` / `Pixel 9 Pro XL (komodo)`
 - `Android 17 QPR1 Beta 1 (SDK 37)` 当前验证基线
 - `APatch ` 实机验证
 - `KernelSU 0.9+` 代码兼容（需 metamodule，未完成真机闭环）
+- `Magisk v27+` 代码兼容（v4.3.29 未完成真机闭环）

+### Root 实现差异

+| 功能 | APatch / KSU+metamodule | Magisk |
+|---|---|---|
+| 温控阈值偏移、CPU 调度、ZRAM、L1-L3 功耗、SIM2、NR 降级、WebUI | ✅ | ✅ |
+| UECap 三档基带切换 (balanced/special/universal) | ✅ | ❌ 不支持* |


```

---

## 不改的部分

以下章节经审视**不需要改**：

- 「支持设备」表格 — 设备列表无变化
- 「功能」三大节（CPU 调度 / 前台自动调度 / 三层功耗等）— v4.3.29 没改这些
- 「WebUI 功能」— 没变

- 「致谢」— （小宝定夺）
- 「免责声明」— 无需改

## 待小宝拍板

1. 改动 4 的 Root 实现差异表是否要加？（信息密度高但实用）
2. 「致谢」是否追加 `liyiqian2012` 名字？ 不追加
3. 「已知问题」是否补 Magisk 老版本卡 G logo 的提示？

姐姐等小宝点头之后再写进 README.md → commit → push。
