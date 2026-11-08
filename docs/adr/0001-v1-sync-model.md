# ADR-0001：第一版采用用户确认的 Apple 写入与局域网设备同步

## Status

Accepted

## Context

第一版需要导入 macOS 26+ 的 Apple Passwords 数据；用户可以取消把本产品设为默认 AutoFill Provider；本产品新建密码时默认尝试同时保存到 Apple Passwords。macOS 与 Android 之间不使用云服务，只允许在局域网内发现并互传。

Apple Credential Exchange 是用户发起且由系统 UI 中介的迁移机制，不提供第三方应用静默读写 Apple Passwords 的能力。局域网广播也只能用于发现，不能证明对端可信。

## Decision

- Apple Passwords 的初始导入使用 Credential Exchange。
- 新建密码时默认选中“保存后导出到 Apple Passwords（下一步需选择 Apple Passwords）”，通过单条 Credential Exchange 完成；本地保存不依赖该流程成功。
- 默认 AutoFill 引导必须允许取消。
- 设备发现使用 mDNS/DNS-SD，服务类型为 `_getfor._tcp.local`。
- 设备首次同步前必须通过二维码完成显式配对；后续连接使用固定公钥的 TLS 1.3。
- 同步采用加密变更记录和两两交换；并发修改保留冲突副本。
- Android 同步只保证在应用获得执行时间时进行，不承诺常驻后台服务。

## Consequences

### Positive

- 不需要维护服务器，符合局域网限定。
- Apple 凭据传输不产生明文导出文件。
- mDNS 发现和设备信任分离，附近的未授权设备无法加入保险库。
- Apple 导出失败不会造成已创建密码丢失。

### Negative

- 每次保存到 Apple Passwords 都需要系统交互，不能完全无感。
- 设备不在同一局域网或 Android 应用长期未运行时，同步会延迟。
- 离线并发修改需要用户处理冲突。

### Neutral

- “保存到 Apple Passwords”和“本产品设备同步”是两个独立状态。

## Alternatives Considered

- 直接写 Apple Passwords：macOS 没有公开的通用写入 API。
- 解析 Apple 私有数据库：接口不稳定且破坏安全边界，不采用。
- 云端中继：违反第一版仅局域网同步的约束。
- 未配对设备直接同步：mDNS 广播不提供可信身份，不采用。

## References

- [Apple ASCredentialExportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)
- [Apple ASCredentialImportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager)
- [Apple Bonjour](https://developer.apple.com/documentation/foundation/bonjour/)
- [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
