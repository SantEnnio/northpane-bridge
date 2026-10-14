import Foundation

/// The platform file store must keep one encryption key across independently
/// constructed stores and Bridge processes.
enum SecureMaterialKeyFile {
    static func loadOrCreate(at url: URL) throws -> Data {
        // Atomic replacement alone does not serialize creators: two stores can
        // retain different keys, leaving one unable to read the other's values.
        let lock = try CrossProcessLock(path: url.appendingPathExtension("lock"))
        defer { lock.unlock() }
        let bytes: Data
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SecureMaterialError.unavailable(-1) }
            bytes = try Data(contentsOf: url)
        } else {
            bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard bytes.count == 32 else { throw SecureMaterialError.unavailable(-1) }
        return bytes
    }
}
