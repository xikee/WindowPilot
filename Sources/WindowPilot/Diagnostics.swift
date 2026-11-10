import Foundation

/// 显式启用的本机验证记录，不记录窗口内容、标题或键盘输入。
final class Diagnostics {
    static let shared = Diagnostics()
    private let file: FileHandle?

    private init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--diagnostics"), arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: arguments[index + 1])
            if FileManager.default.createFile(atPath: url.path, contents: nil) {
                file = try? FileHandle(forWritingTo: url)
            } else { file = nil }
        } else { file = nil }
    }

    func record(_ event: String, _ values: [String: Any] = [:]) {
        guard let file else { return }
        var record = values
        record["event"] = event
        record["time"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        try? file.write(contentsOf: data)
    }
}
