# Pixel 9 Pro 控制台 HTML 移动端设计规范

> 项目：`E:\Pixel ADB\pixel9pro_control_v2\webroot`
> 版本：v1.0
> 日期：2026-04-16
> 设计主轴：Material You / Material 3 Expressive
> 参考约束：iOS Human Interface Guidelines + MIUIX 组件组织方式
> 明确禁用：Liquid Glass 风格悬浮控件、悬浮导航条、悬浮 FAB、漂浮玻璃工具条

---

## 1. 审阅范围

本规范基于以下内容整理：

### 1.1 现有项目

- `E:\Pixel ADB\pixel9pro_control_v2\webroot\index.html`
- `E:\Pixel ADB\pixel9pro_control_v2\webroot\cgi-bin\*.sh`

已确认现有 WebUI 具备以下基础能力：

- 四个一级标签页：`状态 / 性能 / 温控 / 优化`
- 顶部安全区与底部安全区处理
- 横向手势切页
- 下拉刷新
- 实时轮询：CPU / 温控 / Swap
- Toast、弹层、底部弹窗、日志展开
- 详情信息通过长按触发

### 1.2 `E:\交互指南` 内容

已审阅目录内全部顶层内容，并对与本项目高度相关的内容重点细读：

- Apple 文档快照
  - `Layout _ Apple Developer Documentation.html`
  - `Positioning content relative to the safe area _ Apple Developer Documentation.html`
  - `Toolbars _ Apple Developer Documentation.html`
- Material 文档快照
  - `Understanding typography - Material Design.html`
- MIUIX 压缩包
  - `miuix-main.zip`，共 `953` 个条目
  - 重点阅读：`README.md`、`scaffold.md`、`navigationbar.md`、`card.md`、`button.md`、`overlaybottomsheet.md`、`searchbar.md`、`pulltorefresh.md`、`progressindicator.md`、`iconbutton.md`、`floatingactionbutton.md`、`floatingtoolbar.md`
- Material Components Android 压缩包
  - `material-components-android-master.zip`，共 `6667` 个条目
  - 重点阅读：Adaptive demo、Bottom Sheet、Bottom App Bar、Card、Button 相关 catalog/demo 源码

### 1.3 额外官方核对

为避免设计术语和平台约束过时，额外核对了官方资料：

- Google Android Developers：Material 3 / Expressive 设计系统页
- Android Developers Blog：Material 3 Expressive 介绍
- Apple HIG：Layout / Toolbars / Tab Bars / Safe Area

---

## 2. 现状审计结论

现有 `webroot/index.html` 不是空白页，而是一套已经可以运行的移动控制台。它的结构是对的，但视觉语言和交互层级需要重构。

### 2.1 应保留的部分

- 保留四标签信息架构，原因是当前后端接口已经按业务域拆分。
- 保留单页应用式切页，原因是控制台类工具需要快切换、少跳转。
- 保留底部标签导航，原因是一级入口稳定且频繁切换。
- 保留温控、性能、优化三类“可执行配置”，原因是任务导向明确。
- 保留底部弹层，原因是说明、确认、二级操作更适合用 sheet 而不是新页面。
- 保留下拉刷新与实时轮询，但要重做视觉表现。
- 保留状态总览页中的“当前模式 + 实时温度 + CPU 频率 + 设备信息”结构。

### 2.2 必须调整的部分

- 当前页面大量使用 `backdrop-filter`、模糊背景图、半透明白卡片，整体更像玻璃态展示页，不像高密度控制台。
- 卡片、标签栏、Toast、弹层都带明显悬浮感，层级太接近，导致“什么是内容、什么是动作、什么是系统反馈”不够清楚。
- 首页和配置页都依赖小字号说明文字，主次关系偏弱，尤其在中文阅读下显得碎。
- 当前页面把很多说明行为藏在长按里，可发现性偏低，不符合 iOS 和 MIUIX 对主交互可见性的要求。
- 标签栏使用顶部细线指示器，识别弱，且不符合 Material 3 选中态容器的表达方式。
- 背景模糊图片长期存在，会稀释数据密度，也会让“实时监控”场景显得不够稳。
- `toast` 和 `pull-ind` 呈漂浮状态，不够贴边，不够系统化。

### 2.3 明确删除的部分

- 删除大面积玻璃态卡片
- 删除漂浮式工具条视觉
- 删除悬浮式底部导航
- 删除液态玻璃、悬浮胶囊、漂浮圆盘刷新指示器
- 删除“只有长按才看得到详情”的单一交互路径

---

## 3. 目标设计定位

目标不是把当前控制台做成普通 Android 设置页，也不是做成 iOS 拟物工具页，而是：

**以 Material 3 Expressive 的层级、形状、状态表达作为主体；**
**以 iOS 的安全区、工具栏、底部栏约束作为结构纪律；**
**以 MIUIX 的分组列表、卡片组织、偏好设置密度作为落地方式。**

最终页面应呈现为：

- 有明显重点信息的控制台
- 有温度感但不漂浮的表面系统
- 有足够表达力，但不为了“炫”牺牲操作清晰度
- 第一眼能看懂当前状态，第二眼能快速执行切换

一句话定义：

**“贴边、稳态、分层明确、重点鲜明的移动控制台”，而不是“发光漂浮的概念 UI”。**

---

## 4. 总体设计原则

### 4.1 Material 3 Expressive 原则落地

- 用更强的标题对比、状态色、选中容器、形状变化来表达重点。
- 重点表达只放在一级状态区、当前选中项、关键数值，不铺满全界面。
- 通过色阶与容器层级区分信息，而不是靠重度模糊和悬浮阴影。
- 强调“当前模式”“当前阈值”“当前实时温度”的即时识别。

### 4.2 iOS 结构纪律

- 顶部内容必须尊重 safe area，标题和操作按钮不能压进状态栏区域。
- 底部标签栏必须贴边并吞入安全区，而不是悬浮在内容上方。
- 工具栏和标签栏优先承载一级操作；二级操作进入 sheet 或卡片内动作区。
- 内容可滚动，导航层和系统反馈层不应与内容抢视觉焦点。

### 4.3 MIUIX 组织方式

- 采用“页面容器 + 分组卡片 + 偏好项行”的稳定结构。
- 列表项允许高密度，但必须有统一的左右边距、行高、分组间距。
- 选中态要清楚，最好用“容器变化 + 勾选/强调图标”，而不是只改文字颜色。
- 底部 Sheet、按钮、图标按钮都遵循圆角容器语言，但不悬浮发光。

---

## 5. 信息架构建议

现有四个一级标签页保留，但每页职责要更清晰。

| 一级页 | 目标 | 核心内容 | 次级内容 |
|---|---|---|---|
| 状态 | 3 秒内看懂机器当前状态 | 当前模式、机身温度、CPU 摘要、内存摘要 | 设备信息、最近操作 |
| 性能 | 修改调度策略 | 当前模式摘要、实时频率、模式列表 | 参数说明、风险提醒 |
| 温控 | 修改节流阈值 | 当前温度、阈值刻度、节流档位 | 安全提示、档位解释 |
| 优化 | 查看并切换系统优化策略 | 优化项状态、ZRAM/Swap 当前配置 | 详细说明、恢复入口 |

### 5.1 首页结构

首页不应该是“所有东西都堆一点”，而应是：

1. 当前模式 Hero
2. 实时监控双主卡
3. 系统摘要分组
4. 设备信息
5. 操作记录

### 5.2 配置页结构

“性能 / 温控 / 优化”三页都遵循同一骨架：

1. 页面标题
2. 当前状态摘要卡
3. 主列表或主卡片区
4. 说明区或风险区
5. 二级详情通过 sheet 展开

---

## 6. 页面骨架规范

### 6.1 整体结构

建议 HTML 骨架固定为：

```html
<body class="app-shell">
  <header class="top-app-bar"></header>
  <main class="page-host">
    <section class="page page-home is-active"></section>
    <section class="page page-perf"></section>
    <section class="page page-thermal"></section>
    <section class="page page-optim"></section>
  </main>
  <nav class="bottom-nav"></nav>
  <div class="sheet-host"></div>
  <div class="snackbar-host"></div>
</body>
```

### 6.2 安全区

- 顶部栏高度：`56px + env(safe-area-inset-top)`
- 底部栏高度：`64px + env(safe-area-inset-bottom)`
- 页面主内容 padding：
  - 上：`12px`
  - 左右：`16px`
  - 下：`24px`
- 页面滚动区只允许在 `main` 内部发生，不允许整页随意抖动。

### 6.3 栅格与间距

- 基础间距单位：`4px`
- 页面左右边距：`16px`
- 大区块间距：`24px`
- 分组内卡片间距：`12px`
- 紧凑信息块间距：`8px`

### 6.4 响应式范围

- 主设计宽度：`360px - 430px`
- `>= 390px` 时允许双列指标卡
- `< 360px` 时所有指标卡强制单列

---

## 7. 视觉语言规范

### 7.1 背景策略

禁止继续使用当前的“模糊背景图 + 半透明磨砂卡片”方案。

改为：

- 主背景使用浅色 tonal gradient
- 只允许非常轻的色带或纹理，不允许大面积照片模糊
- 页面视觉重点由卡片层级与标题建立，不由背景建立

推荐背景：

```css
--bg-canvas:
  linear-gradient(
    180deg,
    #f6fbf8 0%,
    #eff6f2 44%,
    #f7f5ef 100%
  );
```

### 7.2 色彩角色

建议使用现有绿色温控语义作为种子色，但做成 Material 3 tonal 角色，而不是单一绿色通刷。

推荐角色：

- `primary`：当前选中、主操作、关键强调
- `primary-container`：选中卡、当前模式背景
- `surface`：页面基底
- `surface-container`：普通卡片
- `surface-container-high`：重点卡片
- `secondary-container`：次强调区
- `error / error-container`：失败、危险操作
- `tertiary`：热量、性能等辅助高亮

建议状态色语义：

- 正常：冷静青绿
- 提示：暖黄
- 风险：橙红
- 故障：深红

### 7.3 字体策略

中文环境不建议只用 `Roboto/system-ui`。

建议字体栈：

```css
font-family:
  "MiSans VF",
  "Google Sans Text",
  "PingFang SC",
  "Noto Sans SC",
  sans-serif;
```

数值字体：

```css
font-variant-numeric: tabular-nums;
```

### 7.4 字号层级

建议统一为下列层级：

| 角色 | 字号/行高 | 字重 | 用途 |
|---|---|---|---|
| Display | 36 / 40 | 700 | 首页关键状态数字 |
| Headline | 28 / 32 | 650 | 页面主标题、大标题 |
| Title L | 22 / 28 | 650 | Hero 标题 |
| Title M | 18 / 24 | 600 | 卡片标题 |
| Body M | 15 / 22 | 400 | 常规说明 |
| Body S | 13 / 18 | 400 | 补充说明 |
| Label L | 14 / 18 | 600 | 按钮文字 |
| Label S | 12 / 16 | 600 | 标签、状态徽标 |

规范要求：

- 禁止在主要内容区大量使用 `10px - 11px` 作为默认说明字号。
- Section Label 可以保留小号，但不能承担关键信息。
- 中文界面避免过度 letter-spacing 和全大写气质。

### 7.5 形状与阴影

建议圆角体系：

- `16px`：小按钮、小标签
- `20px`：普通卡片
- `24px`：大卡片
- `28px`：Hero、Bottom Sheet 顶角

阴影策略：

- 阴影只作为轻微分层，不制造漂浮
- 常规卡片阴影不超过 `0 2px 8px rgba(0,0,0,.06)`
- 选中态优先使用描边和容器色变化，不使用发光

---

## 8. 组件规范

## 8.1 Top App Bar

建议采用 Medium Top App Bar：

- 高度：`56px`
- 标题靠左
- 右侧最多放 `1-2` 个图标动作
- 图标按钮最小点击区域：`44px`

规则：

- 顶栏背景为高不透明 surface，不用玻璃磨砂。
- 首页标题可做大标题滚动收缩；其他页保持稳定标题。
- 刷新动作放入标题栏或 section header，不做悬浮刷新按钮。

## 8.2 Bottom Navigation

必须使用贴边式底部导航，不使用浮动底栏。

规则：

- 4 个 item 保持现状
- 每个 item 由图标 + 标签组成
- 选中态使用低高度的 filled container，而不是顶部细线
- 导航栏背景使用高不透明 `surface-container`
- 顶部分隔线可保留，但要极轻

不建议：

- 不建议使用顶部细线 indicator
- 不建议使用玻璃胶囊底栏
- 不建议使用完全透明底栏

## 8.3 Hero 状态卡

当前 `hero-card` 的信息结构可保留，但视觉应改成：

- 大尺寸实色/浅色容器
- 左侧图标区为显性圆角块
- 中央主标题为当前模式
- 下方副文案只保留一行核心信息
- 右上可显示状态 chip

Hero 卡职责：

- 只显示“当前最重要状态”
- 不承担大量参数列表
- 每页只保留一个 Hero

## 8.4 指标卡

适用于温度、CPU、内存等摘要信息。

规则：

- 支持单列和双列
- 数值大，标题小
- 状态文案必须就近出现
- 颜色只强调当前数据，不让整个卡片变成强饱和色

推荐布局：

- 标题
- 大号数值
- 次级说明
- 可选趋势/阈值条

## 8.5 模式卡 / 预设卡

当前 `profile-card` 与 `thermal-list` 的业务结构正确，但 UI 需要从“大片玻璃卡”改为“可选偏好项卡”。

推荐样式：

- 左：图标或模式标识
- 中：标题 + 单行说明
- 右：选中图标 / 当前状态
- 整卡可点击
- 选中态显示更明显的容器色和勾选

强制要求：

- 增加显式“详情”入口
- 长按可保留为补充交互，但不能是唯一详情入口

## 8.6 Button

按钮分为三级：

- Primary Filled：执行主要切换
- Secondary Tonal：刷新、次级应用
- Text / Ghost：关闭、取消、查看详情

尺寸要求：

- 按钮高度：`44px - 48px`
- 圆角：`16px`
- 图标按钮尺寸：`40px - 44px`

## 8.7 Badge / Status Chip

适用于：

- 当前激活
- 已优化 / 已关闭
- 风险 / 警告

规则：

- 只用于短文本
- 不承载长句
- 使用中低对比填充，不要高亮到抢标题

## 8.8 Bottom Sheet

当前 `modal-sheet` 的结构方向是正确的，但应升级为统一规范：

- 顶部拖拽条
- 标题
- 简述
- 滚动内容区
- 底部动作区

建议使用场景：

- 模式详情
- 温控详情
- 重启确认
- ZRAM 详细说明

规则：

- 高度建议 `60vh - 80vh`
- 顶角 `28px`
- 默认允许拖拽关闭
- 对危险操作保留明确主次按钮

不建议再使用：

- 居中的小弹窗承载大量说明文字

## 8.9 Snackbar / Toast

反馈必须从“漂浮消息泡”改为更系统化的底部反馈条。

规则：

- 贴近底部导航上缘
- 水平居中但不悬浮过高
- 宽度建议 `calc(100% - 24px)`
- 成功、失败、处理中有明确色义

## 8.10 Pull To Refresh

现有功能保留，但视觉建议改为：

- 指示器固定在页面顶部内容区下缘
- 不使用漂浮圆盘
- 可带文字状态：
  - 下拉刷新
  - 释放刷新
  - 正在刷新
  - 已完成

## 8.11 Log / 操作记录

日志不是一级主内容，建议：

- 首页只保留折叠摘要
- 详细日志进入 sheet 或独立详情区
- 默认闭合

---

## 9. 当前页面到新规范的映射

| 现有实现 | 处理方式 | 新规范 |
|---|---|---|
| `.bg-img` + `.bg-tint` | 替换 | 改为 tonal 渐变背景 |
| `.card` 玻璃磨砂卡片 | 替换 | 改为实色 surface card |
| `.tab-bar` 半透明底栏 | 替换 | 改为贴边底部导航 |
| `.tab-item::before` 顶部细线 | 替换 | 改为选中态容器 |
| `.hero-card` | 保留结构、重做视觉 | 表达当前模式的主 Hero |
| `.profile-card` | 保留业务结构、重做组件层级 | 可选偏好项卡 |
| `.modal-sheet` | 保留机制、统一规范 | 标准 Bottom Sheet |
| `.toast-wrap` 漂浮消息 | 替换 | 贴边 Snackbar Host |
| `.pull-ind` 漂浮刷新指示器 | 替换 | 顶部锚定式刷新反馈 |
| 长按详情 | 降级为补充交互 | 增加显式详情入口 |

---

## 10. 推荐页面样式方案

### 10.1 状态页

布局顺序：

1. 顶栏：`状态`
2. 当前模式 Hero
3. 双列实时监控卡
4. CPU 摘要卡
5. 内存摘要卡
6. 设备信息分组
7. 操作记录折叠区

视觉重点：

- 当前模式
- 当前温度
- 当前优化摘要

### 10.2 性能页

布局顺序：

1. 顶栏：`性能调度`
2. 当前模式摘要卡
3. 实时频率卡
4. 模式列表
5. 参数说明入口

规范要求：

- 模式列表必须有非常清晰的当前选中态
- “游戏模式”这类高风险项必须有警示标签

### 10.3 温控页

布局顺序：

1. 顶栏：`温控管理`
2. 当前机身温度 Hero / 温度主卡
3. 阈值刻度条
4. 节流档位列表
5. 安全提示区

规范要求：

- 温度条是核心视觉对象
- 不要把过多色彩分散到每个次级芯片
- 节流档位说明进入详情 sheet

### 10.4 优化页

布局顺序：

1. 顶栏：`系统优化`
2. 优化摘要卡
3. 系统优化项分组列表
4. ZRAM / Swap 卡片
5. 详情说明入口

规范要求：

- 优化项更像“状态列表”而不是展示卡片墙
- 应尽量向 MIUIX 的 preference grouping 靠拢

---

## 11. 交互行为规范

### 11.1 导航

- 点击底部导航切页为主
- 左右滑动切页可保留，但不能妨碍纵向滚动
- 切页动效应轻，`180ms - 240ms`

### 11.2 选择

- 列表项按下反馈使用轻微缩放或色面下沉
- 选中态必须常驻
- 切换成功后更新 Hero 与页面状态摘要

### 11.3 详情

- `i` 信息按钮、`详情` 按钮或行尾箭头是主入口
- 长按只作为高级补充交互

### 11.4 危险操作

- 重启、恢复默认、撤销类操作必须有确认
- 危险按钮固定放在 sheet 底部主动作区

---

## 12. 动效规范

Material 3 Expressive 不等于乱动，控制台更需要克制。

建议时长：

- 点击反馈：`100ms - 140ms`
- 卡片状态切换：`180ms`
- 页签切换：`220ms`
- Bottom Sheet 进出：`260ms - 320ms`

建议效果：

- 选中卡：轻微 scale + 容器色变化
- 标签切换：短距离 slide + fade
- 刷新：顶部锚定指示器循环
- Bottom Sheet：从底部上推，不做漂浮弹跳

必须支持：

- `prefers-reduced-motion`

---

## 13. 可访问性规范

- 点击热区最小 `44px`，建议 `48px`
- 文字与背景对比不低于 `4.5:1`
- 图标按钮必须有 `aria-label`
- 数值变化必须伴随文字语义，不可只依赖颜色
- 页面标题、sheet 标题、状态提示必须可被读屏正确识别
- 长按行为不能成为唯一信息入口

---

## 14. HTML / CSS 实施建议

### 14.1 语义结构

- 页面区块使用 `header / main / nav / section / article`
- 可点击卡片优先使用 `button` 或带 `role="button"` 的容器
- 指标列表用 `dl` 或有明确 label/value 结构的块

### 14.2 令牌建议

```css
:root {
  --safe-top: env(safe-area-inset-top, 0px);
  --safe-bottom: env(safe-area-inset-bottom, 0px);

  --page-x: 16px;
  --gap-lg: 24px;
  --gap-md: 12px;
  --gap-sm: 8px;

  --radius-sm: 16px;
  --radius-md: 20px;
  --radius-lg: 24px;
  --radius-xl: 28px;

  --top-bar-h: 56px;
  --bottom-bar-h: 64px;

  --color-bg: #f6fbf8;
  --color-surface: rgba(255, 255, 255, 0.94);
  --color-surface-2: #eef4f0;
  --color-outline: rgba(24, 45, 41, 0.10);
  --color-text: rgba(18, 32, 30, 0.92);
  --color-text-2: rgba(18, 32, 30, 0.68);
  --color-text-3: rgba(18, 32, 30, 0.46);
  --color-primary: #006b5d;
  --color-primary-container: #d2efe7;
  --color-warn: #b76a00;
  --color-danger: #b3261e;
}
```

### 14.3 组件实现优先级

第一阶段先改：

1. 背景
2. 底部导航
3. 通用卡片
4. Hero
5. Bottom Sheet

第二阶段再改：

1. 模式卡
2. 状态 chip
3. Pull To Refresh
4. Snackbar
5. 详情入口显式化

---

## 15. 明确禁止项

- 禁止 liquid glass、液态玻璃、全局磨砂漂浮卡片
- 禁止悬浮式底部导航
- 禁止悬浮 FAB 作为主操作入口
- 禁止悬浮工具条遮挡实时数据
- 禁止大面积背景图模糊作为主视觉
- 禁止用超小字承担主要信息
- 禁止只用颜色区分状态而无文字
- 禁止把详情只藏在长按里

---

## 16. 最终设计结论

这个项目最适合的不是“展示型玻璃界面”，而是：

**Material 3 Expressive 的重点表达能力 + iOS 的边界纪律 + MIUIX 的分组和密度控制。**

落地后的页面应该具备以下特征：

- 视觉更稳，不漂
- 重点更准，不散
- 结构更像控制台，不像概念页
- 操作更显性，不靠隐藏手势
- 依然保留现有四标签与实时数据优势

如果后续进入实现阶段，建议直接以本规范为基础，先重构 `webroot/index.html` 的公共样式层和底部导航层，再替换 Hero、模式卡、Sheet、Toast 四个关键组件。

---

## 17. 参考清单

### 本地审阅文件

- `E:\Pixel ADB\pixel9pro_control_v2\webroot\index.html`
- `E:\交互指南\Layout _ Apple Developer Documentation.html`
- `E:\交互指南\Positioning content relative to the safe area _ Apple Developer Documentation.html`
- `E:\交互指南\Toolbars _ Apple Developer Documentation.html`
- `E:\交互指南\Understanding typography - Material Design.html`
- `E:\交互指南\miuix-main.zip`
- `E:\交互指南\material-components-android-master.zip`

### 官方核对链接

- Android Developers, Material 3 for Compose:
  - https://developer.android.com/develop/ui/compose/designsystems/material3
- Android Developers Blog, Material 3 Expressive:
  - https://android-developers.googleblog.com/2025/05/introducing-material-3-expressive.html
- Apple Human Interface Guidelines:
  - https://developer.apple.com/design/human-interface-guidelines/layout
  - https://developer.apple.com/design/human-interface-guidelines/toolbars
  - https://developer.apple.com/design/human-interface-guidelines/tab-bars

