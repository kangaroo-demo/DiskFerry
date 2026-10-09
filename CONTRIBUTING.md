# 贡献指南

盘渡当前为开发阶段，NTFS 写入引擎尚未接入。请以 [README](README.md) 描述的实际能力为基准。

## 开发

使用包含 macOS 15.4 或更新 SDK 的完整 Xcode 和 Swift 6：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash Scripts/build-app.sh
open dist/DiskFerry.app --args --demo --settings
```

演示模式不操作真实磁盘或登录项。系统镜像测试为显式选择运行，具体步骤见 README。不要使用存有个人数据的磁盘进行开发验证。

## 提交改动

- 先说明具体问题、预期行为、macOS / Xcode 版本及复现步骤；较大的后端或产品范围变更建议先开 Issue。
- 保持 macOS 原生控件、系统字号与菜单栏生命周期，避免不必要的常驻窗口。
- 磁盘操作必须重新核验当前连接身份。保留外置整盘限制、非强制推出及操作后确认。
- 不把偏好开关、引导扇区识别或扩展已安装当作已完成安全写入的证据。
- 对功能和安全边界的变更增加相应测试，提交前运行测试和构建；在 PR 中说明实际验证范围。
- 不提交构建产物、镜像、日志、签名凭据或个人磁盘信息。新增依赖时记录固定版本、来源与许可证。

贡献按本仓库 MIT 许可提交；第三方代码必须保留原有版权和许可证，并说明来源。
