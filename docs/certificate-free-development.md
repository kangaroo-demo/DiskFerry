# 普通应用打包与 FSKit 扩展签名条件

## 独立安装要求

DiskFerry 正式版只需安装自己的应用，由应用统一交付 NTFS 引擎与原生 FSKit 扩展。用户不需要另外安装 macFUSE、Homebrew 或 NTFS 命令行工具，也不需要 Apple 开发者账号。首次使用时，macOS 可能要求启用应用内置的文件系统扩展，这是系统授权步骤。

2026-10-16 已停止借用 macFUSE 已签名扩展的实验路线，并移除对应探针、构建脚本、测试工作流和安装指引。该实验没有取得系统挂载证据，也不作为 DiskFerry 原生扩展的验证结果。历史需求中的 macFUSE 备选研究不代表当前产品方案。

## 同级项目的打包方式

2026-10-16 实际读取同级项目脚本与配置，并检查本机已有应用的签名。以下是当前工作区快照，不代表重新验收其发布资产。

| 项目 | 构建与打包 | 本机现有应用签名 | 额外运行时 |
| --- | --- | --- | --- |
| DockPin | SwiftPM 编译，自行组织 .app，ditto 生成 ZIP；Developer ID 与公证是可选流程 | DockPin Local Development 自签名，TeamIdentifier 未设置；无此身份时脚本回退 ad hoc | 应用无需另装运行时；辅助功能权限由系统管理 |
| Daylight | Tauri 编译 .app 和 DMG，Node 脚本另生成 ZIP、安装说明与 SHA-256 | 配置 signingIdentity 为 -；现有应用为 ad hoc，TeamIdentifier 未设置 | 前端资源随包交付，使用系统 WebKit |
| LumaRec | SwiftPM 编译，可选 lipo 合并架构，生成 .app、DMG、ZIP、构建信息与 SHA-256 | 默认 ad hoc；现有应用也为 ad hoc，TeamIdentifier 未设置 | 录制与导出使用 Apple 框架，无需另装媒体工具 |
| DiskFerry 默认应用 | SwiftPM 分架构编译、lipo 生成 Universal 2 的 .app 和 CLI | ad hoc，TeamIdentifier 未设置 | 当前菜单栏应用无需另装运行时，尚未集成 NTFS 写入 |

核对文件：DockPin 的 scripts/build_app.sh、scripts/package_release.sh 和发布 workflow；Daylight 的 src-tauri/tauri.conf.json、scripts/package-macos-release.mjs 和发布 workflow；LumaRec 的 scripts/build-app.sh、scripts/verify-package.sh、Resources/LumaRec.entitlements 和安装说明。三个项目均未发现 FSKit Module 权限或文件系统扩展打包步骤。

四个本机应用的严格签名完整性检查通过；签名完整性不等于 Apple 信任或公证。DockPin、Daylight、LumaRec 都说明了未公证构建的正常首次打开授权条件。LumaRec 的社区稳定版安装说明明确采用本地签名，不应把 Developer ID 与公证当作一切普通应用发布的必需条件。

DiskFerry 可以复用其 .app、DMG、ZIP、Applications 快捷方式、离线安装说明、源码版本记录、校验值与解包后验证方式。未公证状态须如实说明；能否作为正式 NTFS 产品交付，还取决于真实功能验收。

## 文件系统扩展的独立条件

DiskFerry 的菜单栏应用已经能够用 ad hoc 签名运行。额外的条件来自自带 FSKit 扩展中的 com.apple.developer.fskit.fsmodule，见 [扩展 entitlement](../Extensions/DiskFerryNTFS/Entitlements.plist)。它必须由实际授权该能力的签名与配置描述文件支持。普通应用的“仍要打开”授权不会授予这种开发者权限。

2026-10-16 核对 Apple 的 [macOS 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)：FSKit Module 支持 ADP 和 Developer ID 两列，免费 Apple Developer 一列为空。免费 Personal Team 的普通设备测试能力不能视为拥有这一权限。

本机实验扩展可完成编译与 ad hoc 包完整性签名，但没有可用的 Apple Development / Developer ID 身份或 Xcode Team 配置。实际签名 Xcode 构建返回了“DiskFerryNTFS has entitlements that require signing with a development certificate”，原始日志保留在本地 artifacts/release-qualification-2026-10-15/。扩展尚未通过真实系统挂载验收，不能以默认应用能打开推断 NTFS 已可用。

所需的扩展签名由 DiskFerry 开发者负责，客户只安装含组件的应用。不能把开发者缺少签名条件改成要求客户另装文件系统运行时，也不能用临时签名安装包掩盖扩展尚未取得系统接纳。

## 当前可以继续的开发

- 编译自带的原生扩展与宿主，完善接口、策略传递和错误处理。
- 在普通一次性 NTFS 镜像上验证核心与适配层的读写、同步、名称、时间、并发和故障行为。
- 完善应用内组件打包、GPL 对应源码、许可和可复现构建，生成明确标记能力边界的开发安装包。
- 完善原生界面、磁盘身份检查、诊断与登录项状态。

这些检查不能替代真实 FSKit 资源回调、Finder 操作、实际 NTFS 介质、Windows 互操作或安装验收。编译与测试步骤见 [FSKit 开发说明](fskit-development.md)。

具备支持 FSKit Module 的签名条件后，仍须依次完成只读接入、受控写入、Finder 与实盘持久化、安全推出和故障处理。完整门槛见 [首版验收计划](first-release-plan.md)。不关闭 SIP、不降低启动安全策略，不通过更改就绪标志或额外安装运行时抵扣验收。
