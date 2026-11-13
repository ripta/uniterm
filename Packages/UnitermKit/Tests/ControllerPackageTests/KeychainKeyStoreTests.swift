import ControllerPackage
import Foundation
import Security
import XCTest

/// Signing keys in the login Keychain, where `uniterm controller keygen` makes them.
///
/// This is the one test that reaches the real Keychain. It files its item under a service no other
/// test or user shares, and deletes it however the test ends. Every other key test uses the
/// in-memory store.
final class KeychainKeyStoreTests: XCTestCase {
  /// Catches a store that replaces an existing key, reads back another key than it made, or
  /// answers a missing key with some other key. Losing a key must never sign as someone else.
  func testAKeyIsMadeOnceReadBackAndNeverSubstituted() throws {
    let store = KeychainKeyStore(service: "dev.uniterm.tests.signing-key.\(UUID().uuidString)")
    let name = "test key"

    defer { Self.delete(name, from: store) }

    let made = try store.create(named: name)

    XCTAssertEqual(try store.key(named: name).publicKey, made.publicKey)

    XCTAssertThrowsError(try store.create(named: name)) { error in
      XCTAssertTrue("\(error)".contains("never replaces a key"), "\(error)")
    }

    XCTAssertEqual(try store.key(named: name).publicKey, made.publicKey)

    Self.delete(name, from: store)

    XCTAssertThrowsError(try store.key(named: name)) { error in
      XCTAssertTrue("\(error)".contains("signs with no other key"), "\(error)")
    }
  }

  /// Removes the test's item directly, so the store exports no way to delete a key.
  private static func delete(_ name: String, from store: KeychainKeyStore) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: store.service,
      kSecAttrAccount as String: name,
    ]

    SecItemDelete(query as CFDictionary)
  }

  /// Catches the in-memory store, which the other tests use, drifting from the Keychain's rules.
  func testTheMemoryStoreKeepsTheSameRules() throws {
    let store = InMemoryKeyStore()
    let made = try store.create(named: "a")

    XCTAssertEqual(try store.key(named: "a").publicKey, made.publicKey)
    XCTAssertThrowsError(try store.create(named: "a"))
    XCTAssertThrowsError(try store.key(named: "b"))
    XCTAssertThrowsError(try store.create(named: " edge"))
  }
}
