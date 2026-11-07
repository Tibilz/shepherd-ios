import Foundation

public struct DirEntry: Identifiable, Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let parent: String
    public init(name: String, isDirectory: Bool, parent: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
    }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var path: String { parent == "/" ? "/\(name)" : "\(parent)/\(name)" }
    public var id: String { path }
}

public struct DirListing: Equatable, Sendable {
    public let path: String
    public let entries: [DirEntry]
}

public enum RemoteFilesError: Error, LocalizedError, Equatable {
    case unreadable(String), invalidName, createFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let m): "Folder not readable: \(m)"
        case .invalidName: "Invalid folder name. It must not be empty or contain “/”."
        case .createFailed(let m): "Could not create folder: \(m)"
        }
    }
}

/// Lists directories on the server over a RemoteShell (names NUL-separated, so any character is safe).
public struct RemoteFiles: Sendable {
    public static let marker = "__HERDR_FILES__"
    public let shell: RemoteShell
    public init(shell: RemoteShell) { self.shell = shell }

    static func script(_ path: String?) -> String {
        let p = path.map { "P=\(ShellQuote.quote($0))" } ?? #"P="$HOME""#
        return """
        printf '%s\\n' \(marker)
        \(p)
        cd -- "$P" || exit 2
        printf '%s\\0' "$(pwd -P)"
        for f in * .[!.]* ..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          if [ -d "$f" ]; then printf 'd\\t%s\\0' "$f"; else printf 'f\\t%s\\0' "$f"; fi
        done
        """
    }

    /// `nil` lists the home directory. Folders first (visible, then hidden), then files; each by name.
    public func list(_ path: String?) async throws -> DirListing {
        let res = try await shell.exec(SocketCommand.login(Self.script(path)))
        var out = res.stdout
        if let r = out.range(of: Data((Self.marker + "\n").utf8), options: .backwards) {
            out = out.subdata(in: r.upperBound..<out.endIndex)
        }
        guard res.exitCode == 0 else {
            let err = String(decoding: res.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteFilesError.unreadable(err.isEmpty ? (path ?? "~") : err)
        }
        let parts = out.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        guard let dir = parts.first else { throw RemoteFilesError.unreadable(path ?? "~") }
        let entries = parts.dropFirst().compactMap { item -> DirEntry? in
            let f = item.split(separator: "\t", maxSplits: 1).map(String.init)
            guard f.count == 2 else { return nil }
            return DirEntry(name: f[1], isDirectory: f[0] == "d", parent: dir)
        }
        func rank(_ e: DirEntry) -> Int { (e.isDirectory ? 0 : 2) + (e.isHidden ? 1 : 0) }
        let sorted = entries.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return DirListing(path: dir, entries: sorted)
    }

    /// Creates `name` inside `parent` and returns the new folder's path.
    public func makeDirectory(in parent: String, named rawName: String) async throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\u{0}") else {
            throw RemoteFilesError.invalidName
        }
        let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
        let res = try await shell.exec(SocketCommand.login("mkdir -- \(ShellQuote.quote(path))"))
        guard res.exitCode == 0 else {
            let err = String(decoding: res.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteFilesError.createFailed(err.isEmpty ? path : err)
        }
        return path
    }

    public static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}
