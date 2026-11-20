import Foundation
import SourceAccess

/// Reads a Markdown file in full, off the main thread, and finds the folder its images resolve
/// against. The text is never parsed here. WebKit's content process parses it.
///
/// A file a program sent has no folder, the same as Markdown a program sent inline. The program
/// chose the bytes and the name, never the place, so its images cannot climb out of the folder
/// uniterm keeps its sent content in.
enum MarkdownLoading {
  @concurrent
  static func load(
    path: String, limit: Int, sentByProgram: Bool = false
  ) async -> Result<MarkdownDocument, FileReadError> {
    loadBlocking(path: path, limit: limit, sentByProgram: sentByProgram)
  }

  static func loadBlocking(
    path: String, limit: Int, sentByProgram: Bool = false
  ) -> Result<MarkdownDocument, FileReadError> {
    switch RegularFile.readAll(path: path, limit: limit) {
    case .failure(let error):
      return .failure(error)

    case .success(let data):
      if sentByProgram {
        return .success(MarkdownDocument(text: data, folder: nil, isInline: true))
      }

      let folder = try? ConfinedFile.Folder.at(path: (path as NSString).deletingLastPathComponent)
        .get()

      return .success(MarkdownDocument(text: data, folder: folder))
    }
  }
}
