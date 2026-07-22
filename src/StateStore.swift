import Darwin
import Foundation

public enum StateError: Error, CustomStringConvertible {
    case unsafeDirectory(String)
    case io(String)
    case lockTimeout

    public var description: String {
        switch self {
        case .unsafeDirectory(let path): return "unsafe state directory: \(path)"
        case .io(let operation): return "state I/O failed: \(operation)"
        case .lockTimeout: return "could not acquire safety lock"
        }
    }
}

public final class StateStore {
    public let directory: String
    public let lockPath: String
    private let trustedUID: uid_t
    private let trustedGID: gid_t

    public init(directory: String, lockPath: String, production: Bool) {
        self.directory = directory
        self.lockPath = lockPath
        self.trustedUID = production ? 0 : geteuid()
        self.trustedGID = production ? 0 : getegid()
    }

    public var enabled: Bool { regularFileExists(path("enabled")) }

    public func contains(_ name: String) -> Bool { regularFileExists(path(name)) }

    public func ensureDirectory() throws {
        var info = stat()
        if lstat(directory, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == trustedUID,
                  info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw StateError.unsafeDirectory(directory)
            }
            return
        }
        guard errno == ENOENT, mkdir(directory, 0o755) == 0 else {
            throw StateError.io("mkdir")
        }
        guard chown(directory, trustedUID, trustedGID) == 0, chmod(directory, 0o755) == 0 else {
            throw StateError.io("secure directory")
        }
    }

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StateError.io("open lock") }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == trustedUID,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              fchmod(descriptor, 0o600) == 0 else {
            throw StateError.io("validate lock")
        }

        let deadline = Date().addingTimeInterval(5)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw StateError.lockTimeout }
            usleep(100_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    public func write(_ name: String, value: String) throws {
        try ensureDirectory()
        let temporary = path(".\(name).\(getpid()).\(UUID().uuidString).tmp")
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw StateError.io("create \(name)") }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(temporary) }
        }

        let bytes = Array((value + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let wrote = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            if wrote > 0 {
                offset += wrote
            } else if wrote < 0 && errno == EINTR {
                continue
            } else {
                throw StateError.io("write \(name)")
            }
        }
        guard fchown(descriptor, trustedUID, trustedGID) == 0,
              fchmod(descriptor, 0o644) == 0,
              fsync(descriptor) == 0,
              rename(temporary, path(name)) == 0 else {
            throw StateError.io("commit \(name)")
        }
        shouldRemove = false
    }

    public func read(_ name: String) -> String? {
        let file = path(name)
        guard regularFileExists(file),
              let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe),
              data.count <= 4096 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func remove(_ name: String) throws {
        let file = path(name)
        if unlink(file) != 0, errno != ENOENT { throw StateError.io("remove \(name)") }
    }

    private func path(_ name: String) -> String { directory + "/" + name }

    private func regularFileExists(_ file: String) -> Bool {
        var info = stat()
        return lstat(file, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == trustedUID
    }
}
