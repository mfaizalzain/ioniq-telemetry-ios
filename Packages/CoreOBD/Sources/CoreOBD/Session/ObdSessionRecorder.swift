import Foundation

/// Records raw request/response pairs to a file that can be played back later.
public final class ObdSessionRecorder: @unchecked Sendable {

    private let directory: URL
    private let fileLock = NSLock()
    private var _file: URL?

    public var isRecording: Bool {
        fileLock.withLock { _file != nil }
    }

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func start() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let f = directory.appendingPathComponent("obd-session-\(stamp).txt")
        try? "# Ioniq 5 OBD session capture \(stamp)\n".write(to: f, atomically: true, encoding: .utf8)
        protect(f)
        fileLock.withLock { _file = f }
        return f
    }

    /// A capture is a raw dump of everything the car reported — VIN included — and
    /// it is a debugging artefact, not user data worth restoring. Encrypt it at rest
    /// and keep it out of backups.
    ///
    /// `completeUnlessOpen` rather than `complete`: a capture started before the
    /// phone locks has to keep being appended to for the rest of the drive.
    private func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func record(command: String, rawResponse: String) {
        guard let f = fileLock.withLock({ _file }) else { return }
        let line = ">\(command)\n\(rawResponse.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if let handle = try? FileHandle(forWritingTo: f) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
    }

    @discardableResult
    public func stop() -> URL? {
        fileLock.withLock {
            let f = _file
            _file = nil
            return f
        }
    }

    public func listSessions() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("obd-session-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
