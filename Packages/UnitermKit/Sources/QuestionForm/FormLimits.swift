import Foundation
import ScriptWire

/// The caps on a form spec and on the answers it collects.
///
/// The reply encoder cuts a string at `ScriptValue.maxStringBytes`, holds at most
/// `ScriptValue.maxRecordFields` fields in a record, and keys a record with short ASCII names. A
/// form that could not fit those limits would hand a script a cut answer, so the spec reader
/// refuses it instead. Every cap here that bounds an answer is also what a widget enforces while
/// the user types.
public enum FormLimits {
  /// The most bytes of JSON a spec may hold.
  public static let maxSpecBytes = 32 * 1024

  /// The most items, blocks and questions together. Every question is a field of the answers
  /// record, so this is also the record's field cap.
  public static let maxItems = ScriptValue.maxRecordFields

  /// The most buttons a form may hold.
  public static let maxButtons = 8

  /// The longest question or button `id`, in bytes. Ids become record keys.
  public static let maxIDBytes = ScriptValue.maxKeyBytes

  public static let maxTitleBytes = 200
  public static let maxQuestionTextBytes = 500
  public static let maxDetailBytes = 2000
  public static let maxPlaceholderBytes = 200
  public static let maxLabelBytes = 64

  /// The most choices one `choice` or `multi` question may offer.
  public static let maxChoices = 64

  /// The longest choice, in bytes.
  public static let maxChoiceBytes = 256

  /// The longest free-text entry of a `choice` question with `other`, in bytes.
  public static let maxOtherBytes = 256

  /// The longest answer of a `string` question, in bytes.
  public static let maxStringAnswerBytes = 1024

  /// The longest answer of a `text` question, in bytes. It is the encoder's string cut.
  public static let maxTextAnswerBytes = ScriptValue.maxStringBytes

  /// The longest file path, in bytes. It matches the system's path limit.
  public static let maxPathBytes = 1024

  /// The most paths a `file` question with `multiple` returns.
  public static let maxFilePaths = 16

  /// The most `types` a `file` question may name, and the longest one, in bytes.
  public static let maxFileTypes = 16
  public static let maxFileTypeBytes = 128

  /// The longest `pattern`, in bytes.
  public static let maxPatternBytes = 512

  /// The longest paragraph, code, or notice text, in bytes.
  public static let maxBlockTextBytes = 4096

  /// The most entries of a `list` block, and the longest entry, in bytes.
  public static let maxListEntries = 32
  public static let maxListEntryBytes = 512

  /// The most rows of a `table` block, and the longest key and value, in bytes.
  public static let maxTableRows = 32
  public static let maxTableKeyBytes = 128
  public static let maxTableValueBytes = 512

  /// The most digits a number literal may hold, and the largest exponent it may carry.
  public static let maxNumberDigits = 20
  public static let maxNumberExponent = 20

  /// The largest whole number an `integer` answer may hold. Every whole number up to it is exact
  /// in a double.
  public static let maxIntegerMagnitude: UInt64 = ScriptProtocol.maxID

  /// The longest input a `pattern` check accepts, in UTF-16 units. It is the longest answer.
  public static let maxPatternInputUnits = ScriptValue.maxStringBytes

  /// How long one `pattern` check may run, in seconds.
  public static let patternTimeLimit: TimeInterval = 0.5

  /// The largest result a form may produce, in bytes. It is one reply's payload.
  public static let maxResultBytes = ScriptProtocol.maxReplyPayload
}
