# macOS 密码数据接入调研

调研日期：2026-08-07

## 结论

第三方密码管理器不应把“直接读取 Apple Passwords / iCloud Keychain 或 Chrome Password Manager 整库”作为产品能力。Apple 没有向普通第三方应用开放枚举其密码库的 API；Chrome 也没有向普通扩展开放读取已保存密码的 API。

MVP 应采用两种用户主动迁移方式：

1. macOS 26 / iOS 26 及以上优先使用 Apple Credential Exchange。
2. 旧系统和 Chrome 使用用户手动导出的 CSV。

AutoFill Credential Provider 和浏览器扩展用于日常填充本产品已有的凭据，不是从其他密码管理器导入数据的接口。

## 能力边界

| 目标 | 能否通过公开 API 批量读取 | 官方可行路径 |
| --- | --- | --- |
| Apple Passwords / iCloud Keychain | 否 | Credential Exchange；旧系统由用户导出 CSV |
| Chrome Password Manager | 否 | 用户从 Google Password Manager 导出 CSV |
| 在 macOS/iOS 的系统 AutoFill 中提供本产品密码 | 可以 | AuthenticationServices Credential Provider Extension |
| 在 Chrome 中填充本产品密码 | 可以 | Chrome 扩展；需要桌面应用能力时通过 Native Messaging 通信 |

### Apple Passwords / iCloud Keychain

Keychain 条目按 access group 隔离。应用只能访问其所属 access group 内的条目；没有显式共享组时，条目通常只对创建它的应用可见。因此普通应用不能借助 `SecItemCopyMatching` 获得 Apple Passwords 整库。[Apple `kSecAttrAccessGroup`](https://developer.apple.com/documentation/security/ksecattraccessgroup)

Credential Provider Extension 的方向是“本产品向系统提供凭据”。Apple 明确说明 identity store 由扩展填充，而且不同应用的 store 相互隔离；其中只保存账号、网站等 identity，不保存密码。用户选择填充后，系统才向该扩展取得密码。[Apple Credential Provider 安全说明](https://support.apple.com/guide/security/credential-provider-extensions-sec6319ac7b9/web)、[Apple `ASCredentialIdentityStore.shared`](https://developer.apple.com/documentation/authenticationservices/ascredentialidentitystore/shared)

关联域的 Shared Web Credentials 也不是整库读取接口。它只允许 App 在网站、App 和用户均授权时访问相应网站的凭据，适合自家 App 与网站登录；相关 API 已被 Apple 标记为 deprecated。[Apple Shared Web Credentials](https://developer.apple.com/documentation/security/shared-web-credentials)

### Chrome Password Manager

普通 Chrome 扩展没有读取 Chrome 已保存密码的公开 API。Chromium 虽然内部存在 `chrome.passwordsPrivate`，但权限配置将它限制为 `location: component`；Chromium 文档说明 component extension 是 Chrome 自身的组成部分，不是 Web Store 中的普通扩展。[Chromium `passwordsPrivate` 权限配置](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_permission_features.json)、[Chromium Component Extensions](https://chromium.googlesource.com/chromium/src/+/main/extensions/docs/component_extensions.md)、[Chromium Extension Features 说明](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_features.md)

公开的 `chrome.browsingData` 也不能读取密码；它原本只提供删除能力，而且 Chrome 144 起连扩展删除密码也已移除。[Chrome `browsingData` API](https://developer.chrome.com/docs/extensions/reference/api/browsingData)

Native Messaging 只让扩展与已注册的本地应用通过标准输入输出交换消息。它适合“本产品 Chrome 扩展 ↔ 本产品桌面应用”，不会赋予扩展读取 Chrome Password Manager 或 Apple Passwords 的权限。[Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

## 为什么 Apple 的 iCloud Passwords Chrome 扩展能读取

Apple 官方文档把它描述为 Passwords / iCloud Passwords 自身的浏览器集成：用户从 Passwords 应用获取扩展，扩展可在第三方浏览器中使用 iCloud Passwords 和 AutoFill。[Apple：在 Mac 上获取 Passwords 浏览器扩展](https://support.apple.com/en-lamr/guide/passwords/mchlf7ac261e/mac)

公开资料没有披露该扩展的内部通信协议。可以确认的是，它属于 Apple 自己的 Passwords 产品链路；不能由此推导普通 Chrome 扩展拥有读取 Apple 密码库的权限。若实现类似体验，应让本产品的浏览器扩展只访问本产品桌面应用或本产品保险库。

## 官方迁移方式

### 1. Apple Credential Exchange（优先）

macOS 26 / iOS 26 起，参与的密码管理器可通过 `ASCredentialExportManager` 和 `ASCredentialImportManager` 直接交换密码、Passkey、验证码等凭据。流程由用户发起，系统负责确认参与应用并进行本地认证，且不会把凭据写入文件系统。接收方需要 Credential Provider Extension，并声明 `SupportsCredentialExchange` 及支持的格式版本。[Apple `ASCredentialExportManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)、[Apple `ASCredentialImportManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager)、[WWDC25：What’s new in passkeys，19:12](https://developer.apple.com/videos/play/wwdc2025/279/?time=1152)

这应是 Apple 平台的正式迁移方案，但不能覆盖旧版系统。

### 2. CSV（MVP 兼容路径）

Apple Passwords 支持由用户导出单个或全部网站/App 密码到 CSV。文件是未加密明文，导入后必须删除；Wi-Fi 密码、部分群组共享密码和 Sign in with Apple 账户不能导出。[Apple：从 Mac 导出密码](https://support.apple.com/en-au/guide/passwords/mchl35b12625/mac)

Google Password Manager 同样提供用户操作的 CSV 导出；Google 的官方导入格式使用 `url`、`username`、`password` 列，并提醒导入后删除明文文件。[Google：使用 Chrome 导入或导出密码](https://support.google.com/chrome/answer/13068232?hl=en)

MVP 导入器只需支持 Apple 和 Chrome 的官方 CSV：用户选文件、本地解析、展示导入预览、写入加密保险库、提示并协助用户删除原文件。不要扫描浏览器 Profile、读取私有 SQLite 数据库或实现浏览器密钥解密；这些都不是稳定的官方集成面。

## MVP 决策

- Apple 端实现 AuthenticationServices Credential Provider Extension，用于提供本产品密码。
- macOS 26 / iOS 26 增加 Credential Exchange 导入；旧系统保留 CSV 导入。
- Chrome 扩展只负责识别登录表单、查询本产品保险库并填充；需要连接桌面应用时使用 Native Messaging。
- Chrome Password Manager 的迁移只接收用户主动导出的 CSV。
- 不实现 Apple/Chrome 私有数据库读取、后台静默迁移或非公开 API。

## Credential Exchange 的批量能力与边界

**可以批量导入、导出，且可以承载一次“全选后迁移”的整库数据；但它不是读取 Apple Passwords 或系统 Keychain 整库的 API。** `ASExportedCredentialData` 本身包装多个 `ASImportableAccount`，每个 account 又包含多个 collection 和 item，因此本产品可以把自己保险库中用户选中的全部兼容条目一次交给系统。反方向导入时，本产品只能接收来源密码管理器在用户发起的这次导出中提供的数据，不能指定 Apple Passwords 为来源、主动枚举其保险库，或绕过来源应用读取未选择的数据。[Apple `ASExportedCredentialData`](https://developer.apple.com/documentation/authenticationservices/asexportedcredentialdata)、[Apple `ASImportableAccount`](https://developer.apple.com/documentation/authenticationservices/asimportableaccount)、[Apple `ASImportableItem`](https://developer.apple.com/documentation/authenticationservices/asimportableitem)

### 可迁移的数据类型

Credential Exchange Format v1 的 `ASImportableCredential` 有明确类型，不限于登录密码：

- 登录密码、Passkey、TOTP 验证码和备注；Passkey 数据包含私钥，Apple 要求其 `key` 为 PKCS#8 字节串。[Apple Password](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/basicauthentication)、[Apple Passkey](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/passkey)、[Apple TOTP](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/totp)、[Apple Note](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/note)
- 信用卡、Wi-Fi 凭据、API key 和 SSH 私钥。[Apple Credit Card](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/creditcard)、[Apple Wi-Fi](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/wifi)、[Apple API Key](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/apikey)、[Apple SSH Key](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/sshkey)
- 地址、姓名、护照、驾照、通用身份证件、自定义字段、生成密码及条目引用等结构化数据。[Apple Address](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/address)、[Apple Passport](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/passport)、[Apple Drivers License](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/driverslicense)、[Apple `ASImportableCredential`](https://developer.apple.com/documentation/authenticationservices/asimportablecredential)

这里的“格式支持”不等于 Apple Passwords 一定会导出该类别。例如 schema 有信用卡类型，不代表可以借此导出 Wallet / Apple Pay 卡片；实际内容由来源密码管理器决定。`ASImportableCredential` 也没有 Sign in with Apple、证书、通用系统 Keychain item 或任意二进制密文类型，因此不能把它当作任意密钥或系统 Keychain 备份接口。自定义字段适合保留文本字段，不能据此假定接收方理解私有二进制格式。

### 用户交互与调用流程

导出必须由用户在来源应用中发起。应用先调用 `requestExport(for:)`；系统显示独立进程 UI，说明风险并让用户选择目标应用。WWDC25 还明确说明传输由本地认证（如 Face ID）保护。因此没有后台定时导出或静默整库迁移的公开路径。[Apple `ASCredentialExportManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)、[WWDC25：What's new in passkeys，19:12](https://developer.apple.com/videos/play/wwdc2025/279/?time=1152)

`requestExport(for:)` 返回双方协商的格式版本；导出方据此构造 `ASExportedCredentialData`，再调用 `exportCredentials(_:)`。系统随后用 `ASCredentialExchangeActivity` 的 `NSUserActivity` 启动接收方，接收方从 activity 取得 UUID token，并调用 `ASCredentialImportManager.importCredentials(token:)` 在内存中取得整批数据。系统充当中介，传输过程中不会创建明文 CSV/JSON 文件或把凭据写入文件系统。[Apple `ASCredentialImportManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager)、[Apple `importCredentials(token:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager/importcredentials%28token%3A%29)

### 实现要求

- 主应用需要 Credential Provider Extension；主应用与 extension 都启用 AutoFill Credential Provider capability，对应 entitlement 为 `com.apple.developer.authentication-services.autofill-credential-provider`。[Apple AutoFill Credential Provider Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.authentication-services.autofill-credential-provider)
- extension 的 `Info.plist` 需要在 `ASCredentialProviderExtensionCapabilities` 中设置 `SupportsCredentialExchange = YES`，并声明 `SupportedCredentialExchangeVersions`；当前公开版本只有 `1.0`。[Apple `ASCredentialExportManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)
- 主应用注册 Credential Exchange 的 `NSUserActivity` 类型，并只接受系统 activity 携带、且与目标应用匹配的 import token；token 不匹配时导入 API 会失败。[Apple `ASCredentialImportManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager)

## 新增密码后写入 Apple Passwords 的边界

**不能把“默认同步到 Apple Passwords”实现为 macOS 上的静默、可确认双写。** Apple 26.2 新增的 `ASCredentialDataManager.save(password:for:title:anchor:)` 只把密码提交给**系统中用户首选的密码管理器**，调用方不能传入目标应用或指定 Apple Passwords；而且该保存方法只列出 iOS、iPadOS、Mac Catalyst 和 visionOS 26.2，原生 macOS 不可用。[Apple `ASCredentialDataManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager)、[Apple `save(password:for:title:anchor:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager/save%28password%3Afor%3Atitle%3Aanchor%3A%29)

### `ASCredentialDataManager.save` 能做什么

- 在 iOS / iPadOS 26.2 及以上，普通业务 App 可以提交一个 `ASPasswordCredential`，由系统交给用户首选的密码管理器保存或更新。调用 App **不需要先成为 AutoFill provider**；它需要证明目标 URL 是自己的 `webcredentials` associated domain，除非它拥有 `com.apple.developer.web-browser` entitlement。[Apple `save(password:for:title:anchor:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager/save%28password%3Afor%3Atitle%3Aanchor%3A%29)、[Apple Associated Domains](https://developer.apple.com/documentation/xcode/configuring-an-associated-domain)
- 这意味着普通密码管理器不能用它把保险库中任意网站的条目逐条复制到 Apple Passwords：它通常不可能为用户保存的每个第三方网站取得双向 `webcredentials` 关联，密码管理器也不应假定自己能取得 Web Browser entitlement。
- 目标由用户的系统偏好决定，API 没有 `Apple Passwords`、bundle ID 或 provider ID 参数。如果用户把本产品设为首选密码管理器，保存请求可能回到本产品，而不是形成“本产品 -> Apple Passwords”的副本。
- 方法接收 presentation anchor，系统或目标 provider 可以显示保存/更新界面。第三方 provider 可以先尝试无 UI 保存，也可以返回 `userInteractionRequired`，随后系统展示 provider 的界面；有界面的实现必须允许用户取消。因此产品不能承诺每次后台静默成功。[Apple `performWithoutUserInteractionIfPossible(savePasswordRequest:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller/performwithoutuserinteractionifpossible%28savepasswordrequest%3A%29)、[Apple `prepareInterface(for:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller/prepareinterface%28for%3A%29-69elg)
- 为保护隐私，`ASCredentialDataManager` 不报告目标 manager 是否真正执行了操作；调用成功只表示参数格式正确。因此它也不能作为可确认的双写事务。[Apple `ASCredentialDataManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager)

### `ASSavePasswordRequest` 不是写 Apple Passwords 的入口

`ASSavePasswordRequest` 是系统发送给**接收方 Credential Provider Extension** 的请求对象。第三方密码管理器若希望成为系统保存目标，需要启用 AutoFill Credential Provider extension，并声明 `SupportsSavePasswordCredentials = YES`；extension 再通过无 UI 或有 UI 回调把凭据保存到自己的保险库。它不能被本产品拿来选择或直接调用 Apple Passwords。该接收链路同样从 iOS / iPadOS 26.2 开始，并不提供原生 macOS 版本。[Apple `ASSavePasswordRequest`](https://developer.apple.com/documentation/authenticationservices/assavepasswordrequest)、[Apple provider 无 UI 保存回调](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller/performwithoutuserinteractionifpossible%28savepasswordrequest%3A%29)

### `ASCredentialUpdater` 也不能写入密码值

`ASCredentialUpdater` 在 iOS / macOS 26.0 提供的是 WebAuthn Signal 类事件：更新 Passkey 的显示名称、报告有效或已撤销的 Passkey，以及报告某个密码已不再使用。它没有“新增密码”或“修改密码 secret”的方法，并且会把信号发给系统中所有已启用的 password manager。该类从 26.2 起由 `ASCredentialDataManager` 取代，但 macOS 上替代类仍只有这些 report 方法，没有 password save 方法。[Apple `ASCredentialUpdater`](https://developer.apple.com/documentation/authenticationservices/ascredentialupdater)、[Apple `ASCredentialDataManager`](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager)

### 对第一版需求的可实现结论

- macOS 26+：新增条目后若用户勾选“同步到 Apple Passwords”，唯一公开路径是启动一次 **Credential Exchange 导出**，由系统让用户选择 Apple Passwords 等目标并完成本地认证；不能默认后台执行，不能预选或锁定 Apple Passwords，也不能确认成持续双向同步。[Apple Credential Exchange / WWDC25](https://developer.apple.com/videos/play/wwdc2025/279/?time=1152)
- iOS / iPadOS 26.2+：对本产品自己拥有 associated domain 的账号，可以调用 `ASCredentialDataManager.save` 交给用户首选 manager；对保险库中的任意第三方网站仍只能使用用户主动的 Credential Exchange。
- 用户可以取消把本产品设为默认 AutoFill provider；这不妨碍本产品作为 Credential Exchange 参与方完成用户主动迁移。但“不设为默认”也不会赋予本产品指定 Apple Passwords 或后台双写的能力。

因此第一版产品文案应把该选项命名为“导出到 Apple Passwords”，点击后进入系统迁移确认流程；不应默认开启名为“同步到 Apple 密码”的开关，否则会暗示不存在的后台、持续、可确认同步能力。

## 通行密钥支持可行性

### 结论

**可以支持。** Getfor 可以在 macOS 26+ 和 Android 上成为第三方通行密钥提供方，完成通行密钥的创建、保存、选择和签名断言；也可以把自己管理的可备份通行密钥通过现有局域网加密同步复制到另一台 Getfor 设备。它不能直接读取或后台同步 Apple Passwords、Google Password Manager 等其他提供方的通行密钥；必须由用户通过系统 Credential Exchange 主动迁入 Getfor。

当前代码尚未实现该能力：macOS extension 只处理 `ASPasswordCredentialRequest`，`Info.plist` 未声明 `ProvidesPasskeys`；Android provider 只声明 `TYPE_PASSWORD_CREDENTIAL`，并明确拒绝非密码创建请求；Rust `VaultItem` 目前也只有密码和 TOTP 字段。架构文档虽已预留 `passkey` 类型，但不能视为已经实现。

| 能力 | macOS 26+ | Android | 当前 Getfor |
| --- | --- | --- | --- |
| 作为第三方 provider 创建通行密钥 | 可以 | Android 14+ 可以 | 未实现 |
| 使用本产品通行密钥完成断言 | 可以 | Android 14+ 可以 | 未实现 |
| 从其他 provider 批量导入/导出 | Credential Exchange 正式 API | Provider Events transfer API，当前为 `1.0.0-alpha06` | Apple 端仅实现密码/TOTP 等部分 CXF 映射；Android 未实现 |
| Getfor macOS ↔ Android 局域网同步 | WebAuthn 允许 local network sync | WebAuthn 允许 local network sync | 同步框架已有，通行密钥模型和规则未实现 |

### macOS 26+：创建与断言

Apple 从 macOS 14 起已允许 AutoFill Credential Provider Extension 提供通行密钥，macOS 26+ 因而满足要求。Getfor 需要：

1. 在 extension 的 `ASCredentialProviderExtensionCapabilities` 中声明 `ProvidesPasskeys = YES`；如后续支持无界面的自动升级，再声明 `SupportsConditionalPasskeyRegistration`。
2. 为保险库中的通行密钥写入 `ASPasskeyCredentialIdentity`，保存 relying party ID、用户名、credential ID、user handle 和本地 record ID。系统 identity store 只保存用于匹配和展示的 identity；私钥仍由 Getfor 自己保存。
3. 在 `prepareInterface(forPasskeyRegistration:)` 中校验请求支持的 COSE 算法、完成用户认证、生成 credential ID 和密钥对，构造 WebAuthn attestation object，再通过 `completeRegistrationRequest(using:)` 返回 `ASPasskeyRegistrationCredential`。
4. 在断言请求中按 relying party ID、`allowedCredentials` 和 user handle 找到通行密钥；满足请求的 user-verification 要求后，用私钥签名 `authenticatorData || clientDataHash`，再通过 `completeAssertionRequest(using:)` 返回 `ASPasskeyAssertionCredential`。

Apple 的 provider API 明确提供注册和断言完成接口，并要求声明 `ProvidesPasskeys` 才会出现在系统选择器中。[Apple `prepareInterface(forPasskeyRegistration:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller/prepareinterface%28forpasskeyregistration%3A%29)、[Apple `ASCredentialProviderExtensionContext`](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderextensioncontext)、[Apple `ASPasskeyRegistrationCredential`](https://developer.apple.com/documentation/authenticationservices/aspasskeyregistrationcredential)、[Apple `ASPasskeyAssertionCredential`](https://developer.apple.com/documentation/authenticationservices/aspasskeyassertioncredential)

Apple 会把 active assertion 的 relying party、允许的 credential IDs、client-data hash 和 user-verification preference 交给 extension；Getfor 必须使用这些系统提供的值，不能根据页面文字或 URL 自行猜测目标站点。[Apple `ASPasskeyCredentialRequestParameters`](https://developer.apple.com/documentation/authenticationservices/aspasskeycredentialrequestparameters)、[Apple `ASPasskeyCredentialIdentity`](https://developer.apple.com/documentation/authenticationservices/aspasskeycredentialidentity)

### Android：创建与断言

第三方 credential provider 接入点是 Android 14 引入的 Credential Manager provider API。Getfor 需要在 provider XML 增加 `androidx.credentials.TYPE_PUBLIC_KEY_CREDENTIAL`，并扩展现有 `CredentialProviderService`：

1. 创建流程处理 `BeginCreatePublicKeyCredentialRequest`，返回带 `PendingIntent` 的 `CreateEntry`。
2. 用户选择后，从 `ProviderCreateCredentialRequest` 取得 `requestJson`、`clientDataHash` 和 `CallingAppInfo`；解析并严格校验 WebAuthn creation options 和算法，验证 native App 的 Digital Asset Links，浏览器等 privileged caller 则必须通过包名与签名证书 allowlist 验证其 origin。
3. 用户认证成功后生成 credential ID 和密钥对，保存私钥及 RP/user 元数据，返回 `CreatePublicKeyCredentialResponse`。
4. 获取流程处理 `BeginGetPublicKeyCredentialOption`，只列出 RP ID 和 allow-list 匹配的条目；用户认证成功后签名 challenge，返回 `GetCredentialResponse`。

Android 官方 provider 指南明确要求通行密钥私钥加密保存，并把创建、Digital Asset Links 校验、用户认证、签名断言和 privileged origin allowlist 都列为 provider 的职责。该能力只适用于 Android 14 及以上；旧系统的传统 `AutofillService` 只能填密码，不能提供 WebAuthn 通行密钥。[Android：Integrate Credential Manager with your credential provider solution](https://developer.android.com/identity/sign-in/credential-provider)、[Android `CredentialProviderService`](https://developer.android.com/reference/androidx/credentials/provider/CredentialProviderService)、[Android Credential Manager prerequisites](https://developer.android.com/identity/credential-manager/prerequisites)

### 私钥存储模型

通行密钥不是普通文本字段。每条记录至少需要保存：credential ID、RP ID、user handle、用户名/显示名、私钥、COSE algorithm、创建时间、备份资格与状态；可能还要保存 WebAuthn extension 数据。私钥、user handle 和所有元数据都应进入现有端到端加密的 Rust 保险库，解锁后只在完成注册、断言、导入导出或同步所需的最短时间内进入内存。

若要支持 Credential Exchange 和 Getfor 局域网跨端同步，通行密钥私钥不能只生成在 Secure Enclave 或 Android Keystore 的不可导出 key slot 中。Apple 明确说明 Secure Enclave 没有导入或导出明文密钥的机制；Android Keystore 同样保证 key material 不进入应用进程且不可导出。因此这两种硬件 key 适合保护本地保险库解锁/包装密钥，但不适合作为需要在设备间复制的通行密钥本体。[Apple：Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave)、[Android Keystore system](https://developer.android.com/privacy-and-security/keystore)

第一版只实现 ES256（P-256 + SHA-256）即可，但当 relying party 没有在 `pubKeyCredParams` 中提供 ES256 时必须拒绝创建，不能擅自选算法。创建和每次断言都必须正确构造 WebAuthn `authenticatorData`，包括 RP ID hash、UP/UV、BE/BS flags 和 signature counter，并严格处理 challenge、origin/RP ID、allow/exclude credential list 与 user-verification preference。[W3C WebAuthn Level 3](https://www.w3.org/TR/webauthn-3/)

### Credential Exchange 导入导出

Apple Credential Exchange Format v1 可以携带通行密钥的 credential ID、RP ID、用户名、user handle 和 PKCS#8 私钥。因此 Getfor 在 macOS 26+ 可以批量接收 Apple Passwords 或其他参与方在用户确认后提供的通行密钥，也可以把 Getfor 通行密钥批量交给用户选择的目标 provider。系统迁移不会改变已注册在网站服务端的 public key，credential ID 和私钥必须原样保留。[Apple `ASImportableCredential.Passkey`](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/passkey)、[Apple passkey private key format](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/passkey/key)、[WWDC25：What’s new in passkeys，19:12](https://developer.apple.com/videos/play/wwdc2025/279/?time=1152)

这仍是用户主动迁移，不是持续同步接口。Getfor 无权枚举 Apple Passwords 的通行密钥，也不能静默把新通行密钥双写进去。只有通行密钥通过系统流程进入 Getfor 后，Getfor 才能把自己的副本纳入局域网同步。

Android 也已发布基于 FIDO CXF 的 provider-to-provider transfer API：`ProviderEventsManager.importCredentials` 会显示来源 provider 选择器，导出方需先注册 `ExportEntry`，传输结果使用 CXF credential types，其中包含 public-key credential。不过截至当前官方 API 仍标记为 `androidx.credentials.providerevents:providerevents:1.0.0-alpha06`，不应作为第一版稳定依赖；先完成 Getfor 自身创建、断言和局域网同步，等该 API 稳定后再接系统迁移。[Android `ProviderEventsManager`](https://developer.android.com/reference/androidx/credentials/providerevents/ProviderEventsManager)、[Android provider transfer package](https://developer.android.com/reference/androidx/credentials/providerevents/transfer/package-summary)、[Android `CredentialTypes`](https://developer.android.com/reference/androidx/credentials/providerevents/transfer/CredentialTypes)

Apple 和 Android 都采用 CXF 数据模型，不代表两套系统 UI 能直接跨平台互调：Apple 的 exchange broker 只调度 Apple 平台应用，Android Provider Events 只调度 Android provider。Getfor 的 macOS ↔ Android 迁移应继续使用自己的已配对局域网同步协议。

### 局域网同步规则

WebAuthn Level 3 明确把 peer-to-peer sync、cloud sync、**local network sync** 和 manual import/export 都列为合法的 credential backup 机制，因此“只在已配对局域网设备间同步”与标准兼容，但必须遵循：

- 准备同步的通行密钥在创建时就设置 Backup Eligibility（BE）为 `1`，表示 multi-device credential；BE 是永久属性，注册完成后不能改变。
- 尚未复制到第二台设备时使用 `BE=1, BS=0`；确认至少存在一个受信副本后使用 `BE=1, BS=1`。每次断言返回与当前状态一致的 flags。
- 第一版把 signature counter 固定为 `0`，这是 WebAuthn 允许的“不实现计数器”状态，可避免两台离线设备分别递增后让 relying party 误判克隆；不要维护无法跨离线设备严格单调的本地计数器。
- 密钥同步只能发生在完成现有双方配对、设备身份验证和加密通道建立之后；接收方落盘前必须验证记录结构、credential ID、RP ID、算法和私钥编码，并用导出的 public key 自检签名。
- cryptographic identity（credential ID、RP ID、user handle、私钥、算法、BE）创建后不可编辑。并发同步应按 credential ID 合并同一通行密钥，不得沿用普通记录的“冲突副本”逻辑生成两个内容相同的 passkey 条目；删除则同步 tombstone。
- 创建、使用、导出和删除通行密钥应要求保险库解锁；注册/断言还必须满足平台请求的用户验证要求。生物特征只用于本地授权，不能被保存或同步。

W3C 还规定 BE/BS 位的含义和状态组合，并说明 BE 必须在注册时确定；不实现 signature counter 的 authenticator 可以始终返回 `0`。[W3C：Credential Backup State](https://www.w3.org/TR/webauthn-3/#sctn-credential-backup)、[W3C：Signature Counter Considerations](https://www.w3.org/TR/webauthn-3/#sctn-sign-counter)

### 建议的最小实现顺序

1. 扩展 Rust record schema，允许一个网站/App 记录包含零到多个 passkey，并实现 ES256 生成、PKCS#8 导入导出、attestation/authenticator data 编码和断言签名；用 W3C 测试向量或独立 verifier 留下最小可运行测试。
2. macOS extension 增加 `ProvidesPasskeys`、passkey identities、注册与断言回调；Android provider 增加 public-key capability 和相同流程。
3. 把 passkey 加入现有局域网同步，但按 credential ID 去重并禁用普通字段冲突副本策略。
4. 扩展 macOS Credential Exchange 映射以导入导出 passkey；Android 系统 Credential Exchange 等 Provider Events API 稳定后再接入。

因此产品层面可以承诺“Getfor 管理并在已配对设备间同步通行密钥”，但不能承诺“实时同步 Apple Passwords / Google Password Manager 中的通行密钥”。
