#ifndef GETFOR_CORE_H
#define GETFOR_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GetforVault GetforVault;

typedef enum GetforStatus {
    GETFOR_OK = 0,
    GETFOR_INVALID_ARGUMENT = 1,
    GETFOR_ALREADY_EXISTS = 2,
    GETFOR_INVALID_CREDENTIALS_OR_CORRUPT = 3,
    GETFOR_STORAGE_ERROR = 4,
    GETFOR_INTERNAL_ERROR = 5,
    GETFOR_NOT_FOUND = 6
} GetforStatus;

uint32_t getfor_core_abi_version(void);

GetforStatus getfor_tls_identity_create(uint8_t **out_data, size_t *out_len);

GetforStatus getfor_vault_create(
    const uint8_t *path,
    size_t path_len,
    const uint8_t *password,
    size_t password_len,
    GetforVault **out_vault
);

GetforStatus getfor_vault_open(
    const uint8_t *path,
    size_t path_len,
    const uint8_t *password,
    size_t password_len,
    GetforVault **out_vault
);

GetforStatus getfor_vault_open_with_key(
    const uint8_t *path,
    size_t path_len,
    const uint8_t *key,
    size_t key_len,
    GetforVault **out_vault
);

GetforStatus getfor_vault_quick_unlock_key(
    GetforVault *vault,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_vault_change_password(
    GetforVault *vault,
    const uint8_t *current_password,
    size_t current_password_len,
    const uint8_t *new_password,
    size_t new_password_len
);

/* Each non-null handle must be locked exactly once. */
GetforStatus getfor_vault_lock(GetforVault *vault);

GetforStatus getfor_record_list(
    GetforVault *vault,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_record_get(
    GetforVault *vault,
    const uint8_t *id,
    size_t id_len,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_record_put(
    GetforVault *vault,
    const uint8_t *json,
    size_t json_len
);

GetforStatus getfor_record_delete(
    GetforVault *vault,
    const uint8_t *id,
    size_t id_len
);

GetforStatus getfor_sync_state(
    GetforVault *vault,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_device_info(
    GetforVault *vault,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_sync_proof(
    GetforVault *vault,
    const uint8_t *challenge,
    size_t challenge_len,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_sync_export(
    GetforVault *vault,
    const uint8_t *peer_state,
    size_t peer_state_len,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_sync_import(
    GetforVault *vault,
    const uint8_t *bundle,
    size_t bundle_len,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_pairing_offer_create(
    GetforVault *vault,
    uint8_t **out_data,
    size_t *out_len
);

GetforStatus getfor_pairing_accept(
    GetforVault *vault,
    const uint8_t *offer,
    size_t offer_len,
    const uint8_t *password,
    size_t password_len
);

/* Free each non-null output buffer exactly once. */
GetforStatus getfor_bytes_free(uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif
