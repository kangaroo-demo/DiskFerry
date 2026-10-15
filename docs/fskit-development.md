# 实验 FSKit 扩展开发

`DiskFerryFSKit.xcodeproj` 将原生菜单栏宿主、MIT 控制层 framework 和独立 GPL NTFS 扩展组合为开发应用。默认 Swift Package 和 `Scripts/build-app.sh` 不包含该扩展。

当前实验扩展只读，未注册自动介质匹配，宿主仍报告 `writeEngineQualified = false`。编译、ad hoc 签名、`pluginkit` 注册均不能证明 FSKit 已接纳扩展。实际系统挂载、资源回调、Finder 读写和默认安全设置下的分发仍待验收，不能作为正式版本安装。

## 环境与构建

扩展需要 macOS 26.4+ 和包含对应 SDK 的完整 Xcode；已在 macOS 26.5 / Xcode 26.5 / Apple Silicon 编译。控制层单独构建仍以 macOS 13 为目标。实验扩展及 NTFS 静态库目前只构建本机架构，不能用默认宿主的 Universal 2 构建结果推断扩展支持 Intel。

```bash
bash Scripts/prepare-ntfs-core.sh
bash Scripts/build-app.sh
python3 Tests/NTFSBridgeTests/test_ntfs_bridge.py
python3 -m unittest discover -s Tests/RemovableVolumeTests -v
bash Scripts/test-fskit-adapter.sh
bash Scripts/build-fskit-extension.sh
```

固定依赖下载到 `.build/vendor`，先验证 SHA-256，再在项目内编译，不执行 `make install`。实验脚本产物位于 `dist/experimental/DiskFerry.app`，仅作编译与包完整性检查，不安装或启用扩展。

Xcode 工程的无签名构建：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project DiskFerryFSKit.xcodeproj -scheme DiskFerry \
  -configuration Debug -derivedDataPath .build/xcode-fskit \
  CODE_SIGNING_ALLOWED=NO build
```

无签名产物不能用于系统挂载验收。Xcode 构建可能向 Launch Services 登记产物；切回默认开发应用时，可注销该产物，再登记实际要运行的应用，避免登录项或重新打开时命中其他副本：

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/.build/xcode-fskit/Build/Products/Debug/DiskFerry.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$PWD/dist/DiskFerry.app"
```

GitHub Actions 的 `Experimental FSKit build and image tests` 工作流对修改扩展相关文件的 PR 执行同一组镜像、值对象和构建检查，也支持手动运行。它明确要求 macOS 与 SDK 26.4+；托管 runner 不满足时检查失败，不跳过后冒充通过。此工作流不签名、不安装驱动、不访问物理盘，也不替代系统挂载验收。

## 正式身份配置与系统接入

在 Xcode 打开 `DiskFerryFSKit.xcodeproj`，为宿主与扩展选择自己的 Apple Developer Team，保留自动签名。扩展声明 `com.apple.developer.fskit.fsmodule` 与 App Sandbox；配置描述文件和签名必须实际授权这些能力。仓库不包含 Team ID、证书、私钥或描述文件。

本地 ad hoc / 自签名证书只证明包内容完整，不能代替 Apple Development 配置或 Developer ID 分发身份。开发验证需要系统接受真实签名及扩展；分发还需 Developer ID、Hardened Runtime、签名许可检查、公证和安装复验。不要关闭 SIP、降低启动安全策略或把手工注册记录当作通过。

在系统设置的“通用 → 登录项与扩展 → 文件系统扩展”中核对启用状态，并用 `dist/diskferry backend` 检查 FSKit 的实际枚举结果。即使扩展出现在枚举中，也必须继续取得真实资源并完成挂载与文件操作。目前没有经验证的手工挂载命令或可启用写入的开关；不得仅修改 readiness 常量或 `FSMediaTypes` 跳过这些阶段。

## 验证边界

- C 桥接测试新建 64 MiB 普通 NTFS 镜像，覆盖读写、Unicode、随机写、截断、稀疏空洞、满盘、ADS 扩展属性、重新打开后的持久化、只读拒绝所有修改、同步失败、写失败、脏卷和休眠卷。它不调用 FSKit 或访问物理盘。
- Swift 测试验证控制层与系统只读镜像。镜像扫描和推出不等于自定义文件系统挂载。
- `Scripts/verify-removable-volume.py` 对明确指定 UUID 的外置物理 USB 新建专有测试目录。报告保存在其他卷，保留目录描述符并拒绝符号链接、设备身份变化和挂载点逃逸。`verify` 可在正常卸载并重新挂载后复查。它不会格式化、访问裸设备或强制卸载。
- 实盘 FAT32 结果只证明系统 FAT32 路径。NTFS 引擎镜像结果只证明桥接路径。FSKit 生命周期、读写策略传递、异常断开保护、Windows 互操作、下次登录自启动和正式分发必须分别提供证据。

实盘工具示例中必须替换为本次重新核验的设备号及 UUID，不得复制历史设备号后直接运行：

```bash
python3 Scripts/verify-removable-volume.py write \
  --device diskNsM --expect-volume-uuid YOUR_VERIFIED_VOLUME_UUID \
  --report artifacts/usb-verification.json
python3 Scripts/verify-removable-volume.py verify --report artifacts/usb-verification.json
```

完整阶段和发布门槛见 [首版验收计划](first-release-plan.md)。原始报告、测试数据、镜像和本机身份保留在忽略的 `artifacts/`，不提交到仓库。

## 对应源码与许可

扩展整体为 GPL-2.0-only，来源和本地修改见 [UPSTREAM.md](../Extensions/DiskFerryNTFS/UPSTREAM.md)，依赖版本、校验值和原许可范围见 [第三方说明](../THIRD_PARTY_NOTICES.md)。扩展通过公开 macOS 接口与独立 MIT 宿主交互，不链接到宿主进程。

未来分发含扩展的二进制时，须同时提供匹配版本的完整对应源码：本仓库扩展和构建脚本、确切 NTFS-3G 源码、所需配置及修改、原始版权和许可。仅提供下载链接或 MIT LICENSE 不能代替这项交付。发布流水线和源码归档尚待实际分发验收。
