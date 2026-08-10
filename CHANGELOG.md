# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。用户可见的变更记录在这里；
协议调查过程仍记录在 `Documentation/ShanlingUA1II/ProtocolFindings.md`。

## [Unreleased]

### Changed

- Sparkle 改为验证包含内嵌发布说明的 appcast 以及更新 DMG，并使用系统标准授权界面
  保存自动检查与安装选择。
- 更新按钮跟随 Sparkle 的实时可检查状态；发布流水线验证签名 feed，并在一次性
  GitHub-hosted 签名 runner 上隔离、清理临时签名钥匙串。
- 发布 job 改为现场生成临时钥匙串密码；Developer ID 身份和 Team ID 作为公开 Actions
  Variables 管理，并补充首次发布所需凭据、来源、备份与 runner 配置清单。
- 对外发布改为同时签名、公证和装订 App 与 APFS/LZFSE DMG；镜像仅包含 App 与
  `/Applications` 拖放链接，临时公证 ZIP 不进入 Release。
- CI 与 tag 发布使用 GitHub-hosted ARM、Intel 和最低系统 macOS 14 runner；Universal 2
  产物只签名、公证一次，再以 SHA-256 固定同一 DMG 完成各架构与最低系统启动门禁。
- 发布前置门禁要求 release commit 位于 `origin/main` 且 annotated tag 的签名已由 GitHub
  验证；签名 secrets 由受保护的 `release-signing` environment 审批后才可访问。
- 发布 checksum 只记录 DMG basename，并在 ARM、Intel 和最终发布 job 使用前重新验证；
  匹配的 dSYM 经 AES-256/PBKDF2 加密后作为 Actions artifact 保留 90 天。
- 用户版本改由 `DACBar/Configuration/Version.xcconfig` 单点维护；Xcode、发布脚本、tag、
  DMG 与 Sparkle appcast 不再复制或解析独立 `VERSION` 文件。
- Dependabot 每周监控 Swift Package 与 GitHub Actions 依赖；发布文档加入 N-1 → N
  真正签名、公证更新的端到端验收与 Ed25519 密钥轮换说明。

## [0.3.0] - 2026-08-08

### Added

- Xcode 27 / Swift 6.4 完整并发检查、单元测试和 Universal 2 App 结构验证的 CI。
- Developer ID 签名、公证、票据装订、SHA-256 和 GitHub Release 流水线。
- 英文和简体中文 String Catalog，包括 Driver 能力描述与错误消息。
- Sparkle 2 自动更新、Ed25519 更新签名和手动“检查更新”入口。
- 真实 UA1 II 报文回归、可选真机测试和 completion 间隔测量。

### Changed

- 产品更名为 DACBar；厂商无关核心、App 与 Shanling UA1 II 设备实现拆为独立 targets。
- 引入稳定的正式 Bundle ID，并统一偏好设置、签名与更新身份。
- 版本号以仓库根目录 `VERSION` 为唯一来源。
- App 生成并验证同时支持 Apple Silicon 与 Intel Mac 的 Universal 2 产物。
- 非沙箱发布归档移除未启用的 Sparkle Installer/Downloader XPC 服务。
