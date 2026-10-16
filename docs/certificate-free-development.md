# 没有付费证书时的系统验证

2026-10-16 核对 Apple 的 [macOS 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)：`FSKit Module` 支持 ADP 和 Developer ID 两列，免费 Apple Developer 一列为空。免费 Personal Team 的普通设备测试能力不能视为拥有这一受限权限。自行构建的 DiskFerry FSKit 扩展仍需要授权该 entitlement 的签名与配置描述文件。

可以使用另行安装的 [macFUSE](https://macfuse.github.io/) 已签名 FSKit 后端，让普通用户态文件系统进程接入系统。开发者无需为这个进程取得 FSKit entitlement。官方 [后端说明](https://github.com/macfuse/macfuse/wiki/FUSE-Backends) 指定 `-o backend=fskit`；默认后端是内核扩展，因此本项目验证工具固定该选项，不提供自动回退。

这是一条待验收的可选接入路线，不代表当前 DiskFerry 已经支持 Finder 写入，也不能解决 DiskFerry 自身的 Developer ID 分发签名与公证。首版完整验收范围继续见 [验收计划](first-release-plan.md)。

## 准备运行时

从 [官方 5.4.0 发布页](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.4.0) 下载并通过 macOS 安装器安装。安装时需要本机管理员认证；密码只在系统界面输入。使用 FSKit 后端不需要在恢复模式开启内核扩展或修改 SIP。

本机已核对的官方 DMG：

```text
macfuse-5.4.0.dmg
SHA256 861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5
```

安装包的 `pkgutil --check-signature` 显示 Apple 分发签名和公证有效，签名主体为 `Developer ID Installer: Benjamin Fleischer (3T5GSNBU6W)`；提取的 app 及扩展通过严格签名完整性检查。以上只证明该下载的身份与完整性，未安装、未挂载不算系统接入通过。

安装完成后，在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”中启用 macFUSE 的文件系统扩展。用 `dist/diskferry backend` 核对实际枚举结果；这一步仍不能代替真实资源挂载。

macFUSE 的运行时包含闭源组件，许可对商业软件捆绑和自动下载/安装有限制。DiskFerry 不将该运行时加入源码包、应用包或 Release；使用者从官方渠道独立安装。未来商业分发应重新核对其许可及必要授权，不能将整个依赖称为开源软件。

## 只读接入工具

`Tools/DiskFerryMacFUSE/` 是独立 GPL-2.0-only 的开发工具，动态链接外部 libfuse，复用现有 NTFS 桥接与固定版本核心。它不加入默认 Swift 应用，也不改变写入就绪状态。

```bash
bash Scripts/prepare-ntfs-core.sh
bash Scripts/build-macfuse-probe.sh
python3 Tests/MacFUSEProbeTests/test_readonly.py
```

无安装环境也可先编译：用 `pkgutil --expand-full` 提取官方安装包，设置 `DISKFERRY_MACFUSE_PREFIX` 为提取结果中 `Core.pkg/Payload/usr/local` 的绝对路径。该方式仅提供头文件和链接文件，不能运行系统挂载。回调测试不加载 libfuse 或 FSKit 运行时；不能据此宣称 FSKit 已通过。

验证工具仅接受专用、未附加或被其他程序修改的普通 NTFS 镜像，始终以 `O_RDONLY` 打开，不提供写入能力或裸设备参数，拒绝符号链接和其他文件类型。发现源文件身份、大小或修改时间变化后拒绝继续读取。挂载路径必须直接位于 `/Volumes` 下，缺失的最终目录由 macFUSE 5.4 创建。

macFUSE 的后端文档指出 FSKit 会以读写模式打开文件句柄。适配器接受此类传输句柄，但底层镜像描述符、挂载选项和全部修改操作仍为只读；显式创建、截断和任何数据写入都返回错误。这一接口差异需要真实挂载进一步验证。

安装及启用运行时之后，可对准备好的**一次性镜像**执行：

```bash
.build/macfuse-probe/diskferry-macfuse-readonly \
  /absolute/path/to/disposable.ntfs /Volumes/DiskFerry-Test
```

工具在前台运行。另一个终端或 Finder 可读取文件，完成后正常卸载：

```bash
diskutil unmount /Volumes/DiskFerry-Test
```

应记录实际文件系统提供方、Finder 与命令行读取结果、时间/名称/扩展属性，以及卸载前后镜像哈希。挂载失败须保留原始错误，不改用系统 NTFS 驱动冒充成功。当前尚无这条路线的系统挂载证据。

## 已完成与下一步

普通镜像上的生产 FUSE 回调检查通过：读取与 EOF、独立 Unicode 名称、大小写查找、符号链接、100 纳秒/负 Unix 时间、目录缓冲区分页、扩展属性大小、并发序列化、写入拒绝、设备和符号镜像路径拒绝、外部修改源文件后返回错误。测试后完整镜像 SHA-256 保持一致。AddressSanitizer/UndefinedBehaviorSanitizer 检查也通过；仪器覆盖新适配器与 C 测试程序，不覆盖预编译 NTFS 库和系统 FSKit。

下一步是安装并启用运行时后的真实只读 FSKit 挂载。随后才能完善并验证写入适配、真实设备授权与策略、持久化和故障处理。实际 U 盘 NTFS 读写、Windows 交叉验证、下次登录及正式分发仍未完成。
