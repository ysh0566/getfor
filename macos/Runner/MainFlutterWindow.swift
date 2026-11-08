import Cocoa
import FlutterMacOS
import LocalAuthentication
import Security

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    CredentialExchangeController.shared.attach(to: flutterViewController.engine.binaryMessenger)
    LanDiscoveryController.shared.attach(to: flutterViewController.engine.binaryMessenger)
    QuickUnlockController.shared.attach(to: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

final class QuickUnlockController {
  static let shared = QuickUnlockController()
  private let service: String
  private let account = "vault-key"

  init(service: String = "com.ysh0566.getfor.quick-unlock") {
    self.service = service
  }

  func attach(to messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(
      name: "com.ysh0566.getfor/quick_unlock",
      binaryMessenger: messenger
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "hasKey":
        result(self.readKey() != nil)
      case "saveKey":
        guard let data = call.arguments as? FlutterStandardTypedData, data.data.count == 32 else {
          result(FlutterError(code: "invalid_key", message: nil, details: nil))
          return
        }
        result(self.saveKey(data.data) ? nil : FlutterError(code: "keychain", message: nil, details: nil))
      case "loadKey":
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Getfor") { success, _ in
          DispatchQueue.main.async {
            result(success ? self.readKey().map(FlutterStandardTypedData.init(bytes:)) : nil)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func readKey() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
          let data = value as? Data,
          data.count == 32 else { return nil }
    return data
  }

  func saveKey(_ data: Data) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: data,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }

    // Updating first avoids the stale duplicate left by a delete-then-add sequence.
    return SecItemAdd(query.merging(attributes) { _, replacement in replacement } as CFDictionary, nil)
      == errSecSuccess
  }
}

final class LanDiscoveryController: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  static let shared = LanDiscoveryController()

  private var channel: FlutterMethodChannel?
  private var published: NetService?
  private var browser: NetServiceBrowser?
  private var localDeviceID = ""
  private var resolving: [NetService] = []

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.ysh0566.getfor/lan_discovery",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        guard let arguments = call.arguments as? [String: Any],
              let port = arguments["port"] as? Int,
              let deviceID = arguments["deviceId"] as? String,
              let advertise = arguments["advertise"] as? Bool else {
          result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
          return
        }
        self?.start(port: port, deviceID: deviceID, advertise: advertise)
        result(nil)
      case "stop":
        self?.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private func start(port: Int, deviceID: String, advertise: Bool) {
    stop()
    localDeviceID = deviceID
    if advertise {
      let service = NetService(
        domain: "local.",
        type: "_getfor._tcp.",
        name: "Getfor-\(deviceID.prefix(8))",
        port: Int32(port)
      )
      service.setTXTRecord(NetService.data(fromTXTRecord: [
        "v": Data("1".utf8),
        "id": Data(deviceID.utf8),
      ]))
      service.publish()
      published = service
    }

    let browser = NetServiceBrowser()
    browser.delegate = self
    browser.searchForServices(ofType: "_getfor._tcp.", inDomain: "local.")
    self.browser = browser
  }

  private func stop() {
    browser?.stop()
    published?.stop()
    browser = nil
    published = nil
    resolving.removeAll()
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    service.delegate = self
    resolving.append(service)
    service.resolve(withTimeout: 5)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    defer { resolving.removeAll { $0 === sender } }
    guard let data = sender.txtRecordData(),
          let idData = NetService.dictionary(fromTXTRecord: data)["id"],
          let id = String(data: idData, encoding: .utf8),
          id != localDeviceID,
          let host = sender.hostName else { return }
    channel?.invokeMethod("lanPeerFound", arguments: [
      "id": id,
      "host": host,
      "port": sender.port,
    ])
  }
}
