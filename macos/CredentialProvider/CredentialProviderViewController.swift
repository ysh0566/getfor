import AppKit
import AuthenticationServices
import LocalAuthentication
import Security

final class CredentialProviderViewController: ASCredentialProviderViewController {
  private var records: [GetforAutoFillRecord] = []
  private var passkeyRequestParameters: ASPasskeyCredentialRequestParameters?

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
  }

  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    do {
      records = try GetforAutoFillRecord.loadAll()
      showCredentialList()
    } catch {
      cancel(.failed)
    }
  }

  override func prepareCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier],
    requestParameters: ASPasskeyCredentialRequestParameters
  ) {
    do {
      passkeyRequestParameters = requestParameters
      records = try GetforAutoFillRecord.loadAll()
      showCredentialList()
    } catch {
      cancel(.failed)
    }
  }

  override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
    if credentialRequest is ASPasskeyCredentialRequest {
      cancel(.userInteractionRequired)
    } else {
      complete(credentialRequest)
    }
  }

  override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
    complete(credentialRequest)
  }

  override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
    guard let request = registrationRequest as? ASPasskeyCredentialRequest else {
      cancel(.failed)
      return
    }
    let excluded = Set(request.excludedCredentials?.map(\.credentialID) ?? [])
    let hasExcluded = (try? GetforAutoFillRecord.loadAll())?
      .flatMap(\.passkeys)
      .contains(where: { excluded.contains($0.credentialID) }) == true
    if hasExcluded {
      cancel(.matchedExcludedCredential)
      return
    }
    authenticate(reason: "创建通行密钥") { [weak self] success in
      guard let self, success else {
        self?.cancel(.userCanceled)
        return
      }
      do {
        let (passkey, credential) = try PasskeyCrypto.create(for: request)
        try GetforAutoFillRecord.addCreatedPasskey(passkey)
        ASCredentialIdentityStore.shared.saveCredentialIdentities([passkey.identity]) { saved, _ in
          guard saved else {
            self.cancel(.failed)
            return
          }
          self.extensionContext.completeRegistrationRequest(using: credential, completionHandler: nil)
        }
      } catch {
        self.cancel(.failed)
      }
    }
  }

  private func complete(_ request: ASCredentialRequest) {
    if let passkeyRequest = request as? ASPasskeyCredentialRequest {
      guard let identity = passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity,
            let passkey = records.flatMap(\.passkeys).first(where: {
              $0.credentialID == identity.credentialID &&
                $0.relyingPartyID == identity.relyingPartyIdentifier
            })
      else {
        cancel(.credentialIdentityNotFound)
        return
      }
      authenticate(reason: "使用 \(passkey.relyingPartyID) 通行密钥") { [weak self] success in
        guard let self, success else {
          self?.cancel(.userCanceled)
          return
        }
        do {
          let credential = try PasskeyCrypto.assertion(for: passkeyRequest, passkey: passkey)
          self.extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
        } catch {
          self.cancel(.failed)
        }
      }
      return
    }
    guard let passwordRequest = request as? ASPasswordCredentialRequest,
          let id = passwordRequest.credentialIdentity.recordIdentifier,
          let record = try? GetforAutoFillRecord.load(id: id)
    else {
      cancel(.credentialIdentityNotFound)
      return
    }
    extensionContext.completeRequest(
      withSelectedCredential: ASPasswordCredential(
        user: record.userName,
        password: record.password
      ),
      completionHandler: nil
    )
  }

  private func showCredentialList() {
    view.subviews.forEach { $0.removeFromSuperview() }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "选择 Getfor 凭据")
    title.font = .boldSystemFont(ofSize: 16)
    stack.addArrangedSubview(title)

    if records.isEmpty {
      stack.addArrangedSubview(NSTextField(labelWithString: "没有可用的登录密码"))
    } else {
      for record in records {
        if !record.password.isEmpty && passkeyRequestParameters == nil {
          addButton(
            to: stack,
            title: "\(record.title) — \(record.userName)",
            identifier: "password:\(record.id)"
          )
        }
        for passkey in record.passkeys where passkeyRequestParameters.map({ parameters in
          parameters.relyingPartyIdentifier == passkey.relyingPartyID &&
            (parameters.allowedCredentials.isEmpty ||
              parameters.allowedCredentials.contains(passkey.credentialID))
        }) ?? true {
          addButton(
            to: stack,
            title: "通行密钥 · \(passkey.userDisplayName.isEmpty ? passkey.userName : passkey.userDisplayName)",
            identifier: passkey.recordIdentifier
          )
        }
      }
    }

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.documentView = stack
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
    ])
  }

  @objc private func selectCredential(_ sender: NSButton) {
    guard let selection = sender.identifier?.rawValue else {
      cancel(.credentialIdentityNotFound)
      return
    }
    if selection.hasPrefix("passkey:"),
       let parameters = passkeyRequestParameters,
       let passkey = records.flatMap(\.passkeys).first(where: { $0.recordIdentifier == selection }) {
      let request = ASPasskeyCredentialRequest(
        credentialIdentity: passkey.identity,
        clientDataHash: parameters.clientDataHash,
        userVerificationPreference: parameters.userVerificationPreference,
        supportedAlgorithms: [ASCOSEAlgorithmIdentifier]()
      )
      complete(request)
      return
    }
    let id = selection.replacingOccurrences(of: "password:", with: "")
    guard
          let record = records.first(where: { $0.id == id })
    else {
      cancel(.credentialIdentityNotFound)
      return
    }
    extensionContext.completeRequest(
      withSelectedCredential: ASPasswordCredential(
        user: record.userName,
        password: record.password
      ),
      completionHandler: nil
    )
  }

  private func addButton(to stack: NSStackView, title: String, identifier: String) {
    let button = NSButton(title: title, target: self, action: #selector(selectCredential(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.alignment = .left
    stack.addArrangedSubview(button)
    button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
  }

  private func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      completion(false)
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
      DispatchQueue.main.async { completion(success) }
    }
  }

  private func cancel(_ error: ASExtensionError.Code) {
    extensionContext.cancelRequest(
      withError: NSError(domain: ASExtensionErrorDomain, code: error.rawValue)
    )
  }
}
