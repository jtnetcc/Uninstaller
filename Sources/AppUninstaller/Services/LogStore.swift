import AppKit
import Foundation

/// 操作日志：内存环形缓冲 + 磁盘 JSONL 持久化。线程安全，可从任意线程调用。
final class LogStore: ObservableObject {

    @Published private(set) var entries: [LogEntry] = []

    /// 单次会话最多在内存中保留的条数
    private let memoryLimit = 500
    private let fileQueue = DispatchQueue(label: "com.jt.AppUninstaller.log", qos: .utility)

    static let logDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Logs/AppUninstaller", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var dateTag: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static var currentLogFile: URL {
        logDirectory.appendingPathComponent("uninstall-\(dateTag).log")
    }

    init() {
        loadRecentFromDisk()
    }

    // MARK: 写入

    func append(_ level: LogLevel, action: String, target: String, detail: String? = nil) {
        let entry = LogEntry(date: Date(), level: level, action: action, target: target, detail: detail)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.memoryLimit {
                self.entries.removeLast(self.entries.count - self.memoryLimit)
            }
        }

        fileQueue.async {
            guard let data = try? JSONEncoder().encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            let text = line + "\n"
            let url = LogStore.currentLogFile
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
            } else {
                try? Data(text.utf8).write(to: url, options: .atomic)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    // MARK: 读取

    private func loadRecentFromDisk() {
        fileQueue.async { [weak self] in
            guard let self else { return }
            let url = LogStore.currentLogFile
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            let lines = content.split(separator: "\n").suffix(300)
            var loaded: [LogEntry] = []
            for line in lines {
                if let data = line.data(using: .utf8),
                   let entry = try? decoder.decode(LogEntry.self, from: data) {
                    loaded.append(entry)
                }
            }
            let sorted = loaded.reversed()
            DispatchQueue.main.async {
                self.entries = Array(sorted)
            }
        }
    }

    /// 全部日志文件（用于"在 Finder 中显示"）
    static func revealLogFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logDirectory.path)
    }
}
