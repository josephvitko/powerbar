import Foundation

enum Storage {
    /// `~/Library/Application Support/PowerBar`, or `$POWERBAR_DATA_DIR` (used to test without touching real history).
    static let directory: URL = {
        let dir = ProcessInfo.processInfo.environment["POWERBAR_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PowerBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
