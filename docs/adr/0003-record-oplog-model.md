# ADR-0003：记录级加密与操作日志同步

## Status

Accepted

## Context

设备可能长时间离线，且没有中心服务器决定顺序。同步失败不能影响本地保存，并发修改不能静默覆盖密码。数据库泄露时，网站和用户名等元数据也不应暴露。

## Decision

- 使用随机 Vault Key 对记录 payload 和操作 payload 分别进行 XChaCha20-Poly1305 加密。
- SQLite 明文列只保留随机 ID、revision、设备序号和墓碑等同步索引。
- 每个设备维护单调递增序号，设备间交换缺失操作。
- 操作携带 `base_revision_id`；基础版本不匹配时保留冲突副本。
- 删除保留墓碑，第一版不压缩操作日志。
- 解锁后搜索在内存中线性扫描，不建立明文或确定性加密索引。

## Consequences

### Positive

- 无中心节点也能重试并补齐同步。
- 并发编辑不会静默丢失。
- 数据库文件不会泄露网站、用户名或 secret。

### Negative

- 操作日志和墓碑持续增长。
- 搜索需要解密并扫描全部活动记录。
- 冲突需要用户选择。

### Neutral

- 个人保险库规模较小时，增长和线性扫描可接受；达到真实瓶颈后再增加快照或加密索引。

## Alternatives Considered

- 整库文件同步：小改动也需传输全库，并发时容易覆盖。
- 最后写入者获胜：设备时钟漂移会造成静默数据丢失。
- CRDT：密码值没有有意义的自动合并方式，复杂度没有收益。
- SQLCipher 加明文索引：仍会暴露查询元数据，且不能替代同步级记录加密。

## References

- [RustCrypto Argon2](https://docs.rs/argon2/latest/argon2/)
- [RustCrypto XChaCha20-Poly1305](https://docs.rs/chacha20poly1305/latest/chacha20poly1305/)
- [rustls](https://docs.rs/rustls/latest/rustls/)
- [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html)
