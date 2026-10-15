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

固定 NTFS-3G 原始源码包保留在 `Vendor/`，pkgconf 下载到 `.build/vendor`；均先验证 SHA-256，再在项目内编译，不执行 `make install`。实验脚本产物位于 `dist/experimental/DiskFerry.app`，仅作编译与包完整性检查，不安装或启用扩展。

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

- C 桥接的 32 项测试新建 64 MiB 普通 NTFS 镜像，覆盖读写、Unicode、随机写、截断、稀疏空洞、满盘、ADS 扩展属性、重新打开后的持久化、只读拒绝所有修改、故障后停止写入、同步失败、脏卷、休眠卷、无效 Windows 日志及内部元数据保护。另用独立 ntfscp 导入大小写冲突文件，用原始 ntfscat 读取 STANDARD_INFORMATION 时间字节，避免仅以桥接自己的解码验证写入。子进程被 SIGKILL 后，验证脏标记保留、再次读写挂载被拒绝及已同步数据可只读回读。它不调用 FSKit 或访问物理盘，也不模拟硬件断电。
- Swift 包测试验证控制层与系统只读镜像。另有 36 项 FSKit 适配测试：9 项校验属性/几何值对象，8 项通过与扩展共用的创建代码验证创建属性、重名保护、写入故障及只读拒绝，19 项直接调用生产卷方法验证命名空间、打开后删除、覆盖重命名、缓存身份、并发、名称编码、时间精度和退出失败。镜像传输使用普通文件的 pread/pwrite/fsync，不取得真实 FSKit 资源，也不模拟 FSKit 缓存。文件数据缓冲区和目录打包器仍需系统验收；镜像扫描和推出不等于自定义文件系统挂载。
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

## 写入会话与故障保护

C 引擎先以只读方式检查卷标志、休眠文件和 Windows 日志。只有健康检查通过，才通过禁止自动修改的 `NTFS_MNT_FORENSIC` 句柄写入本次会话的脏标记，并完成同步。正常可写引擎随后打开，因此引擎自动挂载修改也处于脏标记保护下。标记同步失败时不返回可写句柄。

读、写或同步回调发生故障后，该会话永久拒绝后续文件修改；即使底层回调恢复成功，也不能返回“同步成功”或清除脏标记。正常结束时先同步保留的索引和 inode 状态，关闭并同步数据句柄，之后才使用独立元数据句柄清除本次会话的标记。检查操作和只读挂载从不清除原有脏状态，也不回放或重置 Windows 日志。

以上依赖调用方独占资源，以及 `nk_io.sync` 真正持久化完成的写入并返回准确错误的契约。镜像测试使用普通文件的 `fsync`；现有 FSKit 资源适配器的同步语义、硬件缓存、异常拔出和断电行为仍需真实签名模块及实盘验证。这些检查通过前，默认宿主仍报告写入不可用，实验扩展仍只读。

## 内部元数据边界

NTFS 核心的内部 API 可以修改 `$MFT`、`$LogFile` 等元数据；不能直接将这个权限提供给文件路径接口。公共路径逐层检查真实 inode 编号，并检查文件的所有 FILE_NAME 父记录，拒绝内部记录、`$Extend` 目录及其文件的别名。读取、属性、数据、命名空间和 ADS 接口使用同一边界。卷标与会话脏标记通过独立的内部维护接口修改。

根目录仍可创建普通文件和目录、修改时间与扩展属性，但不能被移动、删除或作为普通数据截断。保护不依据文件名的 `$` 前缀或 SYSTEM 标志，因此用户文件及 Interix 符号链接仍可使用。镜像测试核对拒绝操作的 errno、回调写入计数及镜像字节保持不变。

## 创建属性

文件、目录和符号链接创建前校验整组属性和名称，支持的大小与时间属性在同一引擎队列任务内应用，并回报实际消费的属性。命名空间锁覆盖整个创建/配置过程。配置失败时只尝试删除本次已成功创建的项；创建本身返回 EEXIST 时从不进入清理路径。

按 FSKit SDK 的接口契约，目录和符号链接上的大小请求会被忽略，不执行截断、不转换为有符号大小，也不声明已消费该属性；其他支持的属性仍会应用。值对象和普通镜像测试均使用 UInt64.max 覆盖这一边界，并核对符号链接目标保持正确。

设备故障后会话已冻结，清理可能失败；此时返回原始错误并记录清理失败，保留脏状态，不返回创建成功。普通镜像测试注入了创建成功后首个属性写入的真实回调故障，并验证重新打开时卷仍脏。

目前属性展示使用固定的文件/目录/符号链接模式和运行用户身份；更改权限、所有者或未支持的标志会返回错误。此实现尚未完成 Unix 权限映射，不能声称所有应用的创建请求均可用。真实 FSKit 创建、并发、权限与 Finder 行为仍需继续完善和系统验收。

## 文件时间精度与兼容性

创建和属性修改现在保留 NTFS 的 100 纳秒精度，小于 100 纳秒的部分向下取整。C 接口用显式位图区分未请求的时间与合法负 Unix 秒数，支持从 1601 年的 NTFS 起点到当前引擎的有符号 64 位 tick 上限。Swift 与 C 都在修改前检查整组时间，包括最大秒数上的小数溢出，避免无效日期在大小修改之后才被发现。读取使用向下取整的秒数与非负纳秒，修复旧转换对 1970 年前的小数时间的误读；元数据修改也更新 changeTime。

普通镜像测试核对创建、设置、未请求字段保留、重新打开、负 Unix 秒数、上下边界、只读拒绝，以及错误请求不产生回调写入、截断或部分时间修改。原始 ntfscat 独立读取落盘的 STANDARD_INFORMATION 属性，并按 NTFS FILETIME 定义核对字节值。

在 macOS 26.5 自带只读 NTFS 驱动的独立回读中，五个文件的内容正确，现代日期的 access/modify 时间符合 100 纳秒精度；1970 年前的时间却显示为溢出的大数，系统 stat 命令也确认同一现象。原始 FILETIME 字节及 DiskFerry 镜像回读均正确；这项系统时间检查仍记录为失败，不能用原始字段正确替代 Windows 或实际 FSKit 的跨系统验证。默认宿主依然报告写入不可用。

FSKit 能力现在明确声明不支持设置文件权限，与当前固定模式及 ENOTSUP 行为一致。这不代表 Unix 权限或所有应用创建模式已通过系统验收。

## 打开后删除、替换与并发

已在实际卷方法中复现并修复两项问题：删除后重建同名文件时，旧 FSItem 写入会覆盖新文件；覆盖重命名后，仍被引用的目标文件立即变为不可访问。现在删除和替换将旧文件保留在本次会话登记的根目录私有链接下，公共查找与枚举隐藏该链接，旧句柄继续访问原数据，链接数回报 0，直到 reclaim 或正常卸载才删除。原父目录因此仍可删除。不会按文件名前缀清理崩溃遗留文件或其他用户文件。

命名空间锁覆盖路径解析和实际引擎调用，避免获取路径后被另一请求重命名或复用。目录移动同步更新缓存子对象和标识；回收后的对象、上一挂载会话的对象返回 ESTALE。过期源名称、错误覆盖对象、非空目录及文件/目录类型不匹配均在修改前拒绝。

覆盖操作回滚失败时保留已知私有链接，冻结本卷命名空间访问并让同步和退出保持失败，防止继续沿不确定路径读写或清除脏标记。回收或卸载清理失败也不能返回干净退出。C 层保持设备故障的 EIO，防止 inode 清理将其覆盖成 ENOENT 等错误。

11 项卷测试包括中文与 emoji 目录移动、200 次重命名与写入/属性/扩展属性并行操作、重新打开后的独立内容校验，以及覆盖操作和回滚同时失败。可额外运行同一组测试的 ThreadSanitizer 构建：

```bash
DISKFERRY_TEST_TSAN=1 bash Scripts/test-fskit-adapter.sh
```

本机普通与线程检查模式均通过；这不证明真实 FSKit 的引用释放顺序或缓存同步正确。模块当前自行保留旧数据，关闭 FSKit 的 open-unlink 仿真；真实签名系统上的打开、删除、关闭和 reclaim 顺序仍是发布门槛。持久标识和权限映射也仍需完善。

## 文件名、大小写与编码

查找先按磁盘 UTF-16 名称精确匹配，再使用该卷的 `$UpCase` 表查找唯一的大小写匹配，向 FSKit 返回磁盘实际名称。后续数据和命名空间操作始终用实际路径。已有多个仅大小写不同的名称时，精确查找仍可区分；没有精确匹配且有多个大小写候选时返回 EIO，不猜测目标。新建文件、目录、符号链接和重命名会拒绝新增大小写重名，支持保留数据的仅大小写重命名。

关闭 NTFS-3G 旧 macFUSE 路径的自动 NFC/NFD 转换；该转换会将不同 NTFS 名称合并，并让枚举名称与磁盘编码不同。路径缓存和目录前缀比较改用精确 UTF-8 字节，防止 Swift String 的规范等价比较把 `Caf\u{e9}` 与 `Cafe\u{301}` 指向同一对象。普通镜像测试验证两目录、子文件、移动及独立重新读取的数据互不干扰。

所有名称入口拒绝空名称、`.`、`..`、斜杠、NUL 与超长组件；C 入口也独立校验可表示的边界，测试确认拒绝时无回调写入且镜像字节不变。内部元数据保护同时适用于大小写查找。

这仍是适配层行为，尚未更改 FSKit 的系统大小写能力声明或证明内核缓存行为。DOS 8.3 别名查找、规范等价名称在 Finder/Windows 的表现及已有冲突目录的修改行为仍待完善和系统验收；不可据此宣称完整 Windows 文件名兼容。

## 对应源码与许可

扩展整体为 GPL-2.0-only，来源和本地修改见 [UPSTREAM.md](../Extensions/DiskFerryNTFS/UPSTREAM.md)，依赖版本、校验值和原许可范围见 [第三方说明](../THIRD_PARTY_NOTICES.md)。扩展通过公开 macOS 接口与独立 MIT 宿主交互，不链接到宿主进程。

未来分发含扩展的二进制时，须同时提供匹配版本的完整对应源码：本仓库扩展和构建脚本、确切 NTFS-3G 源码、所需配置及修改、原始版权和许可。仅提供下载链接或 MIT LICENSE 不能代替这项交付。发布流水线和源码归档尚待实际分发验收。
