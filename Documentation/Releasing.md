# 发布 DACBar

## 发布契约

- `DACBar/Configuration/Version.xcconfig` 中的 `MARKETING_VERSION` 是
  `CFBundleShortVersionString` 和 Git tag 的唯一来源，格式固定为三段数字
  `Major.Minor.Patch`。
- `CURRENT_PROJECT_VERSION` 只提供本地 Xcode fallback；分发时 GitHub Actions 使用
  递增的 `github.run_number` 覆盖它，最终 `CFBundleVersion` 必须是正整数。
- `DACBar/Configuration/Identity.xcconfig` 中的 `DACBAR_BUNDLE_IDENTIFIER` 是 Bundle ID
  的唯一来源；App、测试 target、构建脚本、验证脚本和运行时日志都从 Xcode 的有效
  build setting 或构建产物派生。构建环境不提供覆盖入口；迁移身份必须显式修改该文件，
  并同时规划偏好设置、签名与 Sparkle 更新连续性。
- 分发产物为 Universal 2（`arm64 + x86_64`），最低支持 macOS 14。
- 对外发布的唯一安装归档是 Developer ID 签名、公证并装订票据的 APFS/LZFSE DMG；
  镜像中只包含 `DACBar.app` 和指向 `/Applications` 的绝对符号链接。不发布 ZIP、XIP
  或安装器包。
- Distribution 产物必须使用 Developer ID Application、hardened runtime、公证和票据装订。
- 当前分发 App 不启用 Sandbox，也不携带分发 entitlement；在架构文档列出的 IOHID、
  Core Audio、全局快捷键和 Sparkle XPC 真机门禁全部通过前，不得切换发布默认值。
- 每种设备 backend 的沙箱兼容状态独立于协议支持状态；未完成对应真机验证时不得据此
  扩大 entitlement 或改变整个 App 的发布模型。
- 每个分发 App 必须内置 Sparkle HTTPS appcast 地址和 Ed25519 公钥，并同时启用
  `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`：appcast（包含内嵌发布说明）
  和更新归档都必须经过 Ed25519 验证。
- `DACBar.xcodeproj` 直接拥有唯一 App target 与 App test target；嵌套的
  `Packages/DACDevices/Package.swift` 只输出可测试、可复用的设备库。
- Swift 6.4 源码测试、Universal 2 构建、Developer ID 签名和公证只使用标准
  GitHub-hosted `xcode-27` ARM64 runner。最终签名、公证的同一个 DMG 会重新下载到
  `xcode-27` ARM、`macos-26-intel` 和最低系统 `macos-14` runner；每个 job 先验证
  SHA-256 和 Gatekeeper，再实际启动对应切片，不使用另一套编译器重新构建源码。
- tag workflow 默认只有 `contents: read`，所有 checkout 都禁用凭据持久化。无 secret 的
  `release-trust` job 先验证 tag、签名和 `origin/main` 包含关系。持有证书与公证 secrets 的
  `notarized-artifacts` job 还必须通过受保护的 `release-signing` environment 审批且没有写权限；
  只有全部运行时门禁通过后，独立 Ubuntu `publish-release` job 才获得 `contents: write`，且它
  不 checkout 源码、不读取任何发布 secret。
- 普通 PR 使用 `pull_request` 在一次性 GitHub-hosted VM 中验证合并结果，不运行持久机器、
  不获得发布 secrets。公开仓库使用 standard hosted runner 不计 Actions 分钟；单 job、
  并发和 artifact storage 仍受 GitHub 套餐限制，`xcode-27-xlarge` 等 larger runner 不在
  本项目自动化路径中且始终可能计费。
- 只有 UA1 II 真机测试使用带 `DACBar-Hardware` 标签的 Apple Silicon self-hosted runner；
  `hardware.yml` 只允许个人仓库所有者从 `main` 手动触发，不执行 PR 代码，也不持有发布
  secrets。迁移到组织仓库前必须把该判断替换为受保护 environment 与 runner group。
- 本地 Xcode Run 可直接使用共享 `DACBar` Scheme；正式分发必须通过 `build.sh`，以便在
  签名前移除非沙箱路径不用的 Sparkle XPC 服务，并验证 App 与所有保留的 Sparkle
  可执行文件都包含两个架构切片。
- Xcode Debug 与 Release 是本地可运行配置，使用仅含
  `disable-library-validation` 的 `DACBar.Local.entitlements`，使 ad-hoc 主程序能加载
  独立 ad-hoc 签名的 Sparkle。Distribution 不携带该 entitlement，并作为 Archive 与
  `build.sh release` 的发布输入；CI 会实际启动 Release，防止 dyld 回归。

## 首次发布准备

以下配置只需在首次公开发布前完成一次；普通源码 push 和不带 `v*` tag 的 CI 不读取
发布 secrets。先创建 GitHub 仓库、配置 `origin` 并让 `gh auth status` 成功，再按下节手工
建立 environment 与 tag ruleset。Secret 的值无法再次查看，只能替换；长期凭据还必须在
GitHub 之外保留恢复副本。

### 1. Developer ID 证书

在 Apple Developer 的 Certificates, Identifiers & Profiles 中创建
`Developer ID Application` 证书，将下载的 `.cer` 安装到构建 Mac 的登录钥匙串。钥匙串
中该证书下方必须能展开看到对应私钥；只有证书而没有私钥无法给 App 签名。

从“钥匙串访问”中把**证书和私钥一起**导出为 `DeveloperID.p12`。导出时由你自己设置
一个强随机密码，这个密码就是下表中的 `P12_PASSWORD`；它不是 Apple ID 或 Mac 登录密码。
`.p12` 和密码应分别保存在密码管理器或离线备份中。可用下面的命令确认准确的签名身份：

```bash
security find-identity -v -p codesigning | grep 'Developer ID Application'
```

### 2. 受保护的发布环境与 tag ruleset（必须手工配置）

仓库代码**不能**替代 GitHub 的仓库级保护。首次发布前，在 **Settings → Environments**
手工创建名为 `release-signing` 的 environment，并至少配置：

- 指定一名或多名可信发布维护者为 required reviewers；可用时启用 prevent self-review；
- deployment branches/tags 只允许 selected patterns 中的 `v*` tag；
- 下文 6 个 Secrets 和 3 个 Variables 全部放在该 environment，而不是 repository scope。

再在 **Settings → Rules → Rulesets** 建立 active tag ruleset，目标为 `v*`，限制 tag 的创建者，
禁止非发布维护者更新或删除 release tag，并只给最小的紧急 bypass 列表。如果仓库计划支持，
同时要求签名提交；但该选项不能代替 tag 本身的签名。required reviewer 应在批准 environment
前核对 tag、commit、前置测试和预期版本。

`release.yml` 还会在任何签名 secret 可见之前执行独立的代码门禁：只接受严格的
`vMajor.Minor.Patch` annotated tag，通过 GitHub Git Tags REST API 要求
`verification.verified=true` 且 `reason=valid`，确认 tag 直接指向当前 workflow commit，并从
远端重新获取 `origin/main` 后用 `git merge-base --is-ancestor` 验证包含关系。这里使用 GitHub
托管的签名验证结果，是因为一次性 runner 并没有维护者的 GPG/SSH trust material；直接运行
`git tag -v` 会因为缺少可信公钥而成为不可工作的伪门禁。轻量 tag、GitHub 未验证的 tag、
间接 tag 和 main 之外的 commit 都会失败。随后仍不接触 environment 或 secrets 的
`source-tests` job 在 `xcode-27` 上通过 Xcode build settings 解析权威版本，并要求 tag 等于
`v$VERSION`；这个 Xcode 依赖的检查不能放在 Ubuntu trust job。

`scripts/configure-release.sh` 只会确认 `release-signing` 已存在并向其中写入 secret/variable；
它有意**不会**创建或修改 environment、reviewer、deployment policy 或 ruleset，也不能宣称
以下代码已经配置了这些仓库保护。

### 3. GitHub Actions Secrets

| Secret | 来源和用途 | 是否需要长期备份 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | `DeveloperID.p12` 的 Base64；CI 导入证书和私钥 | 备份原始 `.p12` |
| `P12_PASSWORD` | 导出 `.p12` 时由你设置的密码 | 是，与 `.p12` 分开保存 |
| `NOTARY_APPLE_ID` | Apple Developer Program 使用的 Apple Account 邮箱 | 是 |
| `NOTARY_PASSWORD` | 在 Apple Account 网站生成的 app-specific password；不是登录密码 | 可撤销后重新生成 |
| `SPARKLE_PRIVATE_KEY` | 下节导出的 Ed25519 私钥种子单行 Base64 | **必须长期离线备份** |
| `DSYM_ARCHIVE_PASSWORD` | 使用 AES-256-CBC/PBKDF2 加密私有 dSYM workflow artifact 的 32+ 字符随机密码 | **必须长期离线备份** |

推荐使用仓库提供的初始化脚本一次性验证并上传全部发布设置。默认模式逐项提示输入，值只
保留在当前进程内；脚本通过标准输入调用 GitHub CLI，不把 secret 放进命令参数、shell
历史或日志：

```bash
./scripts/configure-release.sh
```

如果希望在重装 runner 或迁移仓库时复用配置，可以把示例复制到**仓库外**的默认位置：

```bash
install -d -m 700 "$HOME/.config/dacbar"
install -m 600 Documentation/release.secrets.example \
    "$HOME/.config/dacbar/release.secrets"
install -m 600 Documentation/release.variables.example \
    "$HOME/.config/dacbar/release.variables"
```

编辑两个文件后，先做完全离线的校验，再上传：

```bash
./scripts/configure-release.sh --validate-only
./scripts/configure-release.sh
```

`release.secrets` 只记录 `.p12` 和 Sparkle 私钥的绝对路径以及所需凭据，不复制证书或私钥
本体。脚本拒绝仓库内、符号链接、非当前用户所有或权限不是 `600`/`400` 的 secrets 文件
及其引用的两个密钥文件，并把配置作为纯 `KEY=VALUE` 数据解析，绝不 `source` 或执行其中
内容；它还会验证 Team ID 与签名身份、Sparkle 公私钥是否匹配。可以用
`--secrets-file`、`--variables-file` 指向密码管理器提供的临时文件，并用
`--repo OWNER/REPO` 明确目标仓库。上传前默认必须再次确认经 GitHub 解析的目标。

不要把真实 `.secrets` 放进仓库目录。即使 `.gitignore` 已加入纵深防护，它也无法防止
强制提交、编辑器插件、云同步和本地备份读取明文。长期恢复真相源仍应是密码管理器或加密
离线介质；GitHub 只是发布时使用的托管副本。本地配置用完后可以删除。GitHub CLI 会在
本地加密 Actions Secret 再发送，但这不保护本地配置文件本身；参见
[GitHub CLI secret 文档](https://cli.github.com/manual/gh_secret_set) 与
[GitHub Actions 安全使用指南](https://docs.github.com/en/actions/reference/security/secure-use)。

如需逐项手工设置，`BUILD_CERTIFICATE_BASE64` 可以直接通过标准输入上传到受保护 environment，
避免生成额外
明文文件：

```bash
base64 -i DeveloperID.p12 | gh secret set BUILD_CERTIFICATE_BASE64 --env release-signing
gh secret set P12_PASSWORD --env release-signing
gh secret set NOTARY_APPLE_ID --env release-signing
gh secret set NOTARY_PASSWORD --env release-signing
gh secret set DSYM_ARCHIVE_PASSWORD --env release-signing
```

后四条命令会交互式读取输入。`NOTARY_PASSWORD` 在 Apple Account 的“登录与安全性 →
App 专用密码”中创建。也可以在 GitHub 网页中逐项粘贴；不要把敏感值写进带 `--body`
的命令或 shell 历史。`DSYM_ARCHIVE_PASSWORD` 可用 `openssl rand -base64 48` 生成并保存在
密码管理器；丢失后已保留的 dSYM 无法恢复。

`KEYCHAIN_PASSWORD` **不需要配置**。release job 每次使用 `openssl rand` 生成一个随机密码，
只用于创建和解锁该次运行的临时钥匙串；job 结束后钥匙串和导入的 `.p12` 都会删除。它与
`P12_PASSWORD` 是两个完全不同的概念。

### 4. GitHub Actions Variables

| Variable | 来源和用途 |
|---|---|
| `DEVELOPER_ID_APPLICATION` | 上述 `security find-identity` 输出中的完整身份，例如 `Developer ID Application: Name (TEAMID)` |
| `NOTARY_TEAM_ID` | Apple Developer Membership 中的 10 位 Team ID |
| `SPARKLE_PUBLIC_ED_KEY` | 下节 `generate_keys` 输出的 Ed25519 公钥 Base64 |

这些值不是私密凭据，因此使用 Actions Variables。发布流水线会从 Sparkle 私钥重新推导
公钥并与 `SPARKLE_PUBLIC_ED_KEY` 比对，避免把错误密钥写入已经公证的 App。
前两个值可以立即配置：

```bash
gh variable set DEVELOPER_ID_APPLICATION --env release-signing
gh variable set NOTARY_TEAM_ID --env release-signing
```

命令会交互式读取值；Sparkle 公钥在下一节生成后再设置。

配置后可以检查**名称是否齐全**；GitHub 不会返回 secret 的值：

```bash
gh secret list --env release-signing
gh variable list --env release-signing
```

tag 发布时 workflow 也会在导入证书前检查这 6 个 Secrets 和 3 个 Variables；缺项时只
报告设置名称，不输出任何值，也不会继续执行签名或公证。

### 5. Runner 配置

普通 CI 与发布不需要注册 self-hosted runner。公开仓库直接使用 GitHub 标准
`xcode-27`（Apple Silicon）、`macos-26-intel` 和 `macos-14` image；前者是 Xcode 27 的唯一
编译环境，后两者只启动前者生成的 Universal 2 交付物。GitHub runner-images 在
2026-08-10 仍列出 `macos-14` ARM label，因此它可作为当前最低系统门禁；该 image 已进入
弃用期并计划在 2026-11-02 后停止支持，届时必须迁移为一台锁定 macOS 14 的隔离
self-hosted/external release gate，而不能编造 hosted label。`xcode-27` 当前是 public preview，
因此每个 job 都会显式检查 Xcode、Swift、OS 与 CPU 架构，image 变化会快速失败而不是悄悄
换工具链。计费、弃用与当前 image 状态以
[GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、
[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
、[runner-images](https://github.com/actions/runner-images) 和
[Xcode 27 image 公告](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/)
为准。

若要从 GitHub UI 运行 UA1 II 真机回归，才在仓库
**Settings → Actions → Runners** 注册一台连接设备的 Apple Silicon Mac，并额外添加
`DACBar-Hardware` 自定义标签。该 runner 需要 Xcode 27 / Swift 6.4，但不得保存 Developer
ID、Sparkle 或公证凭据。进入 **Actions → Hardware integration → Run workflow**，保持
branch 为 `main`；只有一台设备时 location ID 留空，多台设备时填写例如 `0x01100000`。
workflow 会串行运行并尝试恢复所有被修改的设置。普通 push、PR 与 tag 发布不会分配这台
机器。

### 一次性的 Sparkle 密钥设置

先让 Xcode 把锁定版本的 Sparkle 工具解析到项目构建目录，再生成密钥并存入本机钥匙串；
这一步只做一次：

```bash
SPARKLE_KEY_ACCOUNT=$(./scripts/read-build-setting.sh \
    PRODUCT_BUNDLE_IDENTIFIER Distribution)
xcodebuild -resolvePackageDependencies \
    -project DACBar.xcodeproj -scheme DACBar \
    -clonedSourcePackagesDirPath .build/xcode/SourcePackages
.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account "$SPARKLE_KEY_ACCOUNT"
```

把工具打印的公钥保存为 GitHub Actions variable `SPARKLE_PUBLIC_ED_KEY`，并把私钥种子
导出后保存为 Actions secret `SPARKLE_PRIVATE_KEY`：

```bash
.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account "$SPARKLE_KEY_ACCOUNT" -x /secure/path/dacbar-sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY --env release-signing \
    < /secure/path/dacbar-sparkle-private-key
gh variable set SPARKLE_PUBLIC_ED_KEY --env release-signing
```

最后一条命令会提示粘贴前一步 `generate_keys` 打印的公钥。

`--account` 只是 Sparkle 在钥匙串中保存私钥的稳定账户标签；首次设置时用 Bundle ID
便于识别，但它不是构建时的 App 身份配置。生成密钥后应持续使用同一个账户标签，即使
以后迁移 Bundle ID 也不要误建一套新密钥。secret 的值是导出文件中的单行 Base64。
私钥不得提交到仓库、Release 或构建产物；应在
独立安全位置保留恢复副本。正常轮换应在旧私钥仍可用时发布一个由旧密钥签名、但内置新
公钥的过渡版本。如果私钥已经丢失，当前 DMG 发布链允许 Sparkle 在 Developer ID 身份
不变时执行紧急 Ed25519 换钥；不能在同一个版本同时更换 Developer ID 证书和 Ed25519
密钥。执行前仍必须遵循 [Sparkle 签名与密钥轮换文档](https://sparkle-project.org/documentation/)
并用真实旧版完成 N-1 → N 验证；不要直接替换 `SPARKLE_PUBLIC_ED_KEY`。

## 发布步骤

1. 更新 `DACBar/Configuration/Version.xcconfig` 中的 `MARKETING_VERSION` 和
   `CHANGELOG.md`，把本次内容从 Unreleased 移入新版本。不要直接编辑 Info.plist、
   pbxproj 或生成的 App 来改版本。
2. 本地执行：

   ```bash
   swift test --package-path Packages/DACDevices \
       --scratch-path .build/package \
       -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
   swift build --package-path Packages/DACDevices \
       --scratch-path .build/package \
       -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
   xcodebuild -project DACBar.xcodeproj -scheme DACBar \
       -disableAutomaticPackageResolution \
       -destination "platform=macOS,arch=$(uname -m)" test
   ./build.sh release
   ```

   GitHub CI 在 `xcode-27` 上运行 Swift 6.4 测试并生成唯一的 Universal 2 DMG。tag 发布
   签名和公证只执行一次；ARM、Intel 与 macOS 14 job 下载完全相同的候选产物，按 basename
   验证 SHA-256、Gatekeeper、票据与启动后，才由不接触 secrets 的独立 job 创建 Release。

3. 把版本变更合并到 `main`，等待 required checks 成功；再从最新 `origin/main` 创建与 Xcode
   有效版本完全一致、GitHub 能验证其签名的 annotated tag：

   ```bash
   VERSION=$(./scripts/read-version.sh Distribution)
   git tag -s "v$VERSION" -m "DACBar $VERSION"
   git push origin "v$VERSION"
   ```

   `read-version.sh` 读取 Xcode 解析后的 build settings，而不是自行解析 xcconfig；因此
   如果工程没有实际接入版本配置，tag 门禁会直接暴露问题。推送后，environment reviewer
   必须在 GitHub UI 核对签名 tag 和目标 commit 确实位于 `main`，再批准 `release-signing`。

4. `release.yml` 会重新测试，通过 Xcode App Target 构建 Universal 2 App，在隔离的临时
   钥匙串中导入证书。流水线先通过临时 ZIP 提交 App 公证并给 App 装订票据，再创建
   APFS/LZFSE DMG、签名并公证该 DMG；临时 ZIP 不发布。最终为 DMG 和包含内嵌发布说明的
   `appcast.xml` 生成 Ed25519 签名。候选 DMG 随后在 GitHub-hosted ARM、Intel 与 macOS 14
   上执行 checksum、Gatekeeper、票据、Universal 2 和启动验证；全部通过后才发布 DMG、
   SHA-256 与 appcast。匹配 App binary UUID 的 dSYM 会单独压缩，并用 environment 中的
   `DSYM_ARCHIVE_PASSWORD` 经 AES-256-CBC/PBKDF2 加密后作为 Actions artifact 保留 90 天；
   即使 public repository 的 workflow artifact 被下载也没有明文符号，且它不会复制到公开
   release candidate 或 GitHub Release。恢复时从密码管理器读取密码并使用相同参数解密：

   ```bash
   DSYM_ARCHIVE_PASSWORD='<from-password-manager>' \
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
       -in DACBar-VERSION.dSYM.zip.enc -out DACBar-VERSION.dSYM.zip \
       -pass env:DSYM_ARCHIVE_PASSWORD
   ```
   临时 `.p12`、钥匙串和公证凭据无论成功失败都会清理，并随一次性签名 VM 一同销毁；
   拥有仓库写权限的最终发布 job 不接触这些 secrets。任何前置步骤失败都不会创建 Release。

5. 从第二个公开版本开始，发布前必须在一台未安装开发构建的 Mac 上完成 N-1 → N 验收：

   - 安装上一个正式 Developer ID 签名、公证的 Release；
   - 通过 App 内“检查更新”读取即将发布的签名 appcast；
   - 确认版本、发布说明、下载、签名验证、安装和重启全部成功；
   - 再验证系统自动检查的授权选择能被保留，且拒绝篡改后的 appcast 或 DMG。

   ad-hoc 构建可以验证 feed 生成和 Ed25519 工具链，但不能替代这个 Gatekeeper、代码签名
   与安装路径的端到端门禁。

## 本地公证演练

先把凭据存入钥匙串：

```bash
xcrun notarytool store-credentials dacbar \
    --apple-id <APPLE_ID> \
    --team-id <TEAM_ID> \
    --password <APP_SPECIFIC_PASSWORD>
```

然后运行：

```bash
DACBAR_SIGN_ID="Developer ID Application: Name (TEAMID)" \
DACBAR_NOTARY_PROFILE=dacbar \
DACBAR_SPARKLE_FEED_URL="https://github.com/OWNER/REPOSITORY/releases/latest/download/appcast.xml" \
DACBAR_SPARKLE_PUBLIC_KEY="<Base64-encoded-Ed25519-public-key>" \
./build.sh release
```

流水线最终执行 `scripts/validate-app.sh` 与 `scripts/validate-dmg.sh`。前者检查 Info.plist、
版本、Bundle ID、图标、本地化资源、`arm64 + x86_64` 架构、签名、hardened runtime、
票据和 Gatekeeper；后者检查 APFS/LZFSE 格式、只读镜像布局、DMG 签名、公证票据及
Gatekeeper。

UA1 II 的 HID 真机回归目前只在 Apple Silicon 上完成。当前 CI 能验证 x86_64 编译与
链接，但不能替代“Intel Mac + UA1 II”的最终硬件回归；完成该回归前，
发布说明不应声称 Intel 设备控制已经过真机验证。

## 更新机制

正式发布构建把 GitHub Release 中的 `appcast.xml` 地址和 Ed25519 公钥写入 Info.plist。
App 不强制打开后台检查：Sparkle 会在第二次正常启动时显示标准授权界面，由用户选择
是否每 24 小时检查更新；界面默认建议自动下载和安装，最终选择由用户保存。用户也可从
面板立即触发“检查更新”。`appcast.xml` 的签名覆盖其中内嵌的发布说明，归档另行验证
Ed25519 签名；安装的 App 本身还必须通过 Developer ID 和公证验证。

首个公开版本虽然没有旧版本可更新，但仍必须带齐 Sparkle framework、feed 地址和公钥，
这样它才能升级到下一个版本。`appcast.xml` 使用 GitHub 的 `releases/latest/download`
固定地址，而其中的 enclosure 指向具体 tag 的不可变 DMG。网站下载与 Sparkle 使用同一
份镜像，避免两套发布载荷发生漂移。

项目锁定 Sparkle 2.9.5，并由 Dependabot 每周检查 Swift Package 与 GitHub Actions
更新。依赖升级 PR 必须重新执行测试、Universal 2 bundle 校验和上述 N-1 → N 门禁；
不能仅凭依赖解析成功直接发布。

当前采用 Sparkle 的非沙箱安装路径，不设置 `SUEnableInstallerLauncherService` 或
`SUEnableDownloaderService`；这些键是沙箱 App 的 XPC 配置，不应加到本项目。正式
`build.sh` 还会在最终签名前移除 framework 自带的 `Installer.xpc`、`Downloader.xpc`
和 framework-level symlink，只保留非沙箱更新需要的 `Updater.app` 与 `Autoupdate`。
如果以后迁移沙箱，必须同时恢复 XPC bundle、签名步骤、Info.plist 开关和对应 entitlement，
不能只打开 `com.apple.security.app-sandbox`。
