# 盘渡 DiskFerry

A native macOS menu bar utility for external NTFS disks, built with Swift, AppKit and SwiftUI.

盘渡希望让外置 NTFS 磁盘融入 Finder 的日常使用。当前为 **0.2.0-dev 开发阶段源码，尚未发布正式版本**。

**NTFS 写入尚未接入。** 当前应用提供磁盘发现、实际访问状态、Finder 打开、安全推出和登录自启动；系统只读挂载不会被显示为可写。自动读写、活动显示和更新设置中尚未实现的能力会明确标注。

![盘渡通用设置](docs/images/settings-light.png)

截图使用演示数据；另见 [深色外观](docs/images/settings-dark.png)。

## 当前功能

- 原生菜单栏入口与通用、磁盘、诊断、关于四个设置页；默认无 Dock 图标，关闭设置后继续运行。
- 通过 `diskutil` 获取外置卷信息，使用 Disk Arbitration / IOKit 验证本次连接身份。
- 打开 Finder 前重新核验卷；非强制推出前核验身份与外置整盘，推出后确认设备消失。推出会影响同盘所有分区。
- 保存本机偏好和基于卷 UUID 的策略；缺少 UUID 的 NTFS 卷仍可打开、推出，暂不保存跨次策略。
- 通过 `SMAppService.mainApp` 管理当前用户登录后的自启动，并同步 macOS 系统设置中的实际状态。
- 查询已安装的 FSKit 扩展，导出诊断 JSON，识别普通 NTFS 镜像的引导扇区。
- 附带 CLI 和完整品牌素材：8 种配色，带名称 / 不带名称的 PNG、JPG 与 macOS ICNS。

## 构建与运行

需要 macOS 和完整 Xcode（Swift 6，包含 macOS 15.4 或更新 SDK；仅 Command Line Tools 不够）。当前在 macOS 26.5 / Apple Silicon / Xcode 26.5 验证。控制层的构建目标为 macOS 13，FSKit 查询需 macOS 15.4+；Intel 已完成交叉构建，Intel 真机与更早系统尚未验收。

```bash
git clone git@github.com:kangaroo-demo/DiskFerry.git
cd DiskFerry
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash Scripts/build-app.sh
open dist/DiskFerry.app
```

构建脚本在标准路径找到完整 Xcode 时会自动选用。Xcode 位于其他位置时，请设置 `DEVELOPER_DIR`。产物是包含 arm64 / x86_64 的 Universal 2 应用 `dist/DiskFerry.app` 和 CLI `dist/diskferry`，采用本地 ad hoc 签名，尚未 Developer ID 签名或公证。

菜单栏选择“设置…”打开设置。开发时也可显式打开设置或查看隔离的演示数据：

```bash
open dist/DiskFerry.app --args --settings
open dist/DiskFerry.app --args --demo --settings
./dist/diskferry scan
./dist/diskferry doctor
./dist/diskferry backend
./dist/diskferry probe-image /absolute/path/to/disposable.ntfs
```

演示模式停用磁盘操作与真实登录项管理，偏好不写入实际设置。应用已运行时，`open` 不会改变现有进程的启动参数。

“开机自启动”指当前用户登录 Mac 后启动，默认关闭。请从 `.app` 设置此项；裸 SwiftPM 可执行文件不注册登录项。可从通用设置中的“登录项设置…”打开系统面板。已验证注册、启用、注销与状态同步，尚未通过注销用户或重启验证下一次登录启动。

SwiftPM 的 CLI 产品名为 `diskferry-cli`，避免与 `DiskFerry` 在大小写不敏感文件系统上冲突；打包后的命令名仍为 `diskferry`。

## 验证

默认测试覆盖磁盘解析、卷身份、推出保护、偏好持久化、镜像识别和登录项状态。真实系统镜像测试默认跳过，需要显式提供一次性镜像。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./dist/DiskFerry.app/Contents/MacOS/DiskFerry --smoke-test artifacts/ui-check
```

UI 检查使用演示模式，检查菜单分发、窗口生命周期及设置页面。以下可选步骤在 `.build/vendor` 内下载并构建固定版本的 NTFS-3G / pkgconf，仅操作新建的 64 MiB 普通文件镜像，验证中文文件名、新建、覆盖、清空和逐字节回读：

```bash
bash Scripts/prepare-ntfs-core.sh
python3 Scripts/verify-ntfs-image.py
```

脚本会输出报告路径。同目录的 `disposable.ntfs` 可用于系统只读挂载测试；测试先复制镜像，并仅扫描和推出自己创建副本的挂载：

```bash
DISKFERRY_TEST_IMAGE_PATH=/absolute/path/to/disposable.ntfs \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test
```

这些验证不代表已完成自定义 FSKit 挂载、Finder 写入或 Windows 互操作。构建脚本不会安装驱动或改变系统安全设置。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/DiskFerryApp` | 菜单栏、原生设置、登录项控制 |
| `Sources/DiskFerryCore` | 磁盘发现、身份核验、推出保护、诊断与偏好 |
| `Sources/DiskFerryCLI` | 命令行入口 |
| `Tests` | 单元测试与可选镜像接入测试 |
| `Scripts` | 应用构建与普通镜像验证 |
| `Resources/Brand` | [品牌素材与导出说明](Resources/Brand/README.md) |
| `docs` | [文档索引](docs/README.md)、需求历史、技术路线与验证记录 |

`.build/`、`dist/`、`artifacts/`、本地设计草稿与凭据不上传。验证记录中的本地产物路径用于复现，仓库不包含测试镜像或运行日志。

下一步是建立可签名的 FSKit 扩展、验证受控资源接入与只读挂载，再实现并验证 NTFS 写入。详见 [技术路线](docs/DiskFerry-技术路线与实施计划-v0.2.md) 和 [开发验证记录](docs/DiskFerry-首轮开发与验证-2026-10-09.md)。

首个正式版本现按 [实盘验收与发布计划](docs/first-release-plan.md) 推进。`Extensions/DiskFerryNTFS/` 和 `DiskFerryFSKit.xcodeproj` 是独立的实验扩展工作，尚未完成系统接纳或实际 FSKit 挂载，默认构建不包含它。开发步骤见 [FSKit 开发说明](docs/fskit-development.md)。

实验扩展现有 NTFS 镜像、属性和资源边界测试；U 盘工具另有不访问设备的路径与身份保护测试。实盘 FAT32 校验与 NTFS 镜像校验分别记录，均不代表 Finder 已可写入 NTFS。

## 参与与许可

欢迎通过 [Issues](https://github.com/kangaroo-demo/DiskFerry/issues) 或 Pull Request 提交反馈与改进，参见 [贡献指南](CONTRIBUTING.md)。提交诊断信息前请去除卷名、UUID、挂载路径及个人信息。

除单独声明外，本仓库自身的源码、文档和品牌素材沿用 [MIT License](LICENSE)。实验 NTFS 扩展整体按 GPL-2.0-only 提供，包含固定 NTFS-3G 核心与 GPL 适配代码；默认菜单栏控制层构建仍为 MIT。NTFS-3G、pkgconf 等依赖保留各自许可，不能以本仓库 MIT 许可替代。参见 [第三方组件说明](THIRD_PARTY_NOTICES.md)。
