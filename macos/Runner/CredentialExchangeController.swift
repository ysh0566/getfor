import AppKit
@preconcurrency import AuthenticationServices
import FlutterMacOS
import Security

@MainActor
final class CredentialExchangeController {
  static let shared = CredentialExchangeController()

  private var channel: FlutterMethodChannel?
  private var pendingPayload: [String: Any]?
  private var pendingError: String?

  private init() {}

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.ysh0566.getfor/credential_exchange",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "takePendingImport":
        self.takePendingImport(result: result)
      case "takePendingPasskeys":
        self.takePendingPasskeys(result: result)
      case "clearPendingPasskeys":
        self.clearPendingPasskeys(result: result)
      case "requestEnableAutoFill":
        ASSettingsHelper.requestToTurnOnCredentialProviderExtension { enabled in
          result(enabled)
        }
      case "exportItem":
        self.exportItem(call.arguments, result: result)
      case "syncAutoFill":
        self.syncAutoFill(call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    notifyFlutterIfNeeded()
  }

  private func takePendingImport(result: FlutterResult) {
    if let error = pendingError {
      pendingError = nil
      result(FlutterError(code: "credential_exchange", message: error, details: nil))
      return
    }
    result(pendingPayload)
    pendingPayload = nil
  }

  private func takePendingPasskeys(result: FlutterResult) {
    do {
      result(try GetforAutoFillRecord.loadPendingPasskeys().map(Self.passkeyPayload))
    } catch {
      result(FlutterError(code: "pending_passkeys", message: error.localizedDescription, details: nil))
    }
  }

  private func clearPendingPasskeys(result: FlutterResult) {
    do {
      try GetforAutoFillRecord.clearPendingPasskeys()
      result(nil)
    } catch {
      result(FlutterError(code: "pending_passkeys", message: error.localizedDescription, details: nil))
    }
  }

  private func exportItem(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let values = arguments as? [String: Any],
          let title = values["title"] as? String,
          let website = values["website"] as? String,
          let userName = values["username"] as? String,
          let password = values["password"] as? String,
          let totpPeriod = values["totpPeriod"] as? Int,
          let totpDigits = values["totpDigits"] as? Int,
          let algorithmName = values["totpAlgorithm"] as? String,
          let totpAlgorithm = ASImportableCredential.TOTP.Algorithm(rawValue: algorithmName),
          !title.isEmpty,
          let anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    else {
      result(FlutterError(code: "invalid_export", message: "缺少可导出的项目数据", details: nil))
      return
    }
    let totpSecret = (values["totpSecret"] as? FlutterStandardTypedData)?.data ?? Data()
    let passkeys = ((values["passkeys"] as? [[String: Any]]) ?? []).compactMap {
      try? GetforPasskey($0)
    }
    guard !password.isEmpty || !totpSecret.isEmpty || !passkeys.isEmpty else {
      result(FlutterError(code: "invalid_export", message: "项目中没有可导出的凭据", details: nil))
      return
    }

    Task {
      do {
        let manager = ASCredentialExportManager(presentationAnchor: anchor)
        let options = try await manager.requestExport()
        let data = Self.makeExportData(
          title: title,
          website: website,
          userName: userName,
          password: password,
          totpSecret: totpSecret,
          totpPeriod: UInt16(totpPeriod),
          totpDigits: UInt16(totpDigits),
          totpAlgorithm: totpAlgorithm,
          passkeys: passkeys,
          formatVersion: options.formatVersion
        )
        try await manager.exportCredentials(data)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "credential_export",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func syncAutoFill(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let values = arguments as? [[String: Any]] else {
      result(FlutterError(code: "invalid_autofill", message: "自动填充数据格式错误", details: nil))
      return
    }

    do {
      let records = try values.map(GetforAutoFillRecord.init)
      try GetforAutoFillRecord.replace(records)
      var identities: [any ASCredentialIdentity] = records.flatMap(\.passkeys).map(\.identity)
      identities += records.compactMap { record -> ASPasswordCredentialIdentity? in
        guard !record.password.isEmpty, let service = record.serviceIdentifier else { return nil }
        return ASPasswordCredentialIdentity(serviceIdentifier: service, user: record.userName, recordIdentifier: record.id)
      }
      ASCredentialIdentityStore.shared.getState { state in
        guard state.isEnabled else {
          result(false)
          return
        }
        ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { success, error in
          if success {
            result(true)
          } else {
            result(
              FlutterError(
                code: "autofill_identity_store",
                message: error?.localizedDescription ?? "无法更新自动填充索引",
                details: nil
              )
            )
          }
        }
      }
    } catch {
      result(
        FlutterError(code: "autofill_keychain", message: error.localizedDescription, details: nil)
      )
    }
  }

  func handle(_ activity: NSUserActivity) -> Bool {
    guard activity.activityType == ASCredentialExchangeActivity,
          let token = importToken(from: activity.userInfo?[ASCredentialImportToken])
    else {
      return false
    }

    Task {
      do {
        let data = try await ASCredentialImportManager().importCredentials(token: token)
        pendingPayload = Self.makePayload(from: data)
      } catch {
        pendingError = error.localizedDescription
      }
      notifyFlutterIfNeeded()
    }
    return true
  }

  private func notifyFlutterIfNeeded() {
    guard pendingPayload != nil || pendingError != nil else { return }
    channel?.invokeMethod("credentialExchangeReady", arguments: nil)
  }

  private func importToken(from value: Any?) -> UUID? {
    // NSUserActivity may bridge UUID through Foundation differently across process boundaries.
    switch value {
    case let token as UUID:
      return token
    case let token as NSUUID:
      return token as UUID
    case let token as String:
      return UUID(uuidString: token)
    default:
      return nil
    }
  }

  private static func makePayload(from data: ASExportedCredentialData) -> [String: Any] {
    var records: [[String: Any]] = []
    var skipped = 0

    for account in data.accounts {
      for item in account.items {
        var password = ""
        var userName = account.userName
        var totpSecret = Data()
        var totpPeriod = 30
        var totpDigits = 6
        var totpAlgorithm = "sha1"
        var passkeys: [GetforPasskey] = []
        // ponytail: one vault item holds one login and one TOTP; keep the first of each.
        for credential in item.credentials {
          switch credential {
          case let .basicAuthentication(login) where password.isEmpty:
            password = login.password?.value ?? ""
            userName = login.userName?.value ?? userName
          case let .totp(totp) where totpSecret.isEmpty:
            totpSecret = totp.secret
            totpPeriod = Int(totp.period)
            totpDigits = Int(totp.digits)
            totpAlgorithm = totp.algorithm.rawValue
            userName = userName.isEmpty ? (totp.userName ?? "") : userName
          case let .passkey(passkey):
            if let value = try? GetforPasskey(
              credentialID: passkey.credentialID,
              relyingPartyID: passkey.relyingPartyIdentifier.lowercased(),
              userHandle: passkey.userHandle,
              userName: passkey.userName,
              userDisplayName: passkey.userDisplayName,
              privateKeyPKCS8: passkey.key
            ), !passkeys.contains(where: { $0.credentialID == value.credentialID }) {
              passkeys.append(value)
              userName = userName.isEmpty ? passkey.userName : userName
            }
          default:
            continue
          }
        }
        if password.isEmpty && totpSecret.isEmpty && passkeys.isEmpty {
          skipped += 1
          continue
        }
        let website = item.scope?.urls.first?.absoluteString
          ?? passkeys.first.map { "https://\($0.relyingPartyID)" }
          ?? ""
        records.append([
          "title": item.title.isEmpty ? (website.isEmpty ? "未命名项目" : website) : item.title,
          "website": website,
          "username": userName,
          "password": password,
          "totpSecret": FlutterStandardTypedData(bytes: totpSecret),
          "totpPeriod": totpPeriod,
          "totpDigits": totpDigits,
          "totpAlgorithm": totpAlgorithm,
          "passkeys": passkeys.map(Self.passkeyPayload),
        ])
      }
    }

    return [
      "source": data.exporterDisplayName,
      "records": records,
      "skipped": skipped,
    ]
  }

  private static func makeExportData(
    title: String,
    website: String,
    userName: String,
    password: String,
    totpSecret: Data,
    totpPeriod: UInt16,
    totpDigits: UInt16,
    totpAlgorithm: ASImportableCredential.TOTP.Algorithm,
    passkeys: [GetforPasskey],
    formatVersion: ASExportedCredentialData.FormatVersion
  ) -> ASExportedCredentialData {
    var credentials: [ASImportableCredential] = []
    if !password.isEmpty {
      let userNameField = ASImportableEditableField(
        id: nil,
        fieldType: .string,
        value: userName,
        label: "Username"
      )
      let passwordField = ASImportableEditableField(
        id: nil,
        fieldType: .concealedString,
        value: password,
        label: "Password"
      )
      credentials.append(.basicAuthentication(.init(
        userName: userNameField,
        password: passwordField
      )))
    }
    if !totpSecret.isEmpty {
      credentials.append(.totp(.init(
        secret: totpSecret,
        period: totpPeriod,
        digits: totpDigits,
        userName: userName.isEmpty ? nil : userName,
        algorithm: totpAlgorithm,
        issuer: title
      )))
    }
    for passkey in passkeys {
      credentials.append(.passkey(.init(
        credentialID: passkey.credentialID,
        relyingPartyIdentifier: passkey.relyingPartyID,
        userName: passkey.userName,
        userDisplayName: passkey.userDisplayName,
        userHandle: passkey.userHandle,
        key: passkey.privateKeyPKCS8
      )))
    }
    let scopeURL = normalizedURL(website)
    let now = Date()
    let item = ASImportableItem(
      id: Data(UUID().uuidString.utf8),
      created: now,
      lastModified: now,
      title: title,
      scope: scopeURL.map { ASImportableCredentialScope(urls: [$0]) },
      credentials: credentials
    )
    let account = ASImportableAccount(
      id: Data(UUID().uuidString.utf8),
      userName: userName,
      email: "",
      collections: [],
      items: [item]
    )
    return ASExportedCredentialData(
      accounts: [account],
      formatVersion: formatVersion,
      exporterRelyingPartyIdentifier: Bundle.main.bundleIdentifier ?? "com.ysh0566.getfor",
      exporterDisplayName: "Getfor",
      timestamp: now
    )
  }

  nonisolated fileprivate static func normalizedURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil {
      return url
    }
    return URL(string: "https://\(trimmed)")
  }

  private static func passkeyPayload(_ passkey: GetforPasskey) -> [String: Any] {
    [
      "credentialId": FlutterStandardTypedData(bytes: passkey.credentialID),
      "relyingPartyId": passkey.relyingPartyID,
      "userHandle": FlutterStandardTypedData(bytes: passkey.userHandle),
      "userName": passkey.userName,
      "userDisplayName": passkey.userDisplayName,
      "privateKeyPkcs8": FlutterStandardTypedData(bytes: passkey.privateKeyPKCS8),
      "backupEligible": passkey.backupEligible,
      "backupState": passkey.backupState,
    ]
  }
}

private extension GetforAutoFillRecord {
  init(_ values: [String: Any]) throws {
    guard let id = values["id"] as? String,
          let title = values["title"] as? String,
          let website = values["website"] as? String,
          let userName = values["username"] as? String,
          let password = values["password"] as? String
    else {
      throw NSError(domain: "GetforAutoFill", code: 1)
    }
    let passkeys = try ((values["passkeys"] as? [[String: Any]]) ?? []).map(GetforPasskey.init)
    self.init(id: id, title: title, website: website, userName: userName, password: password, passkeys: passkeys)
  }
}

private extension GetforPasskey {
  init(_ values: [String: Any]) throws {
    guard let credentialID = (values["credentialId"] as? FlutterStandardTypedData)?.data,
          let relyingPartyID = values["relyingPartyId"] as? String,
          let userHandle = (values["userHandle"] as? FlutterStandardTypedData)?.data,
          let userName = values["userName"] as? String,
          let userDisplayName = values["userDisplayName"] as? String,
          let privateKeyPKCS8 = (values["privateKeyPkcs8"] as? FlutterStandardTypedData)?.data
    else { throw PasskeyError.invalidCredential }
    try self.init(
      credentialID: credentialID,
      relyingPartyID: relyingPartyID,
      userHandle: userHandle,
      userName: userName,
      userDisplayName: userDisplayName,
      privateKeyPKCS8: privateKeyPKCS8,
      backupEligible: values["backupEligible"] as? Bool ?? true,
      backupState: values["backupState"] as? Bool ?? true
    )
  }
}
