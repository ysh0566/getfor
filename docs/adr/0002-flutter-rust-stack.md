# ADR-0002：Flutter UI 加 Rust 共享核心

## Status

Accepted

## Context

第一版只支持 macOS 和 Android，同时存在 Apple Credential Provider、Android Credential Manager Provider、局域网服务和后续浏览器 Native Messaging Host。加密、存储和同步逻辑不能在两个平台重复实现。

## Decision

- 主应用 UI 使用 Flutter。
- 保险库、加密、SQLite 和同步协议使用单一 Rust 核心。
- Flutter 通过小型 C ABI 和 `dart:ffi` 调用核心。
- Swift 和 Kotlin 只实现系统 API 适配，并直接复用 Rust 核心。
- 局域网发现使用平台原生 mDNS/DNS-SD；连接建立后由 Rust 处理 TLS 和同步。

## Consequences

### Positive

- 两端共享安全关键代码和测试。
- Flutter 覆盖全部目标平台，仍可通过原生薄层接入系统能力。
- 系统扩展无需启动 Flutter 引擎。

### Negative

- 构建链同时需要 Flutter、Rust、Xcode 和 Android NDK。
- C ABI 的内存所有权必须严格测试。

### Neutral

- 平台 UI 可以逐步原生化，不影响保险库格式和同步协议。

## Alternatives Considered

- 两端全原生：重复实现加密和同步，缺陷面过大。
- 纯 Flutter/Dart：系统扩展无法只依赖 Flutter 进程，安全核心也难被 Native Messaging Host 复用。
- Tauri 全端：仍需原生 Credential Provider，并增加 WebView 层；第一版没有收益。
- Kotlin Multiplatform：Apple 扩展和 Rust 核心的集成边界不如 C ABI 直接。
- React Native 加 Rust：React/TypeScript 团队更易上手，但 Rust 调用还需 TurboModule/Codegen 胶水；本项目优先使用 Flutter 的直接 FFI。

## References

- [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)
- [Flutter C interop](https://docs.flutter.dev/platform-integration/android/c-interop)
- [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels)
- [Rust platform support](https://doc.rust-lang.org/rustc/platform-support.html)
- [React Native out-of-tree platforms](https://reactnative.dev/docs/out-of-tree-platforms)
- [React Native Codegen](https://reactnative.dev/docs/the-new-architecture/what-is-codegen)
