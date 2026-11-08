import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct GetforPasskey: Codable, Equatable {
  let credentialID: Data
  let relyingPartyID: String
  let userHandle: Data
  let userName: String
  let userDisplayName: String
  let privateKeyPKCS8: Data
  let backupEligible: Bool
  let backupState: Bool

  init(
    credentialID: Data,
    relyingPartyID: String,
    userHandle: Data,
    userName: String,
    userDisplayName: String,
    privateKeyPKCS8: Data,
    backupEligible: Bool = true,
    backupState: Bool = true
  ) throws {
    guard (16...1024).contains(credentialID.count),
          (1...64).contains(userHandle.count),
          !userName.isEmpty,
          userName.count <= 1024,
          Self.validRelyingPartyID(relyingPartyID),
          backupEligible
    else { throw PasskeyError.invalidCredential }
    _ = try P256.Signing.PrivateKey(derRepresentation: privateKeyPKCS8)
    self.credentialID = credentialID
    self.relyingPartyID = relyingPartyID
    self.userHandle = userHandle
    self.userName = userName
    self.userDisplayName = userDisplayName
    self.privateKeyPKCS8 = privateKeyPKCS8
    self.backupEligible = backupEligible
    self.backupState = backupState
  }

  var recordIdentifier: String {
    "passkey:\(credentialID.base64EncodedString())"
  }

  var identity: ASPasskeyCredentialIdentity {
    ASPasskeyCredentialIdentity(
      relyingPartyIdentifier: relyingPartyID,
      userName: userName,
      credentialID: credentialID,
      userHandle: userHandle,
      recordIdentifier: recordIdentifier
    )
  }

  private static func validRelyingPartyID(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 253, value == value.lowercased() else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
    return value.unicodeScalars.allSatisfy(allowed.contains)
      && !value.contains("..")
      && value.split(separator: ".").allSatisfy {
        !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.count <= 63
      }
  }
}

struct GetforAutoFillRecord: Codable {
  static let keychainService = "com.ysh0566.getfor.autofill"
  static let pendingPasskeyService = "com.ysh0566.getfor.pending-passkeys"
  static let keychainAccessGroup = "32RUDQ2549.com.ysh0566.getfor.shared"

  let id: String
  let title: String
  let website: String
  let userName: String
  let password: String
  var passkeys: [GetforPasskey]

  var serviceIdentifier: ASCredentialServiceIdentifier? {
    let value = website.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(string: value.contains("://") ? value : "https://\(value)")
    guard let host = url?.host, !host.isEmpty else { return nil }
    return ASCredentialServiceIdentifier(identifier: host, type: .domain)
  }

  static func load(id: String) throws -> Self {
    var query = baseQuery(service: keychainService)
    query[kSecAttrAccount as String] = id
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return try JSONDecoder().decode(Self.self, from: data)
  }

  static func loadAll() throws -> [Self] {
    var query = baseQuery(service: keychainService)
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let values = item as? [Data] else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return try values.map { try JSONDecoder().decode(Self.self, from: $0) }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  static func replace(_ records: [Self]) throws {
    let status = SecItemDelete(baseQuery(service: keychainService) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    for record in records { try save(record) }
  }

  static func addCreatedPasskey(_ passkey: GetforPasskey) throws {
    var records = try loadAll()
    if records.contains(where: {
      $0.passkeys.contains(where: { $0.credentialID == passkey.credentialID })
    }) {
      try savePending(passkey)
      return
    } else if let index = records.firstIndex(where: {
      $0.userName == passkey.userName &&
        ($0.serviceIdentifier?.identifier == passkey.relyingPartyID ||
          $0.passkeys.contains(where: { $0.relyingPartyID == passkey.relyingPartyID }))
    }) {
      records[index].passkeys.append(passkey)
      try save(records[index], update: true)
    } else {
      try save(Self(
        id: "pending:\(passkey.credentialID.base64EncodedString())",
        title: passkey.relyingPartyID,
        website: "https://\(passkey.relyingPartyID)",
        userName: passkey.userName,
        password: "",
        passkeys: [passkey]
      ))
    }
    try savePending(passkey)
  }

  static func loadPendingPasskeys() throws -> [GetforPasskey] {
    var query = baseQuery(service: pendingPasskeyService)
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let values = item as? [Data] else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return try values.map { try JSONDecoder().decode(GetforPasskey.self, from: $0) }
  }

  static func clearPendingPasskeys() throws {
    let status = SecItemDelete(baseQuery(service: pendingPasskeyService) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private static func savePending(_ passkey: GetforPasskey) throws {
    var query = baseQuery(service: pendingPasskeyService)
    query[kSecAttrAccount as String] = passkey.recordIdentifier
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecValueData as String] = try JSONEncoder().encode(passkey)
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private static func save(_ record: Self, update: Bool = false) throws {
    var query = baseQuery(service: keychainService)
    query[kSecAttrAccount as String] = record.id
    let data = try JSONEncoder().encode(record)
    if update {
      let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
      }
    } else {
      query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      query[kSecValueData as String] = data
      let status = SecItemAdd(query as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
      }
    }
  }

  private static func baseQuery(service: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccessGroup as String: keychainAccessGroup,
      // Shared access groups on macOS are served by the Data Protection Keychain.
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}

enum PasskeyCrypto {
  static func create(for request: ASPasskeyCredentialRequest) throws -> (GetforPasskey, ASPasskeyRegistrationCredential) {
    guard request.type == .passkeyRegistration,
          request.supportedAlgorithms.contains(.ES256),
          let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
    else { throw PasskeyError.unsupportedRequest }
    var credentialBytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, credentialBytes.count, &credentialBytes) == errSecSuccess
    else { throw PasskeyError.invalidCredential }
    let credentialID = Data(credentialBytes)
    let privateKey = P256.Signing.PrivateKey()
    let passkey = try GetforPasskey(
      credentialID: credentialID,
      relyingPartyID: identity.relyingPartyIdentifier.lowercased(),
      userHandle: identity.userHandle,
      userName: identity.userName,
      userDisplayName: identity.userName,
      privateKeyPKCS8: privateKey.derRepresentation
    )
    let authenticatorData = registrationAuthenticatorData(passkey: passkey, privateKey: privateKey)
    let credential = ASPasskeyRegistrationCredential(
      relyingParty: passkey.relyingPartyID,
      clientDataHash: request.clientDataHash,
      credentialID: credentialID,
      attestationObject: attestationObject(authenticatorData: authenticatorData)
    )
    return (passkey, credential)
  }

  static func assertion(for request: ASPasskeyCredentialRequest, passkey: GetforPasskey) throws -> ASPasskeyAssertionCredential {
    guard request.type == .passkeyAssertion,
          let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
          identity.credentialID == passkey.credentialID,
          identity.relyingPartyIdentifier == passkey.relyingPartyID
    else { throw PasskeyError.invalidCredential }
    let authenticatorData = assertionAuthenticatorData(passkey: passkey)
    let privateKey = try P256.Signing.PrivateKey(derRepresentation: passkey.privateKeyPKCS8)
    let signature = try privateKey.signature(for: authenticatorData + request.clientDataHash)
    return ASPasskeyAssertionCredential(
      userHandle: passkey.userHandle,
      relyingParty: passkey.relyingPartyID,
      signature: signature.derRepresentation,
      clientDataHash: request.clientDataHash,
      authenticatorData: authenticatorData,
      credentialID: passkey.credentialID
    )
  }

  private static func registrationAuthenticatorData(
    passkey: GetforPasskey,
    privateKey: P256.Signing.PrivateKey
  ) -> Data {
    var data = Data(SHA256.hash(data: Data(passkey.relyingPartyID.utf8)))
    data.append(0x5d) // UP | UV | BE | BS | AT
    data.append(Data(repeating: 0, count: 4 + 16)) // signCount=0 and no vendor AAGUID.
    data.append(UInt8(passkey.credentialID.count >> 8))
    data.append(UInt8(passkey.credentialID.count & 0xff))
    data.append(passkey.credentialID)
    let publicKey = privateKey.publicKey.x963Representation
    var writer = CBORWriter()
    writer.map(5)
    writer.integer(1); writer.integer(2)
    writer.integer(3); writer.integer(-7)
    writer.integer(-1); writer.integer(1)
    writer.integer(-2); writer.bytes(publicKey.subdata(in: 1..<33))
    writer.integer(-3); writer.bytes(publicKey.subdata(in: 33..<65))
    data.append(writer.data)
    return data
  }

  private static func assertionAuthenticatorData(passkey: GetforPasskey) -> Data {
    var data = Data(SHA256.hash(data: Data(passkey.relyingPartyID.utf8)))
    var flags: UInt8 = 0x01 | 0x04
    if passkey.backupEligible { flags |= 0x08 }
    if passkey.backupState { flags |= 0x10 }
    data.append(flags)
    data.append(Data(repeating: 0, count: 4))
    return data
  }

  private static func attestationObject(authenticatorData: Data) -> Data {
    var writer = CBORWriter()
    writer.map(3)
    writer.text("fmt"); writer.text("none")
    writer.text("attStmt"); writer.map(0)
    writer.text("authData"); writer.bytes(authenticatorData)
    return writer.data
  }
}

enum PasskeyError: Error {
  case unsupportedRequest
  case invalidCredential
}

private struct CBORWriter {
  private(set) var data = Data()

  mutating func map(_ count: Int) { major(5, count) }
  mutating func text(_ value: String) {
    let bytes = Data(value.utf8)
    major(3, bytes.count)
    data.append(bytes)
  }
  mutating func bytes(_ value: Data) {
    major(2, value.count)
    data.append(value)
  }
  mutating func integer(_ value: Int) {
    major(value >= 0 ? 0 : 1, value >= 0 ? value : -1 - value)
  }

  private mutating func major(_ type: Int, _ value: Int) {
    precondition(value >= 0 && value <= 0xffff)
    if value < 24 {
      data.append(UInt8((type << 5) | value))
    } else if value <= 0xff {
      data.append(UInt8((type << 5) | 24)); data.append(UInt8(value))
    } else {
      data.append(UInt8((type << 5) | 25))
      data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xff))
    }
  }
}
