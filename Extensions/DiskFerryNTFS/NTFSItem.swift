// SPDX-License-Identifier: GPL-2.0-only
// Derived from NTFSKit 96ecccb1 (DNA MAKER COMPANY LIMITED and contributors).
// Modified for DiskFerry 2026-10-16; see UPSTREAM.md.

import FSKit

/// Swift String equality normalizes Unicode. NTFS compares stored UTF-16
/// code units, so canonically equivalent spellings must remain separate keys.
struct NTFSPathMap<Value>: ExpressibleByDictionaryLiteral {
    private var storage: [Data: (path: String, value: Value)] = [:]

    init(dictionaryLiteral elements: (String, Value)...) {
        for (path, value) in elements { self[path] = value }
    }

    subscript(_ path: String) -> Value? {
        get { storage[Data(path.utf8)]?.value }
        set { storage[Data(path.utf8)] = newValue.map { (path, $0) } }
    }

    subscript(_ path: String, default fallback: Value) -> Value { self[path] ?? fallback }
    var keys: [String] { storage.values.map(\.path) }
    var values: [Value] { storage.values.map(\.value) }
    mutating func removeAll() { storage.removeAll() }
    mutating func removeValue(forKey path: String) -> Value? { storage.removeValue(forKey: Data(path.utf8))?.value }
}

enum NTFSPath {
    static func equal(_ first: String, _ second: String) -> Bool { first.utf8.elementsEqual(second.utf8) }
    static func hasPrefix(_ path: String, _ prefix: String) -> Bool { path.utf8.starts(with: prefix.utf8) }
}

/// A file or directory in the NTFS volume, identified by its POSIX path.
/// The path is the only state needed to address the item through libntfs-3g.
final class NTFSItem: FSItem {
    // "/" for root; rewritten in-place on rename (FSKit tracks by object
    // identity — the same instance must follow the file to its new name).
    // Lock-guarded: I/O upcalls read the path concurrently with rename.
    private let pathLock = NSLock()
    private var _path: String
    var path: String {
        get { pathLock.lock(); defer { pathLock.unlock() }; return _path }
        set { pathLock.lock(); defer { pathLock.unlock() }; _path = newValue }
    }
    let kind: FSItem.ItemType
    let identifier: FSItem.Identifier
    // Guarded by the owning volume's namespace lock. Unlinked items retain
    // private backing storage until FSKit releases the last reference.
    var unlinked = false
    var reclaimed = false

    init(path: String, kind: FSItem.ItemType, identifier: FSItem.Identifier) {
        self._path = path
        self.kind = kind
        self.identifier = identifier
        super.init()
    }

    func childPath(_ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }
}
