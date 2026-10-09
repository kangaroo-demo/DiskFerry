# 第三方组件说明

仓库自身的代码、文档与品牌素材沿用根目录 [MIT License](LICENSE)。以下工具及平台使用各自的许可；本仓库的 MIT 许可不改变第三方许可。

## 应用构建

当前 Swift Package 没有外部包依赖，也未链接或捆绑 NTFS-3G、pkgconf、macFUSE 或第三方驱动。应用使用 macOS 随系统提供的 Foundation、AppKit、SwiftUI、Combine、Disk Arbitration、IOKit、ServiceManagement 和 FSKit 等公开框架，以及系统命令。Apple 框架、SDK 和工具并非本仓库再许可的代码。

## 可选 NTFS 镜像验证工具

`Scripts/prepare-ntfs-core.sh` 从以下来源下载固定版本，核验 SHA-256，并在忽略的 `.build/vendor/` 中构建。上游源码、版权声明和许可证保留在下载包内；当前源码仓库和应用包不包含这些库或工具。

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
