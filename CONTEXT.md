# Getfor Vault

Getfor 管理以网站或 App 为中心的本地加密凭据。

## Language

**保险库项目（Vault Item）**:
一个网站或 App 的聚合条目，可以同时包含登录凭据和 TOTP 凭据，也可以只包含其中一种。
_Avoid_: 登录密码项目、TOTP 项目、记录类型

**登录凭据（Login Credential）**:
保险库项目中的可选用户名和密码信息。
_Avoid_: 登录项目

**TOTP 凭据（TOTP Credential）**:
保险库项目中的可选一次性验证码密钥。
_Avoid_: TOTP 项目、验证器项目
