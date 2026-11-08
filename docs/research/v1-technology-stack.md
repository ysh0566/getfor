# V1 多端技术栈调研与建议

> 当前产品范围已收窄为 macOS 和 Android；本文保留原四端调研结论，iOS 与 Windows 暂缓实现。

调研日期：2026-08-07

## 结论

V1 采用以下最小组合：

- **Flutter / Dart**：Windows、macOS、iOS、Android 共用一套主应用 UI。
- **Rust shared core**：保险库读写、加密数据模型、变更日志、冲突判定和局域网同步协议只实现一次。
- **直接 Dart FFI + 稳定 C ABI**：Flutter 调 Rust；V1 不引入额外的 Rust/Flutter 桥接框架。
- **Swift 薄层**：Credential Exchange、AutoFill Credential Provider、Apple App Group 和 Apple 平台的 Bonjour。
- **Kotlin 薄层**：Android NSD、权限和生命周期；需要 Android AutoFill/Credential Provider 时也放在这一层。
- **SQLite + `rusqlite`**：每台设备一个本地数据库，数据库只存密文负载及同步所需的最少索引。
- **`rustls`，仅启用 TLS 1.3**：已配对设备间的加密传输。
- **mDNS/DNS-SD**：只负责发现；Apple 使用 Bonjour，Android 使用 `NsdManager`，Windows 使用系统 DNS-SD API。

这个拆分比“全部写在 Flutter”多一个 Rust 构建产物，但 Rust core 同时可被 Flutter 主应用和 Apple 原生扩展复用，因此没有为性能凭空增加一层。无需云服务、账号中心、远程数据库或服务端框架。

## 1. Flutter 四端可行性

Flutter 当前官方支持 Android、iOS、Windows 和 macOS。以 Flutter 3.44.7 的支持表为准：Android 24–37、iOS 13–26、Windows 10/11，以及 macOS 10.15–26 均处于支持范围；Windows 和 macOS 同时覆盖 x64 与 Arm64。因此产品要求的四端均在 Flutter 官方部署范围内，macOS 只发布 26+ 是产品主动收窄，而不是 Flutter 限制。[Flutter supported deployment platforms](https://docs.flutter.dev/reference/supported-platforms)

建议的首发二进制目标：

| 平台 | V1 构建目标 | 说明 |
| --- | --- | --- |
| Windows | x64 | Arm64 等有真实用户需求后再加；Flutter 本身支持 Arm64。 |
| macOS 26+ | Arm64 + x64 Universal | 同时覆盖 Apple Silicon 和仍运行 macOS 26 的 Intel 设备。 |
| iOS | Arm64；Arm64 Simulator 用于开发 | 最低系统版本在 UI/AutoFill 功能清单冻结后确定，不因 Rust 被迫提高。 |
| Android | Arm64；x86_64 用于模拟器 | 如需兼容 32 位真机，再增加 `armv7-linux-androideabi`。 |

Flutter 官方提供 platform channel 调用 Kotlin、Swift 和 Windows 原生代码；消息是异步传递的，适合 Credential Exchange、设置页跳转、权限请求和服务发现等系统 API。[Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels)

### UI 边界

Flutter 只实现主应用页面和状态展示。Apple AutoFill Credential Provider 是独立扩展 target、独立二进制，不能假设 Flutter 主应用正在运行；Apple 官方也要求通过 Credential Provider Extension target 实现它。因此扩展 UI 和系统回调保留 Swift，扩展通过 App Group 共享容器访问同一个保险库格式。[Apple ASCredentialProviderViewController](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller) [Apple App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)

## 2. Flutter 与 Rust 的边界

### 选择直接 Dart FFI

Dart Native 的 `dart:ffi` 可以调用 C ABI、访问原生内存；Flutter 自 3.38 起推荐用 `flutter create --template=package_ffi` 和 build hook 集成原生构建。因此 Rust crate 导出少量 `extern "C"` 函数，Dart 用 `ffigen` 从 C header 生成绑定即可。[Dart C interop](https://dart.dev/interop/c-interop) [Flutter: Bind to native code using FFI](https://docs.flutter.dev/platform-integration/bind-native-code)

V1 的 FFI 保持粗粒度：打开/关闭保险库、执行一个命令、释放返回缓冲区、读取 ABI 版本。参数与返回值使用带长度的 byte buffer，不把 Rust struct 直接暴露给 Dart。这样 ABI 面小，也避免为每个领域类型维护一套跨语言对象模型。

较慢的 SQLite、KDF 和同步操作不得阻塞 Flutter 主 isolate。Flutter 官方明确把数据库、FFI 和长任务列为 helper isolate 的常见用途；V1 使用一个长生命周期 worker isolate 串行调用 core，而不是为每个调用创建 isolate 或引入异步桥接运行时。[Flutter concurrency and isolates](https://docs.flutter.dev/perf/isolates)

### 暂不使用的桥接层

V1 不引入 `flutter_rust_bridge`、UniFFI 或自建 RPC 框架。当前 API 面很小，直接 FFI 已被 Flutter 官方支持。只有当 FFI 出现大量结构体、回调和流式事件，且手工 ABI 成为可测量的维护负担时，再评估代码生成桥。

平台 API 不经 FFI：Flutter 到 Swift/Kotlin 使用 platform channel。Apple 扩展无法依赖正在运行的 Flutter engine，必要时直接链接 Rust 静态库并调用同一 C ABI。

## 3. Rust 四端目标可行性

Rust 官方 target 支持覆盖所需平台：Windows x64、Windows Arm64 和 macOS Arm64 属于 Tier 1，macOS x64、iOS 和 Android 也有官方分发且支持标准库的 targets；移动端分别通过 Xcode SDK 与 Android NDK 交叉编译。[Rust platform support](https://doc.rust-lang.org/stable/rustc/platform-support.html) [Rust macOS targets](https://doc.rust-lang.org/stable/rustc/platform-support/apple-darwin.html) [Rust iOS targets](https://doc.rust-lang.org/stable/rustc/platform-support/apple-ios.html) [Rust Android targets](https://doc.rust-lang.org/stable/rustc/platform-support/android.html)

| 平台 | Rust target | 产物 |
| --- | --- | --- |
| Windows x64 | `x86_64-pc-windows-msvc` | `cdylib` / DLL |
| macOS Universal | `aarch64-apple-darwin`, `x86_64-apple-darwin` | 静态库，最终合并并由 Xcode/Flutter 应用签名 |
| iOS 真机 | `aarch64-apple-ios` | 静态库，链接进 app 与 extension target |
| iOS 模拟器 | `aarch64-apple-ios-sim` | 静态库 |
| Android 真机 | `aarch64-linux-android` | `cdylib` / `.so` |
| Android 模拟器 | `x86_64-linux-android` | `cdylib` / `.so` |

Rust core 建议只产出一个 crate，`crate-type` 同时允许 `staticlib` 与 `cdylib`；由各平台构建选择实际产物。iOS 不设计运行时下载或加载代码。

## 4. 本地存储：SQLite + rusqlite

SQLite 是进程内、单文件、无服务端、零配置并提供事务的数据库，适合每台设备独立保存保险库与同步日志，不需要任何常驻数据库服务。[SQLite overview](https://www.sqlite.org/about.html)

Rust 使用 `rusqlite`，打开 `bundled` feature，统一编译 crate 携带的 SQLite，避免 Windows、Apple 和 Android 系统 SQLite 版本差异。`rusqlite` 官方文档将 `bundled` 描述为最简单的跨平台构建方式。[rusqlite build notes](https://docs.rs/crate/rusqlite/latest)

最小运行模型：

- 主应用内由一个 Rust worker 持有一个写连接，事务覆盖“条目修改 + 变更日志追加”。
- Apple app 与 AutoFill extension 通过 App Group 容器访问同一数据库；SQLite 支持跨进程锁，扩展访问必须处理 `SQLITE_BUSY`，不得假设只有一个进程。[Apple shared-container guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html) [SQLite locking](https://www.sqlite.org/lockingv3.html)
- 数据库不是加密边界：凭据正文在写入 SQLite 前由 Rust core 加密；不因使用 SQLite 而保存明文密码。
- V1 不引入 ORM、数据库 daemon、SQLCipher 或搜索服务。若将来需要在不解锁全部条目的情况下做大规模全文搜索，再单独设计加密索引。

## 5. 局域网传输：rustls TLS 1.3

`rustls` 实现 TLS 1.2 与 TLS 1.3，默认不提供过时密码学；其配置 API 可显式只选择 TLS 1.3。V1 必须在 `ClientConfig` 和 `ServerConfig` 中只配置 `rustls::version::TLS13`，不能只依赖关闭 Cargo 的 `tls12` feature，因为依赖图中的其他 crate 可能重新启用 feature。[rustls crate documentation](https://docs.rs/rustls/latest/rustls/) [rustls protocol versions](https://docs.rs/rustls/latest/rustls/version/)

`rustls` 默认密码学 provider `aws-lc-rs` 的官方平台表覆盖本方案所用的 macOS、iOS、Windows 和 Android targets，因此无需针对移动端改换 TLS 实现。[aws-lc-rs platform support](https://aws.github.io/aws-lc-rs/platform_support.html)

V1 设备数量少，传输层使用 `std::net::TcpListener` / `TcpStream` 加专用 worker thread 即可；不引入 Tokio。`rustls` 本身不负责网络 I/O，并提供面向 `Read`/`Write` 的连接与 stream API，正好可包装标准库 socket。[rustls design overview](https://docs.rs/rustls/latest/rustls/)

证书/公钥固定、首次二维码配对和保险库密钥传递沿用已接受的同步 ADR；mDNS 结果不能加入 TLS 信任集合。

## 6. mDNS / DNS-SD

mDNS/DNS-SD 在四端都可行，但不应强行统一为一个 raw-socket 实现：移动系统的权限、前后台和多播接收由平台管理。

| 平台 | V1 实现 | 依据与限制 |
| --- | --- | --- |
| macOS / iOS | Swift `NWBrowser` + `NWListener.Service` | Network.framework 原生支持发现和发布 Bonjour 服务；必须声明 `NSBonjourServices` 与本地网络用途说明。[Apple NWBrowser](https://developer.apple.com/documentation/network/nwbrowser) [Apple NWListener.Service](https://developer.apple.com/documentation/network/nwlistener/service-swift.struct) |
| Android | Kotlin `NsdManager` | Android NSD 基于 DNS-SD/mDNS；旧版本前台接收 mDNS 可能需要 `WifiManager.MulticastLock`，Android 17 / API 37 起还要处理 `ACCESS_LOCAL_NETWORK`。[Android NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager) |
| Windows | C++ 调用系统 `DnsServiceBrowse` / `DnsServiceRegister` | Windows 原生提供 DNS-SD 浏览和注册 API；Flutter Windows host 已经包含 C++ 薄层，无需再增加发现依赖。[Microsoft DNS-SD](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicebrowse) |

Apple 明确要求 Bonjour 的注册、浏览和解析经过本地网络权限；直接发送/接收多播在 iOS 还可能要求额外 multicast entitlement。使用 `NWBrowser` / `NWListener` 并声明固定服务类型 `_getfor._tcp`，比从 Rust 自己打开多播 socket 更符合平台路径。[Apple TN3179: Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

发现层只传协议版本、随机设备 ID 和端口；用户名、保险库名、条目数、证书或配对秘密都不放进 TXT record。发现回调通过 platform channel 交给 Flutter/Rust 同步入口；设备身份仍由已配对公钥确认。

## 7. 建议的最小代码边界

```text
Flutter app
  UI、导航、可取消的 AutoFill 引导、同步状态
      | dart:ffi                         | platform channel
      v                                  v
Rust getfor_core                    Swift / Kotlin thin layer
  vault + SQLite                    Apple Credential Exchange
  encrypted change log              Apple AutoFill extension
  conflict detection                Bonjour / Android NSD
  TLS 1.3 sync                      permissions + lifecycle
```

只保留两个本地模块即可：Flutter app 与 Rust core。Swift/Kotlin 代码先放在 Flutter host 工程及必需的 extension/service target 中，不为 V1 拆成可发布插件、federated packages 或独立 SDK。

## 8. 构建与验证底线

- 将 Flutter stable 和 Rust stable 的具体版本写入仓库配置并提交 lockfile；不要在 CI 中漂移到“latest”。
- Apple 产物必须在带 Xcode 的 macOS runner 构建；Windows MSVC DLL 在 Windows runner 构建，不规划非 Windows 主机交叉编译 MSVC 产物。[Flutter platform setup](https://docs.flutter.dev/platform-integration) [Rust Windows MSVC targets](https://doc.rust-lang.org/stable/rustc/platform-support/windows-msvc.html)
- 每个平台至少跑一个 FFI ABI smoke test：创建临时保险库、写入一条加密记录、关闭后重开读取。
- 真机验证 Apple 本地网络授权拒绝/重新授权、Android 多播接收及应用回前台补同步。
- 两台异构设备做一次 TLS 1.3 配对后同步，确认未配对设备只能发现服务，不能完成握手。
- Apple 主应用与 AutoFill extension 并发读写一次共享 SQLite，验证 `SQLITE_BUSY` 重试而不是丢失更新。

## 9. 明确不选

- 云同步 SDK、BaaS、远程数据库、账号服务。
- 为 V1 引入 Tokio、gRPC、WebSocket、CRDT 或通用插件系统。
- 在 Dart、Swift、Kotlin 各实现一份保险库和冲突逻辑。
- 用纯 Rust raw multicast 替代 iOS/Android 原生服务发现。
- 为当前很小的 FFI 面引入桥接代码生成框架。
