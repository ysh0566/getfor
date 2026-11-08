# Modern Password Vault 功能状态

对照范围：Stitch 桌面设计稿与 Getfor macOS/Android 第一版。

## 第一版已完成

- 网站/App 为第一公民；同一项目可同时或分别保存密码和 TOTP。
- Argon2id + XChaCha20-Poly1305 + SQLite 本地保险库，支持修改主密码。
- macOS 26+ Credential Exchange 导入/导出、去重、默认 AutoFill 引导和 Credential Provider。
- Android 14+ Credential Manager Provider，支持系统读取与保存密码。
- Vault 三栏布局、搜索、详情、密码/TOTP 安全复制、生成器、强度和弱密码/复用审计。
- macOS Bonjour 与 Android NSD 服务发现、TLS 直连、一次性密钥配对、增量操作日志、墓碑、幂等重试和冲突副本。
- 配对设备可立即同步或移除；每对设备使用独立认证密钥，被移除设备不能继续建立同步会话。

## 明确延期

- Recovery Kit 和硬件安全密钥。
- Passkey、Wi-Fi、Secure Note、API Key、SSH Key 等更多字段模型。
- 条目历史浏览和冲突副本合并界面。
- 离线设备的长期状态、最后同步时间和二维码扫描；第一版使用 mDNS 发现加一次性密钥输入。

## 不纳入本地优先版本

- 云备份、互联网中继、暗网监控和身份监控。
- 依赖持续在线可信执行者的自动数字遗产授权。
- 银行卡、附件、证件和文件型 secret。
