import Cocoa
import FlutterMacOS
import Security
import XCTest
@testable import getfor

class RunnerTests: XCTestCase {

  func testQuickUnlockKeyCanBeReplaced() {
    let service = "com.ysh0566.getfor.quick-unlock.tests.\(UUID().uuidString)"
    defer {
      SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
      ] as CFDictionary)
    }
    let controller = QuickUnlockController(service: service)
    let replacement = Data(repeating: 2, count: 32)

    XCTAssertTrue(controller.saveKey(Data(repeating: 1, count: 32)))
    XCTAssertTrue(controller.saveKey(replacement))
    XCTAssertEqual(controller.readKey(), replacement)
  }

}
