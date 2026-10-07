import Foundation
#if os(Windows)
import WinSDK
#endif

/// Foundation's URL metadata on Windows can trap on files larger than Int32.max,
/// even when only isDirectory is requested. A name-only walk must tolerate large files.
struct HostFileMetadata {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isRegularFile: Bool
    let byteCount: Int
    let modified: Date?

    static var directoryEntryKeys: [URLResourceKey] {
        #if os(Windows)
        []
        #else
        [.isDirectoryKey, .isSymbolicLinkKey]
        #endif
    }

    static func read(_ url: URL, includingDetails: Bool = true) -> HostFileMetadata? {
        #if os(Windows)
        let path = Array(url.path.replacingOccurrences(of: "/", with: "\\").utf16) + [0]
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        let succeeded = path.withUnsafeBufferPointer {
            GetFileAttributesExW($0.baseAddress, GetFileExInfoStandard, &data)
        }
        guard succeeded else { return nil }
        let directory = data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        // Junctions and other reparse points are refused along with symbolic links.
        let link = data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
        let size = UInt64(data.nFileSizeHigh) << 32 | UInt64(data.nFileSizeLow)
        let ticks = UInt64(data.ftLastWriteTime.dwHighDateTime) << 32 | UInt64(data.ftLastWriteTime.dwLowDateTime)
        return HostFileMetadata(isDirectory: directory, isSymbolicLink: link,
            isRegularFile: !directory && !link,
            byteCount: Int(clamping: size),
            modified: ticks == 0 ? nil : Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600))
        #else
        let keys: Set<URLResourceKey> = includingDetails
            ? [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            : [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return HostFileMetadata(isDirectory: values.isDirectory == true, isSymbolicLink: values.isSymbolicLink == true,
            isRegularFile: values.isRegularFile == true, byteCount: values.fileSize ?? 0, modified: values.contentModificationDate)
        #endif
    }
}
