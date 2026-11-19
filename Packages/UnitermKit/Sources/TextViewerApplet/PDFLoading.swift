import Foundation
import PDFKit
import SourceAccess

/// A parsed PDF. `PDFDocument` is not `Sendable`, but this one is built once off the main thread and
/// handed over whole, and nothing else holds it.
struct LoadedPDF: @unchecked Sendable {
  let document: PDFDocument
}

enum PDFLoadError: Error, Equatable, Sendable {
  case read(FileReadError)

  /// The bytes are not a PDF that PDFKit opens.
  case notAPDF

  case locked
}

/// Loads a PDF from bytes read in full, so a file rewritten in place while it shows never feeds
/// CoreGraphics truncated bytes. The read opens the file, accepts only a regular file, and counts
/// the bytes against the cap.
enum PDFLoading {
  @concurrent
  static func load(path: String, limit: Int) async -> Result<LoadedPDF, PDFLoadError> {
    loadBlocking(path: path, limit: limit)
  }

  static func loadBlocking(path: String, limit: Int) -> Result<LoadedPDF, PDFLoadError> {
    switch RegularFile.readAll(path: path, limit: limit) {
    case .failure(let error):
      return .failure(.read(error))

    case .success(let data):
      return document(from: data)
    }
  }

  /// The document for `data`. The fuzzers call this to run PDF loading as shipped.
  static func document(from data: Data) -> Result<LoadedPDF, PDFLoadError> {
    guard let document = PDFDocument(data: data) else { return .failure(.notAPDF) }

    if document.isLocked { return .failure(.locked) }

    lockFormFields(in: document)

    return .success(LoadedPDF(document: document))
  }

  /// The viewer shows documents and does not edit them, so every form widget refuses input. Push
  /// buttons stay unlocked. They take no typed text, and their go-to actions work today. Locking
  /// everything else by default also covers signature widgets and types PDFKit adds later.
  private static func lockFormFields(in document: PDFDocument) {
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }

      for annotation in page.annotations where annotation.isWidget {
        if annotation.widgetFieldType == .button, annotation.widgetControlType == .pushButtonControl
        {
          continue
        }

        annotation.isReadOnly = true
      }
    }
  }
}

extension PDFAnnotation {
  /// PDFKit reports the subtype of a widget as `Widget`, while `PDFAnnotationSubtype.widget` is
  /// spelled with the leading slash of a PDF name.
  fileprivate var isWidget: Bool {
    type.map { "/" + $0 } == PDFAnnotationSubtype.widget.rawValue
  }
}
