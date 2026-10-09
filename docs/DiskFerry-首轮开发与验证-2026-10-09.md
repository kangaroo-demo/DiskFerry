# DiskFerry 首轮开发与验证记录

日期：2026-10-09。用户明确指示“那就定个目标，开始写代码吧”，开发与一次性镜像验证已启动。2026-09-16 的需求和路线文档中“未启动”描述属于当时状态。

## 本轮结果

交付可运行的原生菜单栏开发版和首轮 NTFS 后端证据。控制层可以发现外置 NTFS、显示系统状态、保存偏好并提供 Finder 打开及非强制推出入口；**尚未交付 NTFS 文件系统扩展与 Finder 读写**。

应用从原先的大窗口预览改为 AppKit `NSStatusItem` 与 SwiftUI 设置。默认 `.accessory`，启动无设置窗口；窗口关闭不终止进程。菜单展开时不替换菜单，关闭后更新状态；手动移除图标会保存隐藏偏好。全局设置和单卷策略使用 UserDefaults，单卷键使用卷 UUID，不使用可复用的 BSD 设备号。静态模板图标作为当前活动显示，未模拟读写进度。

检测与推出使用系统公开的 `diskutil`，连接身份通过 Disk Arbitration 与 IOKit 的公开 IOMedia 注册对象 ID 获取，不读取原始磁盘内容。推出重查分区及父整盘，拒绝内置/未知位置、无法确认身份和身份变化；调用 `diskutil eject`，没有 `force`，之后核实设备消失。UI 明示整盘的其他分区也会被推出。

系统实测发现 NTFS 镜像不提供 `VolumeUUID` 或 `MediaUUID`，因此本次连接的媒体和整盘注册对象 ID 用于打开及推出前重验。它们不用于持久化：无稳定 UUID 的卷暂不能保存跨次策略。需要在后续 FSKit 授予的资源中验证 NTFS serial 等稳定格式身份，才能扩大策略覆盖。真实物理介质及 Finder GUI 操作仍未验收。

## 环境和系统证据

| 项目 | 当前证据 |
| --- | --- |
| 系统 | macOS 26.5，25F71，Apple Silicon arm64 |
| 构建工具 | Xcode 26.5，17F42；命令行工具单独使用缺少 Swift Testing |
| 默认系统安全 | SIP enabled；本轮未改变启动安全策略或安装驱动 |
| 构建产物 | 应用及 CLI 均包含 arm64 / x86_64；ad hoc 签名校验通过 |
| FSKit | SDK 公共块资源读取接口编译通过；运行时扩展查询成功 |
| 已启用的 FSKit 扩展 | `com.apple.fskit.exfat`、`com.apple.fskit.ftp`、`com.apple.fskit.msdos` |
| DiskFerry 文件系统扩展 | 尚未构建或安装；查询到系统扩展不代表 NTFS 能力 |
| 签名身份 | 未配置 Apple Development / Developer ID 身份，应用使用本地 ad hoc 签名 |
| 外置盘 | 基线查询为空；后续只接入自建的只读 NTFS 文件镜像，没有操作真实外置介质 |

FSKit 使用弱链接并检查系统版本。Universal 2 是构建证据，尚未实测 Intel 或更早 macOS。签名身份缺失是待解决的交付前提；尚未尝试扩展安装，不能据此声称系统已拒绝某个扩展。

## NTFS 核心证据

固定上游稳定版 **NTFS-3G 2026.9.28**。

- 上游：<https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28>
- 源码：<https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz>
- SHA-256：`350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8`
- 构建选项：`--disable-ntfs-3g --disable-shared --enable-static --disable-dependency-tracking`。
- 构建只保存在 `.build/vendor`，没有 `make install`，未安装 FUSE 驱动，未捆绑入应用。
- 上游缺少本机 `pkg-config` 时，项目内构建 pkgconf 2.3.0；源码 SHA-256 为 `3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b`。

创建 64 MiB 普通文件镜像，`mkntfs` 格式化后，`ntfscp` 写入 `/盘渡验证-旅行档案.bin`，每次关闭工具后由 `ntfscat` 重新读取。

| 用例 | 字节数 | 写入及回读的相同 SHA-256 |
| --- | ---: | --- |
| 中文名称新建 | 2,097,177 | `a0d874363f4c5a55e97e74397a1d63a85429496f6d0abb17a4ce002a8a73748b` |
| 缩短覆盖 | 12,544 | `eb1d2053a15f206eed06c816424e9664e15d1b70140b9f38be0110073610f260` |
| 清空 | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

复现入口：`bash Scripts/prepare-ntfs-core.sh` 和 `python3 Scripts/verify-ntfs-image.py`。每次创建新目录和镜像，验证脚本没有设备路径参数。普通镜像检测器会验证已打开的文件描述符为普通文件，拒绝设备和目录，并检查扇区、簇、MFT 位置、记录大小与容量溢出。

上游提供 `ntfs_device_operations`，可注入 open/close、seek、read/write、pread/pwrite、sync、stat/ioctl；这支持继续研究 FSKit IO 适配。本轮 Swift `FSKitNTFSProbe` 仅编译了公共资源读取与识别接口，未获得扩展授予的真实资源，也未连接这些操作到 NTFS 核心。普通文件镜像成功不能抵扣 FSKit 资源读写、同步、取消、撤销和并发验证。

此外使用 `hdiutil attach -readonly` 将普通镜像接入 macOS 内建 NTFS：系统报告 `Internal=false`、`FilesystemType=ntfs`、`WritableVolume=false`，卷中中文文件可读；查询到 `VolumeUUID` 与 `MediaUUID` 均缺失。应用核心真实扫描识别到该卷和其有效 IOMedia 身份，重复查询身份一致，`DiskEjector` 成功非强制推出并确认设备消失。附加的系统集成测试会先复制镜像并核实所有权，避免操作任何用户磁盘。这证明当前系统只读路径与控制层的真实接入；不是自定义 FSKit 挂载或 NTFS 写入证据。

许可：检查的 libntfs-3g 设备及卷实现头部明确为 GPL-2.0-or-later；不能仅凭仓库中的 `COPYING.LIB` 把整个核心认定为 LGPL。pkgconf 的 COPYING 为宽松许可。当前产品未捆绑这些工具或库；若后续链接和对外分发，需要针对最终组合保留许可、版权、对应源码及构建/修改信息。

## 测试与产物

- 28 项 Swift Testing 测试通过，包括参数化用例。忙卷和身份变化测试使用假查询；单独的镜像集成测试执行真实系统扫描、身份重验和非强制推出，仅操作自身创建副本的只读挂载。
- 本地 UI 检查通过：启动时可见用户窗口 0、Dock 隐藏、图标存在、关闭设置后可见用户窗口 0、进程存活、图标可隐藏/恢复、演示偏好隔离。
- 四个原生设置页逐页截图并检查，关于页使用已确认的石墨色 S 图标。
- 修正默认 macOS 文件系统上 `DiskFerry` / `diskferry` 的构建产物碰撞，CLI 的 SwiftPM 产品改为 `diskferry-cli`；最终 CLI 名仍为 `diskferry`。

本地证据目录（不随源码上传，可通过 README 中的命令复现）：`artifacts/validation-2026-10-09`，包含 `tests.log`、`build.log`、`doctor.json`、`ui/smoke.json`、LaunchServices 启动检查、四页 PNG、镜像回读和系统只读接入报告。可运行产物：`dist/DiskFerry.app`、`dist/diskferry`。

## 下一阶段

同日菜单入口修复：原检查直接调用窗口展示，遗漏了菜单关闭后刷新与点击分发的时序。刷新会释放共享数组里的临时 action target，造成“设置”和“关于”无响应。现改为以常驻控制器作为 target，各菜单项保留自己的回调；即使菜单刷新，待分发的旧菜单项仍能执行。UI 检查已补上 AppKit 菜单分发，`settingsOpenedFromMenu` 和 `aboutOpenedFromMenu` 均为 true，证据见 `artifacts/menu-action-after-fix/smoke.json`。

同日新增登录自启动：通用设置加入原生复选框“开机自启动”及“登录项设置…”入口，采用 `SMAppService.mainApp`。启动只读取系统状态，用户勾选才注册；关闭时注销。回到应用或打开设置会刷新 macOS 的实际状态；被系统关闭或等待批准时不显示已启用，不自行重新注册。演示/截图模式不会更改登录项。本机真实注册从 notFound 到 enabled，注销后为 notRegistered，验证恢复为关闭；记录见 `artifacts/login-item-verification/login-item.json`。8 项登录项测试通过，覆盖成功、失败、外部变更、批准、初次注册、演示隔离与重复操作；浅色/深色四页及菜单打开回归均通过。尚未注销用户或重启电脑验证下一次登录启动。

1. 建立可签名的 FSKit 扩展目标，验证正常安装、启用、普通测试资源获取和只读挂载；保持默认系统安全策略。
2. 通过 `ntfs_device_operations` 接入 FSKit 的受控资源，验证部分 IO、错误、同步、取消、撤销与并发。
3. 在镜像上实现 Finder 所需的目录、属性、创建、覆盖、原子替换、重命名、随机写、截断等文件语义。
4. 加入 dirty、休眠、加密和未知状态的明确拒绝策略，再开放自动写入偏好；完成 Windows 一致性与真实测试介质验收。
5. 真实更新源、签名公证、统一安装与卸载、更新前推出及竞态控制单独完成后再交付日用版本。

本轮不是 G1 全部验收或 G2 的 Finder 日用闭环。当前没有写入接管、健康检查、更新安装或活动动画。

## 源码公开整理

2026-10-09 按用户要求整理并上传开发阶段源码，保留 GitHub 仓库原有 MIT 许可证。补充项目说明、贡献指南、第三方组件说明和 macOS 构建检查，保留选定品牌素材；不上传构建产物、测试镜像、日志或未选中的设计草稿。历史需求保留并注明状态，未创建正式版本或 Release。

整理时完整复验 36 项测试通过（包括一次性镜像的真实只读挂载、身份核验与非强制推出），Universal 2 应用及 CLI 构建、ad hoc 签名验证通过。96 张主品牌素材及母版的 SHA-256 与清单一致，Markdown 本地链接检查通过。日志保存在本地 `artifacts/open-source-tests.log` 与 `artifacts/open-source-build.log`。
