# 第三方组件说明

除单独注明许可的文件外，仓库自身的代码、文档与品牌素材沿用根目录 [MIT License](LICENSE)。`Extensions/DiskFerryNTFS/` 实验扩展整体使用 GPL-2.0-only，不能按根目录 MIT 许可再许可。以下工具及平台使用各自的许可。

## 应用构建

默认 Swift Package / `Scripts/build-app.sh` 构建没有外部包依赖，也未链接或捆绑 NTFS-3G、pkgconf、macFUSE 或第三方驱动。应用使用 macOS 随系统提供的 Foundation、AppKit、SwiftUI、Combine、Disk Arbitration、IOKit、ServiceManagement 和 FSKit 等公开框架，以及系统命令。Apple 框架、SDK 和工具并非本仓库再许可的代码。

## 实验 FSKit 扩展

`Extensions/DiskFerryNTFS/` 的部分代码来自 [NTFSKit 的 GPL 驱动](https://github.com/whereteam/ntfskit/tree/96ecccb1b1f6dba2ecd158ed0ff9a21e7917c80d/NTFSModule)，固定提交 `96ecccb1b1f6dba2ecd158ed0ff9a21e7917c80d`，原项目归属 DNA MAKER COMPANY LIMITED 及贡献者。未引入其专有宿主界面。原许可文本和本地修改清单见 [GPLv2](Extensions/DiskFerryNTFS/LICENSE.GPL2) 与 [UPSTREAM.md](Extensions/DiskFerryNTFS/UPSTREAM.md)。

单独的 `Scripts/build-fskit-extension.sh` 或 `DiskFerryFSKit.xcodeproj` 会将固定 NTFS-3G 静态库链接到实验扩展；不链接到 MIT 菜单栏宿主。扩展整体按 GPL-2.0-only 提供，桥接 C 文件原有 GPL-2.0-or-later 声明及其他文件声明保留。实验包包含相关许可文本；未来向他人提供二进制时还须提供匹配的完整对应源码及构建信息。当前扩展未通过系统签名接纳、真实资源挂载和正式分发验收，不在正式 Release 中交付。

## 可选 NTFS 镜像验证工具

`Scripts/prepare-ntfs-core.sh` 从以下来源下载固定版本，核验 SHA-256，并在忽略的 `.build/vendor/` 中构建。上游源码、版权声明和许可证保留在下载包内；默认控制层应用不包含这些库或工具。实验扩展的链接范围见上一节。

| 组件 | 版本 | 来源 | 许可 |
| --- | --- | --- | --- |
| NTFS-3G / ntfsprogs | 2026.9.28 | [上游源码包](https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz) | 已检查的 libntfs-3g 设备及卷实现为 GPL-2.0-or-later；以各文件声明为准 |
| pkgconf | 2.3.0 | [上游源码包](https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz) | 宽松许可，以源码中的 COPYING 为准 |

校验值：

```text
ntfs-3g_ntfsprogs-2026.9.28.tgz
350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8

pkgconf-2.3.0.tar.xz
3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b
```

不能仅依据 NTFS-3G 仓库内的 `COPYING.LIB` 将整个核心认定为 LGPL。未来如链接、修改或分发 NTFS-3G，需针对最终组合确定许可兼容性，保留版权和许可证，并提供相应源码、修改与构建信息。当前 MIT 源码许可不代表未来包含 GPL 组件的应用组合仍可只按 MIT 分发。

## 品牌素材导出

已导出的 PNG、JPG、ICNS 与母版保存在 `Resources/Brand/`，应用直接使用这些文件。

- `export_assets.py` 可选依赖 [Pillow](https://github.com/python-pillow/Pillow)，遵循 Pillow 的 HPND 等许可；Pillow 本身未捆绑入应用或仓库。
- 文字由 macOS 系统字体 Hiragino Sans GB 和 Avenir Next 渲染，字体文件未再分发。
- ICNS 通过 macOS 自带 `iconutil` 生成。
