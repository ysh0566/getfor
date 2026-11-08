use std::path::Path;

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use std::collections::HashMap;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;
use zeroize::{Zeroize, Zeroizing};

const FORMAT_VERSION: u32 = 1;
const VAULT_ID_LEN: usize = 16;
const SALT_LEN: usize = 16;
const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 24;
const WRAPPED_KEY_LEN: usize = KEY_LEN + 16;

const DEFAULT_MEMORY_KIB: u32 = 19 * 1024;
const DEFAULT_ITERATIONS: u32 = 2;
const DEFAULT_PARALLELISM: u32 = 1;
const MAX_MEMORY_KIB: u32 = 256 * 1024;
const MAX_ITERATIONS: u32 = 10;
const MAX_PARALLELISM: u32 = 8;
pub(crate) const MAX_PASSWORD_LEN: usize = 1024;
pub(crate) const MAX_RECORD_JSON_LEN: usize = 128 * 1024;
const MIN_PASSWORD_LEN: usize = 8;

const CREATE_SCHEMA: &str = "
    CREATE TABLE vault_meta (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        vault_id BLOB NOT NULL CHECK (length(vault_id) = 16),
        format_version INTEGER NOT NULL,
        kdf_salt BLOB NOT NULL CHECK (length(kdf_salt) = 16),
        kdf_memory_kib INTEGER NOT NULL,
        kdf_iterations INTEGER NOT NULL,
        kdf_parallelism INTEGER NOT NULL,
        wrapped_vault_key_nonce BLOB NOT NULL CHECK (length(wrapped_vault_key_nonce) = 24),
        wrapped_vault_key BLOB NOT NULL CHECK (length(wrapped_vault_key) = 48),
        quick_unlock_nonce BLOB NOT NULL CHECK (length(quick_unlock_nonce) = 24),
        quick_unlock_ciphertext BLOB NOT NULL CHECK (length(quick_unlock_ciphertext) = 16),
        local_device_id BLOB NOT NULL CHECK (length(local_device_id) = 16),
        origin_sequence INTEGER NOT NULL DEFAULT 0 CHECK (origin_sequence >= 0)
    ) STRICT;
    CREATE TABLE records (
        record_id BLOB PRIMARY KEY CHECK (length(record_id) = 16),
        revision_id BLOB NOT NULL CHECK (length(revision_id) = 16),
        operation_id BLOB NOT NULL CHECK (length(operation_id) = 16),
        tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
        nonce BLOB NOT NULL CHECK (length(nonce) = 24),
        ciphertext BLOB NOT NULL
    ) STRICT;
    CREATE TABLE devices (
        device_id BLOB PRIMARY KEY CHECK (length(device_id) = 16),
        public_key BLOB NOT NULL,
        encrypted_display_name BLOB NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
        added_at INTEGER NOT NULL
    ) STRICT;
    CREATE TABLE operations (
        operation_id BLOB PRIMARY KEY CHECK (length(operation_id) = 16),
        origin_device_id BLOB NOT NULL CHECK (length(origin_device_id) = 16),
        origin_sequence INTEGER NOT NULL CHECK (origin_sequence > 0),
        record_id BLOB NOT NULL CHECK (length(record_id) = 16),
        base_revision_id BLOB CHECK (base_revision_id IS NULL OR length(base_revision_id) = 16),
        new_revision_id BLOB NOT NULL CHECK (length(new_revision_id) = 16),
        tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
        nonce BLOB NOT NULL CHECK (length(nonce) = 24),
        ciphertext BLOB NOT NULL,
        UNIQUE(origin_device_id, origin_sequence)
    ) STRICT;
    PRAGMA user_version = 2;
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VaultError {
    InvalidArgument,
    AlreadyExists,
    NotFound,
    InvalidCredentialsOrCorrupt,
    Storage,
    Internal,
}

#[derive(Clone, Copy)]
struct KdfParams {
    memory_kib: u32,
    iterations: u32,
    parallelism: u32,
}

impl KdfParams {
    const DEFAULT: Self = Self {
        memory_kib: DEFAULT_MEMORY_KIB,
        iterations: DEFAULT_ITERATIONS,
        parallelism: DEFAULT_PARALLELISM,
    };

    fn validate(self) -> Result<Self, VaultError> {
        if !(DEFAULT_MEMORY_KIB..=MAX_MEMORY_KIB).contains(&self.memory_kib)
            || !(DEFAULT_ITERATIONS..=MAX_ITERATIONS).contains(&self.iterations)
            || !(DEFAULT_PARALLELISM..=MAX_PARALLELISM).contains(&self.parallelism)
        {
            return Err(VaultError::InvalidCredentialsOrCorrupt);
        }
        Ok(self)
    }
}

struct VaultHeader {
    vault_id: Vec<u8>,
    format_version: u32,
    kdf_salt: Vec<u8>,
    kdf: KdfParams,
    nonce: Vec<u8>,
    wrapped_key: Vec<u8>,
}

pub(crate) struct Vault {
    // Keeping both values in this handle guarantees lock closes SQLite and zeroes the key.
    connection: Connection,
    vault_id: [u8; VAULT_ID_LEN],
    vault_key: Zeroizing<[u8; KEY_LEN]>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct VaultItem {
    id: String,
    #[serde(default, rename = "kind", skip_serializing)]
    legacy_kind: Option<String>,
    title: String,
    website: String,
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    totp_secret: String,
    #[serde(default = "default_totp_period")]
    totp_period: u16,
    #[serde(default = "default_totp_digits")]
    totp_digits: u16,
    #[serde(default = "default_totp_algorithm")]
    totp_algorithm: String,
    #[serde(default)]
    passkeys: Vec<PasskeyCredential>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PasskeyCredential {
    credential_id: String,
    relying_party_id: String,
    user_handle: String,
    user_name: String,
    #[serde(default)]
    user_display_name: String,
    private_key_pkcs8: String,
    #[serde(default = "default_true")]
    backup_eligible: bool,
    #[serde(default)]
    backup_state: bool,
}

impl Drop for PasskeyCredential {
    fn drop(&mut self) {
        self.credential_id.zeroize();
        self.relying_party_id.zeroize();
        self.user_handle.zeroize();
        self.user_name.zeroize();
        self.user_display_name.zeroize();
        self.private_key_pkcs8.zeroize();
    }
}

impl Drop for VaultItem {
    fn drop(&mut self) {
        self.title.zeroize();
        self.website.zeroize();
        self.username.zeroize();
        self.password.zeroize();
        self.totp_secret.zeroize();
        self.totp_algorithm.zeroize();
        self.passkeys.clear();
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VaultItemInput {
    #[serde(default)]
    id: Option<String>,
    title: String,
    #[serde(default)]
    website: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    totp_secret: String,
    #[serde(default = "default_totp_period")]
    totp_period: u16,
    #[serde(default = "default_totp_digits")]
    totp_digits: u16,
    #[serde(default = "default_totp_algorithm")]
    totp_algorithm: String,
    #[serde(default)]
    passkeys: Vec<PasskeyCredential>,
}

impl Drop for VaultItemInput {
    fn drop(&mut self) {
        if let Some(id) = &mut self.id {
            id.zeroize();
        }
        self.title.zeroize();
        self.website.zeroize();
        self.username.zeroize();
        self.password.zeroize();
        self.totp_secret.zeroize();
        self.totp_algorithm.zeroize();
        self.passkeys.clear();
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VaultItemSummary {
    id: String,
    title: String,
    website: String,
    username: String,
    has_password: bool,
    has_totp: bool,
    has_passkey: bool,
    passkey_count: usize,
}

struct EncryptedRecord {
    record_id: Vec<u8>,
    revision_id: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
}

struct LegacyRecord {
    record_id: [u8; VAULT_ID_LEN],
    revision_id: [u8; VAULT_ID_LEN],
    tombstone: bool,
    nonce: [u8; NONCE_LEN],
    ciphertext: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OperationPayload {
    record_nonce: String,
    record_ciphertext: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncState {
    origins: HashMap<String, u64>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncBundle {
    vault_id: String,
    operations: Vec<SyncOperation>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncOperation {
    operation_id: String,
    origin_device_id: String,
    origin_sequence: u64,
    record_id: String,
    base_revision_id: Option<String>,
    new_revision_id: String,
    tombstone: bool,
    nonce: String,
    ciphertext: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingOffer {
    token: String,
    nonce: String,
    ciphertext: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingPayload {
    vault_id: String,
    vault_key: String,
}

impl Vault {
    pub(crate) fn create(path: &Path, password: &[u8]) -> Result<Self, VaultError> {
        validate_create_input(path, password)?;

        let parent = path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let temporary = NamedTempFile::new_in(parent).map_err(|_| VaultError::Storage)?;

        let vault_id = random_array::<VAULT_ID_LEN>()?;
        let local_device_id = random_array::<VAULT_ID_LEN>()?;
        let salt = random_array::<SALT_LEN>()?;
        let nonce = random_array::<NONCE_LEN>()?;
        let vault_key = Zeroizing::new(random_array::<KEY_LEN>()?);
        let kek = derive_key(password, &salt, KdfParams::DEFAULT)?;
        let aad = vault_key_aad(&vault_id, FORMAT_VERSION);
        let cipher =
            XChaCha20Poly1305::new_from_slice(kek.as_ref()).map_err(|_| VaultError::Internal)?;
        let wrapped_key = cipher
            .encrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: vault_key.as_ref(),
                    aad: &aad,
                },
            )
            .map_err(|_| VaultError::Internal)?;
        let quick_unlock_nonce = random_array::<NONCE_LEN>()?;
        let quick_unlock_ciphertext = XChaCha20Poly1305::new_from_slice(vault_key.as_ref())
            .map_err(|_| VaultError::Internal)?
            .encrypt(
                &XNonce::from(quick_unlock_nonce),
                Payload {
                    msg: &[],
                    aad: &quick_unlock_aad(&vault_id),
                },
            )
            .map_err(|_| VaultError::Internal)?;

        let mut connection = open_existing(temporary.path())?;
        let transaction = connection.transaction().map_err(|_| VaultError::Storage)?;
        transaction
            .execute_batch(CREATE_SCHEMA)
            .map_err(|_| VaultError::Storage)?;
        transaction
            .execute(
                "INSERT INTO vault_meta (
                    id, vault_id, format_version, kdf_salt, kdf_memory_kib,
                    kdf_iterations, kdf_parallelism, wrapped_vault_key_nonce,
                    wrapped_vault_key, quick_unlock_nonce, quick_unlock_ciphertext,
                    local_device_id, origin_sequence
                 ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0)",
                params![
                    &vault_id[..],
                    FORMAT_VERSION,
                    &salt[..],
                    KdfParams::DEFAULT.memory_kib,
                    KdfParams::DEFAULT.iterations,
                    KdfParams::DEFAULT.parallelism,
                    &nonce[..],
                    &wrapped_key,
                    &quick_unlock_nonce[..],
                    &quick_unlock_ciphertext,
                    &local_device_id[..],
                ],
            )
            .map_err(|_| VaultError::Storage)?;
        transaction.commit().map_err(|_| VaultError::Storage)?;
        drop(connection);
        temporary
            .as_file()
            .sync_all()
            .map_err(|_| VaultError::Storage)?;

        temporary.persist_noclobber(path).map_err(|error| {
            if error.error.kind() == std::io::ErrorKind::AlreadyExists {
                VaultError::AlreadyExists
            } else {
                VaultError::Storage
            }
        })?;

        Ok(Self {
            connection: open_existing(path)?,
            vault_id,
            vault_key,
        })
    }

    pub(crate) fn open(path: &Path, password: &[u8]) -> Result<Self, VaultError> {
        validate_password(password)?;
        let connection = open_existing(path)?;
        let header = read_header(&connection)?;
        validate_header(&header)?;

        let vault_id: [u8; VAULT_ID_LEN] = header
            .vault_id
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let nonce: [u8; NONCE_LEN] = header
            .nonce
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let kek = derive_key(password, &header.kdf_salt, header.kdf)?;
        let cipher = XChaCha20Poly1305::new_from_slice(kek.as_ref())
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    &XNonce::from(nonce),
                    Payload {
                        msg: &header.wrapped_key,
                        aad: &vault_key_aad(&vault_id, header.format_version),
                    },
                )
                .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
        );
        let vault_key: [u8; KEY_LEN] = plaintext
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;

        let vault = Self {
            connection,
            vault_id,
            vault_key: Zeroizing::new(vault_key),
        };
        vault.migrate_schema()?;
        Ok(vault)
    }

    pub(crate) fn open_with_key(path: &Path, key: &[u8]) -> Result<Self, VaultError> {
        let vault_key: [u8; KEY_LEN] = key
            .try_into()
            .map_err(|_| VaultError::InvalidArgument)?;
        let connection = open_existing(path)?;
        let (vault_id, format_version, nonce, ciphertext): (Vec<u8>, u32, Vec<u8>, Vec<u8>) =
            connection
                .query_row(
                    "SELECT vault_id, format_version, quick_unlock_nonce,
                            quick_unlock_ciphertext FROM vault_meta WHERE id = 1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let vault_id: [u8; VAULT_ID_LEN] = vault_id
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        if format_version != FORMAT_VERSION {
            return Err(VaultError::InvalidCredentialsOrCorrupt);
        }
        let nonce: [u8; NONCE_LEN] = nonce
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        XChaCha20Poly1305::new_from_slice(&vault_key)
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?
            .decrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: &ciphertext,
                    aad: &quick_unlock_aad(&vault_id),
                },
            )
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        Ok(Self {
            connection,
            vault_id,
            vault_key: Zeroizing::new(vault_key),
        })
    }

    pub(crate) fn quick_unlock_key(&self) -> Vec<u8> {
        self.vault_key.to_vec()
    }

    fn migrate_schema(&self) -> Result<(), VaultError> {
        let version = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))
            .map_err(|_| VaultError::Storage)?;
        match version {
            2 => Ok(()),
            1 => self.migrate_v1_to_v2(),
            _ => Err(VaultError::InvalidCredentialsOrCorrupt),
        }
    }

    fn migrate_v1_to_v2(&self) -> Result<(), VaultError> {
        let quick_unlock_nonce = random_array::<NONCE_LEN>()?;
        let quick_unlock_ciphertext = XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::Internal)?
            .encrypt(
                &XNonce::from(quick_unlock_nonce),
                Payload {
                    msg: &[],
                    aad: &quick_unlock_aad(&self.vault_id),
                },
            )
            .map_err(|_| VaultError::Internal)?;
        let local_device_id = random_array::<VAULT_ID_LEN>()?;
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|_| VaultError::Storage)?;

        // Rename first so CREATE_SCHEMA rebuilds the exact V2 constraints; the transaction
        // guarantees an interrupted migration leaves the original vault untouched.
        transaction
            .execute_batch(
                "ALTER TABLE vault_meta RENAME TO vault_meta_v1;
                 ALTER TABLE records RENAME TO records_v1;",
            )
            .map_err(|_| VaultError::Storage)?;
        transaction
            .execute_batch(CREATE_SCHEMA)
            .map_err(|_| VaultError::Storage)?;

        let records = {
            let mut statement = transaction
                .prepare(
                    "SELECT record_id, revision_id, tombstone, nonce, ciphertext
                     FROM records_v1 ORDER BY rowid",
                )
                .map_err(|_| VaultError::Storage)?;
            let mut rows = statement.query([]).map_err(|_| VaultError::Storage)?;
            let mut records = Vec::new();
            while let Some(row) = rows.next().map_err(|_| VaultError::Storage)? {
                let tombstone = row.get::<_, i64>(2).map_err(|_| VaultError::Storage)?;
                if !matches!(tombstone, 0 | 1) {
                    return Err(VaultError::InvalidCredentialsOrCorrupt);
                }
                records.push(LegacyRecord {
                    record_id: row
                        .get::<_, Vec<u8>>(0)
                        .map_err(|_| VaultError::Storage)?
                        .try_into()
                        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
                    revision_id: row
                        .get::<_, Vec<u8>>(1)
                        .map_err(|_| VaultError::Storage)?
                        .try_into()
                        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
                    tombstone: tombstone != 0,
                    nonce: row
                        .get::<_, Vec<u8>>(3)
                        .map_err(|_| VaultError::Storage)?
                        .try_into()
                        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
                    ciphertext: row.get(4).map_err(|_| VaultError::Storage)?,
                });
            }
            records
        };
        let origin_sequence = i64::try_from(records.len()).map_err(|_| VaultError::Storage)?;
        let inserted = transaction
            .execute(
                "INSERT INTO vault_meta (
                    id, vault_id, format_version, kdf_salt, kdf_memory_kib,
                    kdf_iterations, kdf_parallelism, wrapped_vault_key_nonce,
                    wrapped_vault_key, quick_unlock_nonce, quick_unlock_ciphertext,
                    local_device_id, origin_sequence
                 ) SELECT id, vault_id, format_version, kdf_salt, kdf_memory_kib,
                    kdf_iterations, kdf_parallelism, wrapped_vault_key_nonce,
                    wrapped_vault_key, ?1, ?2, ?3, ?4 FROM vault_meta_v1",
                params![
                    &quick_unlock_nonce[..],
                    &quick_unlock_ciphertext,
                    &local_device_id[..],
                    origin_sequence,
                ],
            )
            .map_err(|_| VaultError::Storage)?;
        if inserted != 1 {
            return Err(VaultError::InvalidCredentialsOrCorrupt);
        }

        for (index, record) in records.iter().enumerate() {
            let operation_id = random_array::<VAULT_ID_LEN>()?;
            let sequence = u64::try_from(index + 1).map_err(|_| VaultError::Storage)?;
            let (operation_nonce, operation_ciphertext) = self.encrypt_operation(
                &operation_id,
                &record.record_id,
                &record.revision_id,
                &record.nonce,
                &record.ciphertext,
            )?;
            transaction
                .execute(
                    "INSERT INTO records
                        (record_id, revision_id, operation_id, tombstone, nonce, ciphertext)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        &record.record_id[..],
                        &record.revision_id[..],
                        &operation_id[..],
                        i64::from(record.tombstone),
                        &record.nonce[..],
                        &record.ciphertext,
                    ],
                )
                .map_err(|_| VaultError::Storage)?;
            insert_operation(
                &transaction,
                &operation_id,
                &local_device_id,
                sequence,
                &record.record_id,
                None,
                &record.revision_id,
                record.tombstone,
                &operation_nonce,
                &operation_ciphertext,
            )?;
        }
        transaction
            .execute_batch("DROP TABLE records_v1; DROP TABLE vault_meta_v1;")
            .map_err(|_| VaultError::Storage)?;
        transaction.commit().map_err(|_| VaultError::Storage)
    }

    pub(crate) fn change_password(
        &self,
        current_password: &[u8],
        new_password: &[u8],
    ) -> Result<(), VaultError> {
        validate_password(current_password)?;
        validate_password(new_password)?;
        let header = read_header(&self.connection)?;
        validate_header(&header)?;
        let current_kek = derive_key(current_password, &header.kdf_salt, header.kdf)?;
        let current_cipher = XChaCha20Poly1305::new_from_slice(current_kek.as_ref())
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let current_nonce: [u8; NONCE_LEN] = header
            .nonce
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let unwrapped = Zeroizing::new(
            current_cipher
                .decrypt(
                    &XNonce::from(current_nonce),
                    Payload {
                        msg: &header.wrapped_key,
                        aad: &vault_key_aad(&self.vault_id, header.format_version),
                    },
                )
                .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
        );
        // Compare every byte so a valid open handle cannot be rebound to a different vault key.
        let mismatch = unwrapped
            .iter()
            .zip(self.vault_key.iter())
            .fold(unwrapped.len() ^ KEY_LEN, |value, (left, right)| {
                value | usize::from(*left ^ *right)
            });
        if mismatch != 0 {
            return Err(VaultError::InvalidCredentialsOrCorrupt);
        }

        let salt = random_array::<SALT_LEN>()?;
        let nonce = random_array::<NONCE_LEN>()?;
        let new_kek = derive_key(new_password, &salt, header.kdf)?;
        let new_cipher = XChaCha20Poly1305::new_from_slice(new_kek.as_ref())
            .map_err(|_| VaultError::Internal)?;
        let wrapped_key = new_cipher
            .encrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: self.vault_key.as_ref(),
                    aad: &vault_key_aad(&self.vault_id, header.format_version),
                },
            )
            .map_err(|_| VaultError::Internal)?;
        let updated = self
            .connection
            .execute(
                "UPDATE vault_meta
                 SET kdf_salt = ?1,
                     wrapped_vault_key_nonce = ?2,
                     wrapped_vault_key = ?3
                 WHERE id = 1",
                params![&salt[..], &nonce[..], &wrapped_key],
            )
            .map_err(|_| VaultError::Storage)?;
        if updated != 1 {
            return Err(VaultError::Storage);
        }
        Ok(())
    }

    pub(crate) fn pairing_offer_json(&self) -> Result<Vec<u8>, VaultError> {
        let token = Zeroizing::new(random_array::<KEY_LEN>()?);
        let nonce = random_array::<NONCE_LEN>()?;
        let plaintext = Zeroizing::new(
            serde_json::to_vec(&PairingPayload {
                vault_id: encode_id(&self.vault_id),
                vault_key: encode_bytes(self.vault_key.as_ref()),
            })
            .map_err(|_| VaultError::Internal)?,
        );
        let cipher = XChaCha20Poly1305::new_from_slice(token.as_ref())
            .map_err(|_| VaultError::Internal)?;
        let ciphertext = cipher
            .encrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: &plaintext,
                    aad: b"getfor:pairing:v1",
                },
            )
            .map_err(|_| VaultError::Internal)?;
        serde_json::to_vec(&PairingOffer {
            token: encode_bytes(token.as_ref()),
            nonce: encode_bytes(&nonce),
            ciphertext: encode_bytes(&ciphertext),
        })
        .map_err(|_| VaultError::Internal)
    }

    pub(crate) fn pairing_accept_json(
        &mut self,
        offer_json: &[u8],
        current_password: &[u8],
    ) -> Result<(), VaultError> {
        validate_password(current_password)?;
        if offer_json.is_empty() || offer_json.len() > MAX_RECORD_JSON_LEN {
            return Err(VaultError::InvalidArgument);
        }
        let offer: PairingOffer =
            serde_json::from_slice(offer_json).map_err(|_| VaultError::InvalidArgument)?;
        let token: Zeroizing<[u8; KEY_LEN]> = Zeroizing::new(
            decode_bytes(&offer.token)?
                .try_into()
                .map_err(|_| VaultError::InvalidArgument)?,
        );
        let nonce: [u8; NONCE_LEN] = decode_bytes(&offer.nonce)?
            .try_into()
            .map_err(|_| VaultError::InvalidArgument)?;
        let ciphertext = decode_bytes(&offer.ciphertext)?;
        let cipher = XChaCha20Poly1305::new_from_slice(token.as_ref())
            .map_err(|_| VaultError::InvalidArgument)?;
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    &XNonce::from(nonce),
                    Payload {
                        msg: &ciphertext,
                        aad: b"getfor:pairing:v1",
                    },
                )
                .map_err(|_| VaultError::InvalidArgument)?,
        );
        let payload: PairingPayload =
            serde_json::from_slice(&plaintext).map_err(|_| VaultError::InvalidArgument)?;
        let new_vault_id = parse_id(&payload.vault_id)?;
        let new_vault_key: [u8; KEY_LEN] = decode_bytes(&payload.vault_key)?
            .try_into()
            .map_err(|_| VaultError::InvalidArgument)?;

        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|_| VaultError::Storage)?;
        let record_count: i64 = transaction
            .query_row("SELECT count(*) FROM records", [], |row| row.get(0))
            .map_err(|_| VaultError::Storage)?;
        if record_count != 0 {
            // Joining rewrites the vault key, so accepting into a non-empty vault would destroy data.
            return Err(VaultError::AlreadyExists);
        }
        let header = read_header(&transaction)?;
        let current_kek = derive_key(current_password, &header.kdf_salt, header.kdf)?;
        let current_cipher = XChaCha20Poly1305::new_from_slice(current_kek.as_ref())
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        current_cipher
            .decrypt(
                &XNonce::from(
                    <[u8; NONCE_LEN]>::try_from(header.nonce.as_slice())
                        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
                ),
                Payload {
                    msg: &header.wrapped_key,
                    aad: &vault_key_aad(&self.vault_id, header.format_version),
                },
            )
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;

        let new_nonce = random_array::<NONCE_LEN>()?;
        let wrapped_key = current_cipher
            .encrypt(
                &XNonce::from(new_nonce),
                Payload {
                    msg: &new_vault_key,
                    aad: &vault_key_aad(&new_vault_id, header.format_version),
                },
            )
            .map_err(|_| VaultError::Internal)?;
        let quick_unlock_nonce = random_array::<NONCE_LEN>()?;
        let quick_unlock_ciphertext = XChaCha20Poly1305::new_from_slice(&new_vault_key)
            .map_err(|_| VaultError::Internal)?
            .encrypt(
                &XNonce::from(quick_unlock_nonce),
                Payload {
                    msg: &[],
                    aad: &quick_unlock_aad(&new_vault_id),
                },
            )
            .map_err(|_| VaultError::Internal)?;
        transaction
            .execute(
                "UPDATE vault_meta
                 SET vault_id = ?1, wrapped_vault_key_nonce = ?2, wrapped_vault_key = ?3,
                     quick_unlock_nonce = ?4, quick_unlock_ciphertext = ?5
                 WHERE id = 1",
                params![
                    &new_vault_id[..],
                    &new_nonce[..],
                    &wrapped_key,
                    &quick_unlock_nonce[..],
                    &quick_unlock_ciphertext
                ],
            )
            .map_err(|_| VaultError::Storage)?;
        transaction.commit().map_err(|_| VaultError::Storage)?;
        self.vault_id = new_vault_id;
        self.vault_key = Zeroizing::new(new_vault_key);
        Ok(())
    }

    pub(crate) fn record_put_json(&self, json: &[u8]) -> Result<(), VaultError> {
        if json.is_empty() || json.len() > MAX_RECORD_JSON_LEN {
            return Err(VaultError::InvalidArgument);
        }
        let mut input: VaultItemInput =
            serde_json::from_slice(json).map_err(|_| VaultError::InvalidArgument)?;
        validate_record_input(&input)?;

        let is_update = input.id.is_some();
        let record_id = match input.id.as_deref() {
            Some(id) => parse_id(id)?,
            None => random_array::<VAULT_ID_LEN>()?,
        };
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|_| VaultError::Storage)?;
        let base_revision = if is_update {
            Some(
                transaction
                    .query_row(
                        "SELECT revision_id FROM records WHERE record_id = ?1 AND tombstone = 0",
                        [&record_id[..]],
                        |row| row.get::<_, Vec<u8>>(0),
                    )
                    .map_err(|error| match error {
                        rusqlite::Error::QueryReturnedNoRows => VaultError::NotFound,
                        _ => VaultError::Storage,
                    })?
                    .try_into()
                    .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
            )
        } else {
            None
        };
        let revision_id = random_array::<VAULT_ID_LEN>()?;
        let operation_id = random_array::<VAULT_ID_LEN>()?;
        let nonce = random_array::<NONCE_LEN>()?;
        let record = VaultItem {
            id: encode_id(&record_id),
            legacy_kind: None,
            title: std::mem::take(&mut input.title),
            website: std::mem::take(&mut input.website),
            username: std::mem::take(&mut input.username),
            password: std::mem::take(&mut input.password),
            totp_secret: std::mem::take(&mut input.totp_secret),
            totp_period: input.totp_period,
            totp_digits: input.totp_digits,
            totp_algorithm: std::mem::take(&mut input.totp_algorithm),
            passkeys: std::mem::take(&mut input.passkeys),
        };
        let plaintext =
            Zeroizing::new(serde_json::to_vec(&record).map_err(|_| VaultError::Internal)?);
        let ciphertext = self.encrypt_record(&record_id, &revision_id, &nonce, &plaintext)?;
        let (origin_device_id, origin_sequence) = advance_local_sequence(&transaction)?;
        let (operation_nonce, operation_ciphertext) = self.encrypt_operation(
            &operation_id,
            &record_id,
            &revision_id,
            &nonce,
            &ciphertext,
        )?;

        if is_update {
            let updated = transaction
                .execute(
                    "UPDATE records
                     SET revision_id = ?2, operation_id = ?3, tombstone = 0, nonce = ?4, ciphertext = ?5
                     WHERE record_id = ?1 AND tombstone = 0",
                    params![
                        &record_id[..],
                        &revision_id[..],
                        &operation_id[..],
                        &nonce[..],
                        &ciphertext
                    ],
                )
                .map_err(|_| VaultError::Storage)?;
            if updated == 0 {
                return Err(VaultError::NotFound);
            }
        } else {
            transaction
                .execute(
                    "INSERT INTO records (record_id, revision_id, operation_id, tombstone, nonce, ciphertext)
                     VALUES (?1, ?2, ?3, 0, ?4, ?5)",
                    params![
                        &record_id[..],
                        &revision_id[..],
                        &operation_id[..],
                        &nonce[..],
                        &ciphertext
                    ],
                )
                .map_err(|_| VaultError::Storage)?;
        }
        insert_operation(
            &transaction,
            &operation_id,
            &origin_device_id,
            origin_sequence,
            &record_id,
            base_revision.as_ref(),
            &revision_id,
            false,
            &operation_nonce,
            &operation_ciphertext,
        )?;
        transaction.commit().map_err(|_| VaultError::Storage)
    }

    pub(crate) fn record_list_json(&self) -> Result<Vec<u8>, VaultError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT record_id, revision_id, nonce, ciphertext
                 FROM records WHERE tombstone = 0 ORDER BY rowid",
            )
            .map_err(|_| VaultError::Storage)?;
        let rows = statement
            .query_map([], encrypted_record_from_row)
            .map_err(|_| VaultError::Storage)?;
        let mut summaries = Vec::new();
        for row in rows {
            let record = self.decrypt_record(row.map_err(|_| VaultError::Storage)?)?;
            summaries.push(VaultItemSummary {
                id: record.id.clone(),
                title: record.title.clone(),
                website: record.website.clone(),
                username: record.username.clone(),
                has_password: !record.password.is_empty(),
                has_totp: !record.totp_secret.is_empty(),
                has_passkey: !record.passkeys.is_empty(),
                passkey_count: record.passkeys.len(),
            });
        }
        serde_json::to_vec(&summaries).map_err(|_| VaultError::Internal)
    }

    pub(crate) fn record_get_json(&self, id: &str) -> Result<Vec<u8>, VaultError> {
        let record_id = parse_id(id)?;
        let encrypted = self
            .connection
            .query_row(
                "SELECT record_id, revision_id, nonce, ciphertext
                 FROM records WHERE record_id = ?1 AND tombstone = 0",
                [&record_id[..]],
                encrypted_record_from_row,
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => VaultError::NotFound,
                _ => VaultError::Storage,
            })?;
        let record = self.decrypt_record(encrypted)?;
        serde_json::to_vec(&record).map_err(|_| VaultError::Internal)
    }

    pub(crate) fn record_delete(&self, id: &str) -> Result<(), VaultError> {
        let record_id = parse_id(id)?;
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|_| VaultError::Storage)?;
        let base_revision: [u8; VAULT_ID_LEN] = transaction
            .query_row(
                "SELECT revision_id FROM records WHERE record_id = ?1 AND tombstone = 0",
                [&record_id[..]],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => VaultError::NotFound,
                _ => VaultError::Storage,
            })?
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let revision_id = random_array::<VAULT_ID_LEN>()?;
        let operation_id = random_array::<VAULT_ID_LEN>()?;
        let nonce = random_array::<NONCE_LEN>()?;
        let plaintext = Zeroizing::new(Vec::new());
        let ciphertext = self.encrypt_record(&record_id, &revision_id, &nonce, &plaintext)?;
        let (origin_device_id, origin_sequence) = advance_local_sequence(&transaction)?;
        let (operation_nonce, operation_ciphertext) = self.encrypt_operation(
            &operation_id,
            &record_id,
            &revision_id,
            &nonce,
            &ciphertext,
        )?;
        let updated = transaction
            .execute(
                "UPDATE records
                 SET revision_id = ?2, operation_id = ?3, tombstone = 1, nonce = ?4, ciphertext = ?5
                 WHERE record_id = ?1 AND tombstone = 0",
                params![
                    &record_id[..],
                    &revision_id[..],
                    &operation_id[..],
                    &nonce[..],
                    &ciphertext
                ],
            )
            .map_err(|_| VaultError::Storage)?;
        if updated == 0 {
            return Err(VaultError::NotFound);
        }
        insert_operation(
            &transaction,
            &operation_id,
            &origin_device_id,
            origin_sequence,
            &record_id,
            Some(&base_revision),
            &revision_id,
            true,
            &operation_nonce,
            &operation_ciphertext,
        )?;
        transaction.commit().map_err(|_| VaultError::Storage)
    }

    pub(crate) fn sync_state_json(&self) -> Result<Vec<u8>, VaultError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT origin_device_id, origin_sequence
                 FROM operations ORDER BY origin_device_id, origin_sequence",
            )
            .map_err(|_| VaultError::Storage)?;
        let mut rows = statement.query([]).map_err(|_| VaultError::Storage)?;
        let mut origins = HashMap::new();
        while let Some(row) = rows.next().map_err(|_| VaultError::Storage)? {
            let device: Vec<u8> = row.get(0).map_err(|_| VaultError::Storage)?;
            let sequence = u64::try_from(
                row.get::<_, i64>(1).map_err(|_| VaultError::Storage)?,
            )
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
            let key = encode_bytes(&device);
            let expected = origins.get(&key).copied().unwrap_or(0) + 1;
            if sequence == expected {
                origins.insert(key, sequence);
            }
        }
        serde_json::to_vec(&SyncState { origins }).map_err(|_| VaultError::Internal)
    }

    pub(crate) fn device_info_json(&self) -> Result<Vec<u8>, VaultError> {
        let device: Vec<u8> = self
            .connection
            .query_row(
                "SELECT local_device_id FROM vault_meta WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .map_err(|_| VaultError::Storage)?;
        serde_json::to_vec(&serde_json::json!({ "deviceId": encode_bytes(&device) }))
            .map_err(|_| VaultError::Internal)
    }

    pub(crate) fn sync_proof(&self, challenge: &[u8]) -> Result<Vec<u8>, VaultError> {
        let challenge: [u8; NONCE_LEN] = challenge
            .try_into()
            .map_err(|_| VaultError::InvalidArgument)?;
        XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::Internal)?
            .encrypt(
                &XNonce::from(challenge),
                Payload {
                    msg: &[],
                    aad: b"getfor:sync-proof:v1",
                },
            )
            .map_err(|_| VaultError::Internal)
    }

    pub(crate) fn sync_export_json(&self, peer_state_json: &[u8]) -> Result<Vec<u8>, VaultError> {
        if peer_state_json.is_empty() || peer_state_json.len() > MAX_RECORD_JSON_LEN {
            return Err(VaultError::InvalidArgument);
        }
        let peer: SyncState =
            serde_json::from_slice(peer_state_json).map_err(|_| VaultError::InvalidArgument)?;
        let mut statement = self
            .connection
            .prepare(
                "SELECT operation_id, origin_device_id, origin_sequence, record_id,
                        base_revision_id, new_revision_id, tombstone, nonce, ciphertext
                 FROM operations ORDER BY origin_device_id, origin_sequence",
            )
            .map_err(|_| VaultError::Storage)?;
        let rows = statement
            .query_map([], |row| {
                Ok(SyncOperation {
                    operation_id: encode_bytes(&row.get::<_, Vec<u8>>(0)?),
                    origin_device_id: encode_bytes(&row.get::<_, Vec<u8>>(1)?),
                    origin_sequence: u64::try_from(row.get::<_, i64>(2)?)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    record_id: encode_bytes(&row.get::<_, Vec<u8>>(3)?),
                    base_revision_id: row
                        .get::<_, Option<Vec<u8>>>(4)?
                        .map(|value| encode_bytes(&value)),
                    new_revision_id: encode_bytes(&row.get::<_, Vec<u8>>(5)?),
                    tombstone: row.get::<_, i64>(6)? != 0,
                    nonce: encode_bytes(&row.get::<_, Vec<u8>>(7)?),
                    ciphertext: encode_bytes(&row.get::<_, Vec<u8>>(8)?),
                })
            })
            .map_err(|_| VaultError::Storage)?;
        let mut operations = Vec::new();
        for operation in rows {
            let operation = operation.map_err(|_| VaultError::Storage)?;
            if operation.origin_sequence
                > peer
                    .origins
                    .get(&operation.origin_device_id)
                    .copied()
                    .unwrap_or(0)
            {
                operations.push(operation);
            }
        }
        serde_json::to_vec(&SyncBundle {
            vault_id: encode_id(&self.vault_id),
            operations,
        })
        .map_err(|_| VaultError::Internal)
    }

    pub(crate) fn sync_import_json(&self, bundle_json: &[u8]) -> Result<u64, VaultError> {
        if bundle_json.is_empty() || bundle_json.len() > 4 * 1024 * 1024 {
            return Err(VaultError::InvalidArgument);
        }
        let bundle: SyncBundle =
            serde_json::from_slice(bundle_json).map_err(|_| VaultError::InvalidArgument)?;
        if parse_id(&bundle.vault_id)? != self.vault_id {
            return Err(VaultError::InvalidArgument);
        }
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(|_| VaultError::Storage)?;
        let mut imported = 0_u64;
        for operation in bundle.operations {
            let operation_id = parse_id(&operation.operation_id)?;
            let origin_device_id = parse_id(&operation.origin_device_id)?;
            let record_id = parse_id(&operation.record_id)?;
            let base_revision_id = operation
                .base_revision_id
                .as_deref()
                .map(parse_id)
                .transpose()?;
            let new_revision_id = parse_id(&operation.new_revision_id)?;
            let operation_nonce: [u8; NONCE_LEN] = decode_bytes(&operation.nonce)?
                .try_into()
                .map_err(|_| VaultError::InvalidArgument)?;
            let operation_ciphertext = decode_bytes(&operation.ciphertext)?;
            if operation.origin_sequence == 0 {
                return Err(VaultError::InvalidArgument);
            }
            let exists = transaction
                .query_row(
                    "SELECT 1 FROM operations WHERE operation_id = ?1",
                    [&operation_id[..]],
                    |_| Ok(()),
                )
                .optional()
                .map_err(|_| VaultError::Storage)?
                .is_some();
            if exists {
                continue;
            }

            let payload = self.decrypt_operation(
                &operation_id,
                &record_id,
                &new_revision_id,
                &operation_nonce,
                &operation_ciphertext,
            )?;
            let record_nonce: [u8; NONCE_LEN] = decode_bytes(&payload.record_nonce)?
                .try_into()
                .map_err(|_| VaultError::InvalidArgument)?;
            let record_ciphertext = decode_bytes(&payload.record_ciphertext)?;
            self.decrypt_record_bytes(
                &record_id,
                &new_revision_id,
                &record_nonce,
                &record_ciphertext,
            )?;

            let current_revision = transaction
                .query_row(
                    "SELECT revision_id FROM records WHERE record_id = ?1",
                    [&record_id[..]],
                    |row| row.get::<_, Vec<u8>>(0),
                )
                .optional()
                .map_err(|_| VaultError::Storage)?;
            let applies = match (&current_revision, &base_revision_id) {
                (None, None) => true,
                (Some(current), Some(base)) => current.as_slice() == base,
                _ => false,
            };
            if applies {
                transaction
                    .execute(
                        "INSERT INTO records
                            (record_id, revision_id, operation_id, tombstone, nonce, ciphertext)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                         ON CONFLICT(record_id) DO UPDATE SET
                            revision_id = excluded.revision_id,
                            operation_id = excluded.operation_id,
                            tombstone = excluded.tombstone,
                            nonce = excluded.nonce,
                            ciphertext = excluded.ciphertext",
                        params![
                            &record_id[..],
                            &new_revision_id[..],
                            &operation_id[..],
                            i64::from(operation.tombstone),
                            &record_nonce[..],
                            &record_ciphertext
                        ],
                    )
                    .map_err(|_| VaultError::Storage)?;
            } else if !operation.tombstone {
                self.insert_conflict_copy(
                    &transaction,
                    &record_id,
                    &new_revision_id,
                    &record_nonce,
                    &record_ciphertext,
                )?;
            }
            insert_operation(
                &transaction,
                &operation_id,
                &origin_device_id,
                operation.origin_sequence,
                &record_id,
                base_revision_id.as_ref(),
                &new_revision_id,
                operation.tombstone,
                &operation_nonce,
                &operation_ciphertext,
            )?;
            transaction
                .execute(
                    "INSERT OR IGNORE INTO devices
                        (device_id, public_key, encrypted_display_name, status, added_at)
                     VALUES (?1, X'', X'', 'active', strftime('%s','now'))",
                    [&origin_device_id[..]],
                )
                .map_err(|_| VaultError::Storage)?;
            imported += 1;
        }
        transaction.commit().map_err(|_| VaultError::Storage)?;
        Ok(imported)
    }

    fn decrypt_operation(
        &self,
        operation_id: &[u8; VAULT_ID_LEN],
        record_id: &[u8; VAULT_ID_LEN],
        revision_id: &[u8; VAULT_ID_LEN],
        nonce: &[u8; NONCE_LEN],
        ciphertext: &[u8],
    ) -> Result<OperationPayload, VaultError> {
        let cipher = XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    &XNonce::from(*nonce),
                    Payload {
                        msg: ciphertext,
                        aad: &operation_aad(
                            &self.vault_id,
                            operation_id,
                            record_id,
                            revision_id,
                        ),
                    },
                )
                .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
        );
        serde_json::from_slice(&plaintext).map_err(|_| VaultError::InvalidCredentialsOrCorrupt)
    }

    fn decrypt_record_bytes(
        &self,
        record_id: &[u8; VAULT_ID_LEN],
        revision_id: &[u8; VAULT_ID_LEN],
        nonce: &[u8; NONCE_LEN],
        ciphertext: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, VaultError> {
        let cipher = XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        cipher
            .decrypt(
                &XNonce::from(*nonce),
                Payload {
                    msg: ciphertext,
                    aad: &record_aad(&self.vault_id, record_id, revision_id),
                },
            )
            .map(Zeroizing::new)
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)
    }

    fn insert_conflict_copy(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        remote_record_id: &[u8; VAULT_ID_LEN],
        remote_revision_id: &[u8; VAULT_ID_LEN],
        remote_nonce: &[u8; NONCE_LEN],
        remote_ciphertext: &[u8],
    ) -> Result<(), VaultError> {
        let plaintext = self.decrypt_record_bytes(
            remote_record_id,
            remote_revision_id,
            remote_nonce,
            remote_ciphertext,
        )?;
        let mut record: VaultItem = serde_json::from_slice(&plaintext)
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let record_id = random_array::<VAULT_ID_LEN>()?;
        let revision_id = random_array::<VAULT_ID_LEN>()?;
        let operation_id = random_array::<VAULT_ID_LEN>()?;
        record.id = encode_id(&record_id);
        record.title.push_str(" (冲突副本)");
        let plaintext = Zeroizing::new(serde_json::to_vec(&record).map_err(|_| VaultError::Internal)?);
        let nonce = random_array::<NONCE_LEN>()?;
        let ciphertext = self.encrypt_record(&record_id, &revision_id, &nonce, &plaintext)?;
        let (origin_device_id, origin_sequence) = advance_local_sequence(transaction)?;
        let (operation_nonce, operation_ciphertext) = self.encrypt_operation(
            &operation_id,
            &record_id,
            &revision_id,
            &nonce,
            &ciphertext,
        )?;
        transaction
            .execute(
                "INSERT INTO records
                    (record_id, revision_id, operation_id, tombstone, nonce, ciphertext)
                 VALUES (?1, ?2, ?3, 0, ?4, ?5)",
                params![
                    &record_id[..],
                    &revision_id[..],
                    &operation_id[..],
                    &nonce[..],
                    &ciphertext
                ],
            )
            .map_err(|_| VaultError::Storage)?;
        insert_operation(
            transaction,
            &operation_id,
            &origin_device_id,
            origin_sequence,
            &record_id,
            None,
            &revision_id,
            false,
            &operation_nonce,
            &operation_ciphertext,
        )
    }

    fn encrypt_operation(
        &self,
        operation_id: &[u8; VAULT_ID_LEN],
        record_id: &[u8; VAULT_ID_LEN],
        revision_id: &[u8; VAULT_ID_LEN],
        record_nonce: &[u8; NONCE_LEN],
        record_ciphertext: &[u8],
    ) -> Result<([u8; NONCE_LEN], Vec<u8>), VaultError> {
        let plaintext = Zeroizing::new(
            serde_json::to_vec(&OperationPayload {
                record_nonce: encode_bytes(record_nonce),
                record_ciphertext: encode_bytes(record_ciphertext),
            })
            .map_err(|_| VaultError::Internal)?,
        );
        let nonce = random_array::<NONCE_LEN>()?;
        let cipher = XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::Internal)?;
        let ciphertext = cipher
            .encrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: &plaintext,
                    aad: &operation_aad(
                        &self.vault_id,
                        operation_id,
                        record_id,
                        revision_id,
                    ),
                },
            )
            .map_err(|_| VaultError::Internal)?;
        Ok((nonce, ciphertext))
    }

    fn encrypt_record(
        &self,
        record_id: &[u8; VAULT_ID_LEN],
        revision_id: &[u8; VAULT_ID_LEN],
        nonce: &[u8; NONCE_LEN],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, VaultError> {
        let cipher = XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::Internal)?;
        cipher
            .encrypt(
                &XNonce::from(*nonce),
                Payload {
                    msg: plaintext,
                    aad: &record_aad(&self.vault_id, record_id, revision_id),
                },
            )
            .map_err(|_| VaultError::Internal)
    }

    fn decrypt_record(&self, encrypted: EncryptedRecord) -> Result<VaultItem, VaultError> {
        let record_id: [u8; VAULT_ID_LEN] = encrypted
            .record_id
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let revision_id: [u8; VAULT_ID_LEN] = encrypted
            .revision_id
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let nonce: [u8; NONCE_LEN] = encrypted
            .nonce
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let cipher = XChaCha20Poly1305::new_from_slice(self.vault_key.as_ref())
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    &XNonce::from(nonce),
                    Payload {
                        msg: &encrypted.ciphertext,
                        aad: &record_aad(&self.vault_id, &record_id, &revision_id),
                    },
                )
                .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
        );
        let mut record: VaultItem = serde_json::from_slice(&plaintext)
            .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
        if record.id != encode_id(&record_id) {
            return Err(VaultError::InvalidCredentialsOrCorrupt);
        }
        // Records created by the short-lived typed model stored a TOTP secret in password.
        if record.legacy_kind.as_deref() == Some("totp") && record.totp_secret.is_empty() {
            record.totp_secret = std::mem::take(&mut record.password);
        }
        record.legacy_kind = None;
        Ok(record)
    }
}

fn validate_record_input(input: &VaultItemInput) -> Result<(), VaultError> {
    let has_totp = !input.totp_secret.is_empty();
    let has_passkey = !input.passkeys.is_empty();
    if input.title.is_empty()
        || input.title.len() > 512
        || input.website.len() > 2048
        || input.username.len() > 1024
        || input.password.len() > 64 * 1024
        || input.totp_secret.len() > 64 * 1024
        || (input.password.is_empty() && !has_totp && !has_passkey)
        || (has_totp
            && (input.totp_period == 0
                || !(6..=8).contains(&input.totp_digits)
                || !matches!(input.totp_algorithm.as_str(), "sha1" | "sha256" | "sha512")
                || !input
                    .totp_secret
                    .bytes()
                    .all(|byte| matches!(byte, b'A'..=b'Z' | b'2'..=b'7'))))
    {
        return Err(VaultError::InvalidArgument);
    }
    let mut credential_ids = std::collections::HashSet::new();
    for passkey in &input.passkeys {
        let credential_id = decode_passkey_value(&passkey.credential_id, 16, 1024)?;
        let user_handle = decode_passkey_value(&passkey.user_handle, 1, 64)?;
        let private_key = decode_passkey_value(&passkey.private_key_pkcs8, 64, 2048)?;
        if !credential_ids.insert(passkey.credential_id.as_str())
            || !valid_relying_party_id(&passkey.relying_party_id)
            || passkey.user_name.is_empty()
            || passkey.user_name.len() > 1024
            || passkey.user_display_name.len() > 1024
            || !passkey.backup_eligible
            || credential_id.iter().all(|byte| *byte == 0)
            || user_handle.iter().all(|byte| *byte == 0)
            || private_key.iter().all(|byte| *byte == 0)
        {
            return Err(VaultError::InvalidArgument);
        }
    }
    Ok(())
}

fn decode_passkey_value(value: &str, minimum: usize, maximum: usize) -> Result<Vec<u8>, VaultError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| VaultError::InvalidArgument)?;
    if !(minimum..=maximum).contains(&decoded.len()) {
        return Err(VaultError::InvalidArgument);
    }
    Ok(decoded)
}

fn valid_relying_party_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 253
        && value.is_ascii()
        && !value.contains("..")
        && value.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
}

fn default_true() -> bool {
    true
}

fn default_totp_period() -> u16 {
    30
}

fn default_totp_digits() -> u16 {
    6
}

fn default_totp_algorithm() -> String {
    "sha1".to_owned()
}

fn encrypted_record_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<EncryptedRecord> {
    Ok(EncryptedRecord {
        record_id: row.get(0)?,
        revision_id: row.get(1)?,
        nonce: row.get(2)?,
        ciphertext: row.get(3)?,
    })
}

fn validate_create_input(path: &Path, password: &[u8]) -> Result<(), VaultError> {
    if path.as_os_str().is_empty() {
        return Err(VaultError::InvalidArgument);
    }
    if path.exists() {
        return Err(VaultError::AlreadyExists);
    }
    validate_password(password)
}

fn validate_password(password: &[u8]) -> Result<(), VaultError> {
    if password.len() < MIN_PASSWORD_LEN || password.len() > MAX_PASSWORD_LEN {
        return Err(VaultError::InvalidArgument);
    }
    Ok(())
}

fn open_existing(path: &Path) -> Result<Connection, VaultError> {
    // SQLite's NOFOLLOW VFS flag is not portable across all bundled targets.
    // Reject links here so a vault path cannot redirect to an unrelated file.
    if std::fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(VaultError::Storage);
    }
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| VaultError::Storage)
}

fn derive_key(
    password: &[u8],
    salt: &[u8],
    parameters: KdfParams,
) -> Result<Zeroizing<[u8; KEY_LEN]>, VaultError> {
    let parameters = parameters.validate()?;
    let argon_params = Params::new(
        parameters.memory_kib,
        parameters.iterations,
        parameters.parallelism,
        Some(KEY_LEN),
    )
    .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, argon_params);
    let mut output = Zeroizing::new([0_u8; KEY_LEN]);
    argon
        .hash_password_into(password, salt, output.as_mut())
        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
    Ok(output)
}

fn read_header(connection: &Connection) -> Result<VaultHeader, VaultError> {
    connection
        .query_row(
            "SELECT vault_id, format_version, kdf_salt, kdf_memory_kib,
                    kdf_iterations, kdf_parallelism, wrapped_vault_key_nonce,
                    wrapped_vault_key
             FROM vault_meta
             WHERE id = 1
               AND length(vault_id) = 16
               AND length(kdf_salt) = 16
               AND length(wrapped_vault_key_nonce) = 24
               AND length(wrapped_vault_key) = 48",
            [],
            |row| {
                Ok(VaultHeader {
                    vault_id: row.get(0)?,
                    format_version: row.get(1)?,
                    kdf_salt: row.get(2)?,
                    kdf: KdfParams {
                        memory_kib: row.get(3)?,
                        iterations: row.get(4)?,
                        parallelism: row.get(5)?,
                    },
                    nonce: row.get(6)?,
                    wrapped_key: row.get(7)?,
                })
            },
        )
        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)
}

fn validate_header(header: &VaultHeader) -> Result<(), VaultError> {
    if header.format_version != FORMAT_VERSION
        || header.vault_id.len() != VAULT_ID_LEN
        || header.kdf_salt.len() != SALT_LEN
        || header.nonce.len() != NONCE_LEN
        || header.wrapped_key.len() != WRAPPED_KEY_LEN
    {
        return Err(VaultError::InvalidCredentialsOrCorrupt);
    }
    header.kdf.validate()?;
    Ok(())
}

fn vault_key_aad(vault_id: &[u8; VAULT_ID_LEN], format_version: u32) -> Vec<u8> {
    let mut aad = Vec::with_capacity(21 + VAULT_ID_LEN);
    aad.extend_from_slice(b"getfor:vault-key:");
    aad.extend_from_slice(&format_version.to_be_bytes());
    aad.extend_from_slice(vault_id);
    aad
}

fn quick_unlock_aad(vault_id: &[u8; VAULT_ID_LEN]) -> Vec<u8> {
    let mut aad = b"getfor:quick-unlock:".to_vec();
    aad.extend_from_slice(vault_id);
    aad
}

fn record_aad(
    vault_id: &[u8; VAULT_ID_LEN],
    record_id: &[u8; VAULT_ID_LEN],
    revision_id: &[u8; VAULT_ID_LEN],
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(18 + 4 + VAULT_ID_LEN * 3);
    aad.extend_from_slice(b"getfor:record:");
    aad.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    aad.extend_from_slice(vault_id);
    aad.extend_from_slice(record_id);
    aad.extend_from_slice(revision_id);
    aad
}

fn operation_aad(
    vault_id: &[u8; VAULT_ID_LEN],
    operation_id: &[u8; VAULT_ID_LEN],
    record_id: &[u8; VAULT_ID_LEN],
    revision_id: &[u8; VAULT_ID_LEN],
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(21 + VAULT_ID_LEN * 4);
    aad.extend_from_slice(b"getfor:operation:");
    aad.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    aad.extend_from_slice(vault_id);
    aad.extend_from_slice(operation_id);
    aad.extend_from_slice(record_id);
    aad.extend_from_slice(revision_id);
    aad
}

fn advance_local_sequence(
    transaction: &rusqlite::Transaction<'_>,
) -> Result<([u8; VAULT_ID_LEN], u64), VaultError> {
    let (device, current): (Vec<u8>, i64) = transaction
        .query_row(
            "SELECT local_device_id, origin_sequence FROM vault_meta WHERE id = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|_| VaultError::Storage)?;
    let device = device
        .try_into()
        .map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?;
    let next = current.checked_add(1).ok_or(VaultError::Storage)?;
    let updated = transaction
        .execute(
            "UPDATE vault_meta SET origin_sequence = ?1 WHERE id = 1 AND origin_sequence = ?2",
            params![next, current],
        )
        .map_err(|_| VaultError::Storage)?;
    if updated != 1 {
        return Err(VaultError::Storage);
    }
    Ok((
        device,
        u64::try_from(next).map_err(|_| VaultError::InvalidCredentialsOrCorrupt)?,
    ))
}

#[allow(clippy::too_many_arguments)]
fn insert_operation(
    transaction: &rusqlite::Transaction<'_>,
    operation_id: &[u8; VAULT_ID_LEN],
    origin_device_id: &[u8; VAULT_ID_LEN],
    origin_sequence: u64,
    record_id: &[u8; VAULT_ID_LEN],
    base_revision_id: Option<&[u8; VAULT_ID_LEN]>,
    new_revision_id: &[u8; VAULT_ID_LEN],
    tombstone: bool,
    nonce: &[u8; NONCE_LEN],
    ciphertext: &[u8],
) -> Result<(), VaultError> {
    transaction
        .execute(
            "INSERT INTO operations
                (operation_id, origin_device_id, origin_sequence, record_id,
                 base_revision_id, new_revision_id, tombstone, nonce, ciphertext)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                &operation_id[..],
                &origin_device_id[..],
                i64::try_from(origin_sequence).map_err(|_| VaultError::Storage)?,
                &record_id[..],
                base_revision_id.map(|value| &value[..]),
                &new_revision_id[..],
                i64::from(tombstone),
                &nonce[..],
                ciphertext
            ],
        )
        .map_err(|_| VaultError::Storage)?;
    Ok(())
}

fn encode_id(id: &[u8; VAULT_ID_LEN]) -> String {
    encode_bytes(id)
}

fn encode_bytes(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

fn parse_id(id: &str) -> Result<[u8; VAULT_ID_LEN], VaultError> {
    if id.len() != VAULT_ID_LEN * 2 {
        return Err(VaultError::InvalidArgument);
    }
    let bytes = id.as_bytes();
    let mut decoded = [0_u8; VAULT_ID_LEN];
    for (index, byte) in decoded.iter_mut().enumerate() {
        let high = decode_hex(bytes[index * 2])?;
        let low = decode_hex(bytes[index * 2 + 1])?;
        *byte = (high << 4) | low;
    }
    Ok(decoded)
}

fn decode_bytes(value: &str) -> Result<Vec<u8>, VaultError> {
    if value.len() % 2 != 0 || value.len() > 8 * 1024 * 1024 {
        return Err(VaultError::InvalidArgument);
    }
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        decoded.push((decode_hex(pair[0])? << 4) | decode_hex(pair[1])?);
    }
    Ok(decoded)
}

fn decode_hex(byte: u8) -> Result<u8, VaultError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        _ => Err(VaultError::InvalidArgument),
    }
}

fn random_array<const N: usize>() -> Result<[u8; N], VaultError> {
    let mut bytes = [0_u8; N];
    getrandom::fill(&mut bytes).map_err(|_| VaultError::Internal)?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSWORD: &[u8] = b"correct horse battery staple";

    #[test]
    fn create_open_and_reject_duplicate() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");

        drop(Vault::create(&path, PASSWORD).unwrap());
        let database = std::fs::read(&path).unwrap();
        assert!(
            !database
                .windows(PASSWORD.len())
                .any(|bytes| bytes == PASSWORD)
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        drop(Vault::open(&path, PASSWORD).unwrap());
        assert_eq!(
            Vault::create(&path, PASSWORD).err(),
            Some(VaultError::AlreadyExists)
        );
    }

    #[test]
    fn changes_only_the_password_wrapping_key() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        let vault = Vault::create(&path, PASSWORD).unwrap();
        vault
            .record_put_json(br#"{"title":"Example","password":"record-secret"}"#)
            .unwrap();

        assert_eq!(
            vault.change_password(b"incorrect password", b"new secure password"),
            Err(VaultError::InvalidCredentialsOrCorrupt)
        );
        vault
            .change_password(PASSWORD, b"new secure password")
            .unwrap();
        drop(vault);

        assert_eq!(
            Vault::open(&path, PASSWORD).err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );
        let reopened = Vault::open(&path, b"new secure password").unwrap();
        let items: serde_json::Value =
            serde_json::from_slice(&reopened.record_list_json().unwrap()).unwrap();
        let id = items[0]["id"].as_str().unwrap();
        let item: serde_json::Value =
            serde_json::from_slice(&reopened.record_get_json(id).unwrap()).unwrap();
        assert_eq!(item["password"], "record-secret");
    }

    #[test]
    fn wrong_password_and_tampering_have_the_same_error() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        drop(Vault::create(&path, PASSWORD).unwrap());

        assert_eq!(
            Vault::open(&path, b"wrong password").err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );

        let connection = open_existing(&path).unwrap();
        connection
            .execute(
                "UPDATE vault_meta SET wrapped_vault_key = randomblob(48) WHERE id = 1",
                [],
            )
            .unwrap();
        drop(connection);
        assert_eq!(
            Vault::open(&path, PASSWORD).err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );
    }

    #[test]
    fn rejects_malformed_nonce_and_hostile_kdf_before_decryption() {
        let directory = tempfile::tempdir().unwrap();
        let nonce_path = directory.path().join("nonce.db");
        drop(Vault::create(&nonce_path, PASSWORD).unwrap());
        let connection = open_existing(&nonce_path).unwrap();
        connection
            .execute_batch("PRAGMA ignore_check_constraints = ON")
            .unwrap();
        connection
            .execute(
                "UPDATE vault_meta SET wrapped_vault_key_nonce = zeroblob(23) WHERE id = 1",
                [],
            )
            .unwrap();
        drop(connection);
        assert_eq!(
            Vault::open(&nonce_path, PASSWORD).err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );

        let kdf_path = directory.path().join("kdf.db");
        drop(Vault::create(&kdf_path, PASSWORD).unwrap());
        let connection = open_existing(&kdf_path).unwrap();
        connection
            .execute_batch("PRAGMA ignore_check_constraints = ON")
            .unwrap();
        connection
            .execute(
                "UPDATE vault_meta SET kdf_memory_kib = ?1 WHERE id = 1",
                [MAX_MEMORY_KIB + 1],
            )
            .unwrap();
        drop(connection);
        assert_eq!(
            Vault::open(&kdf_path, PASSWORD).err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );
    }

    #[test]
    fn vault_id_is_bound_as_aad() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        drop(Vault::create(&path, PASSWORD).unwrap());
        let connection = open_existing(&path).unwrap();
        connection
            .execute(
                "UPDATE vault_meta SET vault_id = randomblob(16) WHERE id = 1",
                [],
            )
            .unwrap();
        drop(connection);

        assert_eq!(
            Vault::open(&path, PASSWORD).err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );
    }

    #[test]
    fn encrypted_record_crud_and_tombstone() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        let vault = Vault::create(&path, PASSWORD).unwrap();
        vault
            .record_put_json(
                br#"{"title":"Example","website":"https://example.com","username":"alice","password":"unique-secret-123","totpSecret":"JBSWY3DPEHPK3PXP"}"#,
            )
            .unwrap();

        let database = std::fs::read(&path).unwrap();
        assert!(!database.windows(7).any(|bytes| bytes == b"Example"));
        assert!(
            !database
                .windows(17)
                .any(|bytes| bytes == b"unique-secret-123")
        );

        let summaries: serde_json::Value =
            serde_json::from_slice(&vault.record_list_json().unwrap()).unwrap();
        let id = summaries[0]["id"].as_str().unwrap();
        assert_eq!(summaries[0]["title"], "Example");
        assert_eq!(summaries[0]["hasPassword"], true);
        assert_eq!(summaries[0]["hasTotp"], true);
        assert!(summaries[0].get("password").is_none());

        let full: serde_json::Value =
            serde_json::from_slice(&vault.record_get_json(id).unwrap()).unwrap();
        assert_eq!(full["password"], "unique-secret-123");
        assert_eq!(full["totpSecret"], "JBSWY3DPEHPK3PXP");

        let updated = format!(
            r#"{{"id":"{id}","title":"Updated","website":"","username":"alice","password":"new-secret"}}"#
        );
        vault.record_put_json(updated.as_bytes()).unwrap();
        let full: serde_json::Value =
            serde_json::from_slice(&vault.record_get_json(id).unwrap()).unwrap();
        assert_eq!(full["title"], "Updated");
        assert_eq!(full["password"], "new-secret");

        vault.record_delete(id).unwrap();
        assert_eq!(vault.record_list_json().unwrap(), b"[]");
        assert_eq!(vault.record_get_json(id).unwrap_err(), VaultError::NotFound);
    }

    #[test]
    fn passkey_only_record_is_encrypted_and_survives_sync() {
        let directory = tempfile::tempdir().unwrap();
        let first_path = directory.path().join("first.db");
        let second_path = directory.path().join("second.db");
        drop(Vault::create(&first_path, PASSWORD).unwrap());
        std::fs::copy(&first_path, &second_path).unwrap();
        let first = Vault::open(&first_path, PASSWORD).unwrap();
        let second = Vault::open(&second_path, PASSWORD).unwrap();
        second
            .connection
            .execute(
                "UPDATE vault_meta SET local_device_id = randomblob(16), origin_sequence = 0",
                [],
            )
            .unwrap();

        let passkey = serde_json::json!({
            "credentialId": URL_SAFE_NO_PAD.encode([1_u8; 32]),
            "relyingPartyId": "example.com",
            "userHandle": URL_SAFE_NO_PAD.encode([2_u8; 16]),
            "userName": "alice",
            "userDisplayName": "Alice",
            "privateKeyPkcs8": URL_SAFE_NO_PAD.encode([3_u8; 96]),
            "backupEligible": true,
            "backupState": false,
        });
        let input = serde_json::to_vec(&serde_json::json!({
            "title": "Example passkey",
            "website": "https://example.com",
            "username": "alice",
            "passkeys": [passkey],
        }))
        .unwrap();
        first.record_put_json(&input).unwrap();

        let summary: serde_json::Value =
            serde_json::from_slice(&first.record_list_json().unwrap()).unwrap();
        assert_eq!(summary[0]["hasPassword"], false);
        assert_eq!(summary[0]["hasPasskey"], true);
        assert_eq!(summary[0]["passkeyCount"], 1);
        let bundle = first.sync_export_json(&second.sync_state_json().unwrap()).unwrap();
        assert_eq!(second.sync_import_json(&bundle).unwrap(), 1);
        let synced: serde_json::Value =
            serde_json::from_slice(&second.record_list_json().unwrap()).unwrap();
        let record = second
            .record_get_json(synced[0]["id"].as_str().unwrap())
            .unwrap();
        let record: serde_json::Value = serde_json::from_slice(&record).unwrap();
        assert_eq!(record["passkeys"][0]["relyingPartyId"], "example.com");
    }

    #[test]
    fn record_ciphertext_is_bound_to_its_revision() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        let vault = Vault::create(&path, PASSWORD).unwrap();
        vault
            .record_put_json(br#"{"title":"Example","password":"secret"}"#)
            .unwrap();
        let summaries: serde_json::Value =
            serde_json::from_slice(&vault.record_list_json().unwrap()).unwrap();
        let id = summaries[0]["id"].as_str().unwrap();
        vault
            .connection
            .execute("UPDATE records SET revision_id = randomblob(16)", [])
            .unwrap();
        assert_eq!(
            vault.record_get_json(id).unwrap_err(),
            VaultError::InvalidCredentialsOrCorrupt
        );
    }

    #[test]
    fn sync_is_idempotent_and_preserves_concurrent_edits() {
        let directory = tempfile::tempdir().unwrap();
        let first_path = directory.path().join("first.db");
        let second_path = directory.path().join("second.db");
        drop(Vault::create(&first_path, PASSWORD).unwrap());
        std::fs::copy(&first_path, &second_path).unwrap();

        let first = Vault::open(&first_path, PASSWORD).unwrap();
        let second = Vault::open(&second_path, PASSWORD).unwrap();
        second
            .connection
            .execute(
                "UPDATE vault_meta SET local_device_id = randomblob(16), origin_sequence = 0",
                [],
            )
            .unwrap();

        first
            .record_put_json(br#"{"title":"Example","password":"one"}"#)
            .unwrap();
        let bundle = first.sync_export_json(&second.sync_state_json().unwrap()).unwrap();
        assert_eq!(second.sync_import_json(&bundle).unwrap(), 1);
        assert_eq!(second.sync_import_json(&bundle).unwrap(), 0);

        let summaries: serde_json::Value =
            serde_json::from_slice(&first.record_list_json().unwrap()).unwrap();
        let id = summaries[0]["id"].as_str().unwrap();
        first
            .record_put_json(
                format!(r#"{{"id":"{id}","title":"First","password":"one"}}"#).as_bytes(),
            )
            .unwrap();
        second
            .record_put_json(
                format!(r#"{{"id":"{id}","title":"Second","password":"two"}}"#).as_bytes(),
            )
            .unwrap();

        let bundle = first.sync_export_json(&second.sync_state_json().unwrap()).unwrap();
        assert_eq!(second.sync_import_json(&bundle).unwrap(), 1);
        let summaries: serde_json::Value =
            serde_json::from_slice(&second.record_list_json().unwrap()).unwrap();
        assert_eq!(summaries.as_array().unwrap().len(), 2);
        assert!(summaries
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["title"] == "First (冲突副本)"));
    }

    #[test]
    fn pairing_joins_only_an_empty_vault_and_keeps_its_master_password() {
        let directory = tempfile::tempdir().unwrap();
        let source_path = directory.path().join("source.db");
        let target_path = directory.path().join("target.db");
        let source = Vault::create(&source_path, PASSWORD).unwrap();
        source
            .record_put_json(br#"{"title":"Example","password":"secret"}"#)
            .unwrap();
        let offer = source.pairing_offer_json().unwrap();

        let target_password = b"different target password";
        let mut target = Vault::create(&target_path, target_password).unwrap();
        target
            .pairing_accept_json(&offer, target_password)
            .unwrap();
        let bundle = source.sync_export_json(&target.sync_state_json().unwrap()).unwrap();
        assert_eq!(target.sync_import_json(&bundle).unwrap(), 1);
        drop(target);
        assert!(Vault::open(&target_path, target_password).is_ok());

        let mut non_empty = Vault::open(&target_path, target_password).unwrap();
        assert_eq!(
            non_empty.pairing_accept_json(&offer, target_password),
            Err(VaultError::AlreadyExists)
        );
    }

    #[test]
    fn quick_unlock_accepts_only_the_bound_vault_key() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        let vault = Vault::create(&path, PASSWORD).unwrap();
        let key = vault.quick_unlock_key();
        drop(vault);
        assert!(Vault::open_with_key(&path, &key).is_ok());
        assert_eq!(
            Vault::open_with_key(&path, &[0_u8; KEY_LEN]).err(),
            Some(VaultError::InvalidCredentialsOrCorrupt)
        );
    }

    #[test]
    fn opening_v1_vault_migrates_without_losing_records() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        let vault = Vault::create(&path, PASSWORD).unwrap();
        vault
            .record_put_json(br#"{"title":"Legacy","password":"secret"}"#)
            .unwrap();
        drop(vault);

        let connection = open_existing(&path).unwrap();
        connection
            .execute_batch(
                "BEGIN;
                 CREATE TABLE vault_meta_v1 (
                     id INTEGER PRIMARY KEY CHECK (id = 1),
                     vault_id BLOB NOT NULL CHECK (length(vault_id) = 16),
                     format_version INTEGER NOT NULL,
                     kdf_salt BLOB NOT NULL CHECK (length(kdf_salt) = 16),
                     kdf_memory_kib INTEGER NOT NULL,
                     kdf_iterations INTEGER NOT NULL,
                     kdf_parallelism INTEGER NOT NULL,
                     wrapped_vault_key_nonce BLOB NOT NULL CHECK (length(wrapped_vault_key_nonce) = 24),
                     wrapped_vault_key BLOB NOT NULL CHECK (length(wrapped_vault_key) = 48)
                 ) STRICT;
                 INSERT INTO vault_meta_v1 SELECT
                     id, vault_id, format_version, kdf_salt, kdf_memory_kib,
                     kdf_iterations, kdf_parallelism, wrapped_vault_key_nonce,
                     wrapped_vault_key FROM vault_meta;
                 CREATE TABLE records_v1 (
                     record_id BLOB PRIMARY KEY CHECK (length(record_id) = 16),
                     revision_id BLOB NOT NULL CHECK (length(revision_id) = 16),
                     tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
                     nonce BLOB NOT NULL CHECK (length(nonce) = 24),
                     ciphertext BLOB NOT NULL
                 ) STRICT;
                 INSERT INTO records_v1 SELECT
                     record_id, revision_id, tombstone, nonce, ciphertext FROM records;
                 DROP TABLE operations;
                 DROP TABLE devices;
                 DROP TABLE records;
                 DROP TABLE vault_meta;
                 ALTER TABLE records_v1 RENAME TO records;
                 ALTER TABLE vault_meta_v1 RENAME TO vault_meta;
                 PRAGMA user_version = 1;
                 COMMIT;",
            )
            .unwrap();
        drop(connection);

        let reopened = Vault::open(&path, PASSWORD).unwrap();
        assert_eq!(
            reopened
                .connection
                .query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))
                .unwrap(),
            2
        );
        let items: serde_json::Value =
            serde_json::from_slice(&reopened.record_list_json().unwrap()).unwrap();
        assert_eq!(items[0]["title"], "Legacy");
        assert_eq!(
            reopened
                .connection
                .query_row("SELECT count(*) FROM operations", [], |row| row.get::<_, u32>(0))
                .unwrap(),
            1
        );
        let key = reopened.quick_unlock_key();
        drop(reopened);
        assert!(Vault::open_with_key(&path, &key).is_ok());
    }
}
