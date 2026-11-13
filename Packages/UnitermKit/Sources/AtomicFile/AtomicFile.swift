import Darwin
import Foundation

/// Why a private file could not be written. The path names the file that failed, and the code is
/// the `errno` the system gave.
public struct AtomicFileError: Error, Equatable, Sendable, CustomStringConvertible {
  public let path: String
  public let code: Int32

  public init(path: String, code: Int32) {
    self.path = path
    self.code = code
  }

  public var description: String {
    "could not write \(path): \(String(cString: strerror(code)))"
  }
}

/// Writes a file so that a crash leaves either the old file or the new one, never a mix.
///
/// The bytes go to a temp file beside the target, readable by the user alone. The temp file is
/// flushed to the drive, then renamed over the target, and the folder is flushed so the rename
/// lasts. The layout file and the controller policy file both go through here.
public enum AtomicFile {
  /// The marker in a temp file's name. A folder's owner removes leftovers that carry it.
  public static let tempMarker = ".tmp-"

  /// Throws when the write fails, and leaves the old file in place.
  public static func write(_ data: Data, to url: URL) throws(AtomicFileError) {
    let temp = URL(fileURLWithPath: url.path + tempMarker + "\(getpid())")

    unlink(temp.path)

    let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)

    guard descriptor >= 0 else { throw AtomicFileError(path: temp.path, code: errno) }

    var failure: Int32 = 0

    if fchmod(descriptor, 0o600) != 0 { failure = errno }

    if failure == 0 {
      failure = data.withUnsafeBytes { buffer -> Int32 in
        var offset = 0

        while offset < buffer.count {
          let written = Darwin.write(
            descriptor, buffer.baseAddress! + offset, buffer.count - offset)

          if written < 0 {
            if errno == EINTR { continue }

            return errno
          }

          offset += written
        }

        return 0
      }
    }

    // fsync does not flush the drive's cache on macOS. F_FULLFSYNC does, and some file systems
    // refuse it, so fsync is the fallback.
    if failure == 0, fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
      failure = errno
    }

    close(descriptor)

    guard failure == 0 else {
      unlink(temp.path)
      throw AtomicFileError(path: temp.path, code: failure)
    }

    guard rename(temp.path, url.path) == 0 else {
      let code = errno
      unlink(temp.path)
      throw AtomicFileError(path: url.path, code: code)
    }

    syncDirectory(url.deletingLastPathComponent())
  }

  /// Makes a rename in `directory` durable. A failure here leaves the file in place, so it is not
  /// an error.
  public static func syncDirectory(_ directory: URL) {
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)

    guard descriptor >= 0 else { return }

    if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }

    close(descriptor)
  }
}
