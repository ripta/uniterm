import Foundation

/// The Unicode properties a `pattern` may name with `\p{...}`. ECMA-262 lists the names a
/// pattern may use. This table holds the ones whose translation is proven, by a test that
/// compiles each emitted form and compares membership with JavaScriptCore. A name outside it
/// refuses the pattern. Widening it later is additive.
enum PatternProperties {
  /// The ICU text for a name, or nil when the name is not in the table.
  static func icuName(forName name: String, value: String?) -> String? {
    guard let value else {
      if let category = generalCategory[name] { return category }

      return binary.contains(name) ? name : nil
    }

    switch name {
    case "General_Category", "gc": return generalCategory[value]
    case "Script", "sc": return scripts[value].map { "sc=\($0)" }
    case "Script_Extensions", "scx": return scripts[value].map { "scx=\($0)" }
    default: return nil
    }
  }

  /// Every ICU name the table emits, so a test can compile each one.
  static var emitted: [String] {
    Set(generalCategory.values).sorted() + binary.sorted()
      + Set(scripts.values).sorted().flatMap { ["sc=\($0)", "scx=\($0)"] }
  }

  private static let categoryPairs: [(short: String, long: [String])] = [
    ("LC", ["Cased_Letter"]), ("Pe", ["Close_Punctuation"]),
    ("Pc", ["Connector_Punctuation"]), ("Cc", ["Control", "cntrl"]),
    ("Sc", ["Currency_Symbol"]), ("Pd", ["Dash_Punctuation"]),
    ("Nd", ["Decimal_Number", "digit"]), ("Me", ["Enclosing_Mark"]),
    ("Pf", ["Final_Punctuation"]), ("Cf", ["Format"]), ("Pi", ["Initial_Punctuation"]),
    ("L", ["Letter"]), ("Nl", ["Letter_Number"]), ("Zl", ["Line_Separator"]),
    ("Ll", ["Lowercase_Letter"]), ("M", ["Mark", "Combining_Mark"]),
    ("Sm", ["Math_Symbol"]), ("Lm", ["Modifier_Letter"]), ("Sk", ["Modifier_Symbol"]),
    ("Mn", ["Nonspacing_Mark"]), ("N", ["Number"]), ("Ps", ["Open_Punctuation"]),
    ("C", ["Other"]), ("Lo", ["Other_Letter"]), ("No", ["Other_Number"]),
    ("Po", ["Other_Punctuation"]), ("So", ["Other_Symbol"]),
    ("Zp", ["Paragraph_Separator"]), ("Co", ["Private_Use"]), ("P", ["Punctuation", "punct"]),
    ("Z", ["Separator"]), ("Zs", ["Space_Separator"]), ("Mc", ["Spacing_Mark"]),
    ("Cs", ["Surrogate"]), ("S", ["Symbol"]), ("Lt", ["Titlecase_Letter"]),
    ("Cn", ["Unassigned"]), ("Lu", ["Uppercase_Letter"]),
  ]

  /// Short and long names of each general category, keyed to the short name.
  private static let generalCategory: [String: String] = {
    var table: [String: String] = [:]

    for pair in categoryPairs {
      table[pair.short] = pair.short

      for long in pair.long { table[long] = pair.short }
    }

    return table
  }()

  /// The binary properties ECMA-262 lists, minus those the test found ICU to spell differently.
  private static let binary: Set<String> = [
    "ASCII", "ASCII_Hex_Digit", "AHex", "Alphabetic", "Alpha", "Any", "Assigned", "Bidi_Control",
    "Bidi_C", "Bidi_Mirrored", "Bidi_M", "Case_Ignorable", "CI", "Cased",
    "Changes_When_Casefolded", "CWCF", "Changes_When_Casemapped", "CWCM",
    "Changes_When_Lowercased", "CWL", "Changes_When_NFKC_Casefolded", "CWKCF",
    "Changes_When_Titlecased", "CWT", "Changes_When_Uppercased", "CWU", "Dash",
    "Default_Ignorable_Code_Point", "DI", "Deprecated", "Dep", "Diacritic", "Dia", "Emoji",
    "Emoji_Component", "EComp", "Emoji_Modifier", "EMod", "Emoji_Modifier_Base", "EBase",
    "Emoji_Presentation", "EPres", "Extended_Pictographic", "ExtPict", "Extender", "Ext",
    "Grapheme_Base", "Gr_Base", "Grapheme_Extend", "Gr_Ext", "Hex_Digit", "Hex",
    "IDS_Binary_Operator", "IDSB", "IDS_Trinary_Operator", "IDST", "ID_Continue", "IDC",
    "ID_Start", "IDS", "Ideographic", "Ideo", "Join_Control", "Join_C",
    "Logical_Order_Exception", "LOE", "Lowercase", "Lower", "Math", "Noncharacter_Code_Point",
    "NChar", "Pattern_Syntax", "Pat_Syn", "Pattern_White_Space", "Pat_WS", "Quotation_Mark",
    "QMark", "Radical", "Regional_Indicator", "RI", "Sentence_Terminal", "STerm", "Soft_Dotted",
    "SD", "Terminal_Punctuation", "Term", "Unified_Ideograph", "UIdeo", "Uppercase", "Upper",
    "Variation_Selector", "VS", "White_Space", "space", "XID_Continue", "XIDC", "XID_Start",
    "XIDS",
  ]

  /// Common scripts, by long name and four-letter code, keyed to the long name.
  private static let scripts: [String: String] = {
    let pairs: [(long: String, short: String)] = [
      ("Latin", "Latn"), ("Greek", "Grek"), ("Cyrillic", "Cyrl"), ("Han", "Hani"),
      ("Hiragana", "Hira"), ("Katakana", "Kana"), ("Hangul", "Hang"), ("Arabic", "Arab"),
      ("Hebrew", "Hebr"), ("Thai", "Thai"), ("Devanagari", "Deva"), ("Common", "Zyyy"),
      ("Inherited", "Zinh"),
    ]

    var table: [String: String] = [:]

    for pair in pairs {
      table[pair.long] = pair.long
      table[pair.short] = pair.long
    }

    return table
  }()
}
