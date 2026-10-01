import Foundation

// MARK: - Path safety

public enum PathRules {
    public static let forbiddenComponents: Set<String> = [".merge_backup", ".git"]

    /// Returns a clean project-relative path or throws. Rejects absolute paths, "..", and protected dirs.
    public static func validate(_ rel: String) throws -> String {
        let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { throw MergeError.invalidPath(rel) }
        let comps = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.isEmpty { throw MergeError.invalidPath(rel) }
        for c in comps where c == "." || c == ".." || forbiddenComponents.contains(c) {
            throw MergeError.invalidPath(rel)
        }
        return comps.joined(separator: "/")
    }
}

// MARK: - Index

public struct ProjectFile: Hashable, Sendable {
    public let relPath: String
    public let url: URL
    public var name: String { url.lastPathComponent }
}

public struct ProjectIndex: Sendable {
    public let root: URL
    public let files: [ProjectFile]
    public let byPath: [String: ProjectFile]
    public let byName: [String: [ProjectFile]]

    public init(root: URL, files: [ProjectFile]) {
        self.root = root
        self.files = files
        var p: [String: ProjectFile] = [:]
        var n: [String: [ProjectFile]] = [:]
        for f in files {
            p[f.relPath] = f
            n[f.name, default: []].append(f)
        }
        self.byPath = p
        self.byName = n
    }
}

// MARK: - Scanner

public enum ProjectScanner {
    public static let defaultIgnored: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "__pycache__",
        ".DS_Store", ".merge_backup", ".build", "DerivedData",
    ]

    /// All regular files under `root` (symlinks and ignored names skipped), as (relative path, url).
    public static func regularFiles(in rootURL: URL,
                                    ignored: Set<String> = defaultIgnored) -> [(rel: String, url: URL)] {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        let rootPrefix = root.path + "/"
        var out: [(rel: String, url: URL)] = []
        for case let url as URL in en {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if ignored.contains(url.lastPathComponent) {
                if rv?.isDirectory == true { en.skipDescendants() }
                continue
            }
            if rv?.isSymbolicLink == true { continue }
            guard rv?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else { continue }
            out.append((String(path.dropFirst(rootPrefix.count)), url))
        }
        return out.sorted { $0.rel < $1.rel }
    }

    public static func scan(_ rootURL: URL, ignored: Set<String> = defaultIgnored) -> ProjectIndex {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let files = regularFiles(in: root, ignored: ignored).map { ProjectFile(relPath: $0.rel, url: $0.url) }
        return ProjectIndex(root: root, files: files)
    }
}
