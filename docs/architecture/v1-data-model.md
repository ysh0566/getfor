# 第一版技术栈与保险库模型

状态：已确认

## 技术栈

| 层 | 选择 | 职责 |
| --- | --- | --- |
| 跨端 UI | Flutter / Dart | macOS、Android 主应用界面 |
| 共享核心 | Rust 静态/动态库 | 保险库、加密、SQLite、冲突处理、局域网传输 |
| Flutter 与核心 | 小型 C ABI + `dart:ffi` | 只暴露保险库和同步用例，不暴露内部表结构 |
| Apple 系统接入 | Swift | Credential Exchange、AutoFill Credential Provider、Bonjour |
| Android 系统接入 | Kotlin | Credential Manager Provider、NSD、生命周期 |
| 本地存储 | SQLite / `rusqlite` bundled | 单文件事务存储，不依赖系统 SQLite 版本 |
| 传输 | TCP + TLS 1.3 / `rustls` | 已配对设备之间的双向同步 |
| 消息格式 | 长度前缀 JSON | 小数据量下优先可调试性；单帧设置硬上限 |

不引入服务端、HTTP API、gRPC、Protobuf、消息队列或异步运行时。个人保险库规模下，同步使用阻塞 socket 和少量后台线程即可。

## 代码边界

```text
Flutter UI
   | dart:ffi
   v
Rust Core ----------------------- SQLite
   ^                                  |
   | C ABI                            | encrypted rows
   |
Swift / Kotlin platform bridge
   |
   +-- Credential Provider / Credential Exchange
   +-- mDNS / DNS-SD discovery
   +-- OS key store and biometric unlock
```

系统扩展不能依赖 Flutter 引擎启动。Apple Credential Provider、Android Credential Manager Provider 和后续桌面浏览器 Native Messaging Host 都直接调用同一个 Rust C ABI。

## 加密模型

1. 首次创建保险库时生成随机 256-bit Vault Key。
2. 主密码通过 Argon2id 派生 Key Encryption Key；内存、迭代和并行度参数写入保险库头，并允许按设备性能校准。
3. Vault Key 使用 XChaCha20-Poly1305 封装；修改主密码只重新封装 Vault Key。
4. 每条记录和操作日志使用 Vault Key、随机 192-bit nonce 和 XChaCha20-Poly1305 独立加密。
5. AAD 固定包含格式版本、vault ID、record ID、revision ID 和 operation ID，防止密文被移到其他上下文。
6. OS Keychain 和 Android Keystore 只保存可选的本机快速解锁材料，不保存保险库明文。

所有随机值来自操作系统安全随机源。密钥和主密码缓冲区在 Rust 中使用后清零；UI 层不缓存密码明文。

## 记录模型

SQLite 只保留同步必需的非秘密索引；网站、用户名、标题和 secret 全部在加密 payload 内。

### `vault_meta`

单行表：

- `vault_id`
- `format_version`
- `kdf_salt`
- `kdf_memory_kib`
- `kdf_iterations`
- `kdf_parallelism`
- `wrapped_vault_key_nonce`
- `wrapped_vault_key`

### `devices`

- `device_id`
- `public_key`
- `encrypted_display_name`
- `status`：active / revoked
- `added_at`

### `records`

- `record_id`
- `revision_id`
- `operation_id`
- `tombstone`
- `nonce`
- `ciphertext`

解密后的 `RecordPayload` 第一版支持：

- login：网站/App、用户名、密码
- passkey
- TOTP
- Wi-Fi 凭据
- secure note
- API key
- SSH key
- custom：有标签的文本字段

不支持附件、证件、银行卡和文件型 secret。

### `operations`

- `operation_id`
- `origin_device_id`
- `origin_sequence`
- `record_id`
- `base_revision_id`
- `new_revision_id`
- `tombstone`
- `nonce`
- `ciphertext`

唯一约束：`operation_id` 唯一，且 `(origin_device_id, origin_sequence)` 唯一。

## 同步规则

1. 每个设备只递增自己的 `origin_sequence`。
2. 同步握手交换各 origin 已连续收到的最高序号。
3. 对端只发送缺失操作；接收方在单个 SQLite 事务中写入操作并更新记录。
4. 当前 revision 等于操作的 `base_revision_id` 时直接应用。
5. 不相等表示离线并发修改：保留当前记录，并用新的 record ID 保存冲突副本。
6. 删除也生成操作和墓碑，不物理删除同步历史。
7. 网络中断只丢弃未提交事务；下次连接继续交换缺失操作。

第一版不压缩操作日志、不做字段级合并、不使用 CRDT。个人保险库的搜索在解锁后于内存中线性扫描；达到可测量性能瓶颈后再增加加密索引。

## 最小 C ABI

- `vault_create` / `vault_open` / `vault_lock`
- `record_list` / `record_get` / `record_put` / `record_delete`
- `pairing_offer_create` / `pairing_accept`
- `sync_start` / `sync_stop` / `sync_status`

ABI 传递长度明确的字节缓冲区；所有返回缓冲区都由 Rust 分配，并提供配套释放函数。复杂结果先使用 JSON，避免第一版维护四套生成式绑定。

## 最小验证

- Rust 单元测试验证错误主密码、密文篡改、nonce 长度和 AAD 绑定。
- 三个临时 SQLite 保险库做同步测试：顺序同步、断线重试、删除、并发冲突。
- Apple/Android 真机测试系统扩展可以在不启动 Flutter 引擎时读取已解锁保险库。
- macOS 与 Android 完成双向发现、配对和同步冒烟测试。
