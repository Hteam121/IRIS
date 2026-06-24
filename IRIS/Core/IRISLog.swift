//
//  IRISLog.swift
//  IRIS — Core
//
//  Lightweight file logger. NSLog from a GUI app doesn't reliably surface via `log show`, so we
//  also append diagnostics to ~/.iris/iris.log for easy inspection (tail -f ~/.iris/iris.log).
//

import Foundation

enum IRISLog {
    private static let queue = DispatchQueue(label: "com.iris.log")
    private static let url: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".iris/iris.log")

    static func log(_ message: String) {
        NSLog("[IRIS] \(message)")
        queue.async {
            let line = "\(Self.stamp()) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
