# Optional Module Sources

本目录用于保存与 `pixel9pro_control` 同仓库管理、但职责独立的可选模块源码。

当前规划：

- `pixel9pro_baseband_trial/`
  - 独立基带配置模块源码
  - 负责 `CarrierSettings / APN / China MCFG / IMS props`
  - 不负责 `UECap binarypb`、温控、CPU 调度、ZRAM 或 WebUI

发布建议：

- 源码保留在仓库里，便于统一维护与 issue 追踪
- ZIP 安装包不要提交进源码树，作为 GitHub Releases assets 上传
