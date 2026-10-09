import DiskFerryCore
import Foundation

@main
struct DiskFerryCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args {
            case ["scan"], ["scan", "--demo"]:
                let snapshot = args.contains("--demo") ? DiskSnapshot.demo : try await DiskScanner().scan()
                let report = DiagnosticReport(environment: .inspect(), snapshot: snapshot)
                FileHandle.standardOutput.write(try report.json())
                FileHandle.standardOutput.write(Data("\n".utf8))
            case ["doctor"]:
                let report = DiagnosticReport(environment: .inspect(), snapshot: try await DiskScanner().scan(),
                                              backend: await BackendInspector.inspect())
                FileHandle.standardOutput.write(try report.json())
                FileHandle.standardOutput.write(Data("\n".utf8))
            case ["backend"]:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(await BackendInspector.inspect()))
                FileHandle.standardOutput.write(Data("\n".utf8))
            case let values where values.count == 2 && values[0] == "probe-image":
                let path = values[1]
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(NTFSBootSector.inspectImage(at: URL(fileURLWithPath: path))))
                FileHandle.standardOutput.write(Data("\n".utf8))
            case ["--version"]:
                print(DiskFerryVersion.current)
            case [], ["help"], ["--help"], ["-h"]:
                print("""
                盘渡 DiskFerry \(DiskFerryVersion.current)
                diskferry scan [--demo]    输出外置磁盘检测报告（JSON）
                diskferry doctor          检查系统、磁盘与 FSKit 扩展（JSON）
                diskferry backend         查询已安装的 FSKit 扩展（JSON）
                diskferry probe-image FILE 检测普通镜像的 NTFS 引导扇区（JSON）
                CLI 仅检测；安全推出通过菜单栏中的明确操作执行。NTFS 写入尚未开放。
                """)
            default:
                FileHandle.standardError.write(Data("未知参数。运行 diskferry --help 查看用法。\n".utf8))
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("检测失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
