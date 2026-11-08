use std::{ffi::c_void, path::Path, ptr, slice, str};

use zeroize::Zeroize;

use crate::vault::{MAX_PASSWORD_LEN, MAX_RECORD_JSON_LEN, Vault, VaultError};

const MAX_PATH_LEN: usize = 32 * 1024;
const MAX_SYNC_JSON_LEN: usize = 4 * 1024 * 1024;

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GetforStatus {
    Ok = 0,
    InvalidArgument = 1,
    AlreadyExists = 2,
    InvalidCredentialsOrCorrupt = 3,
    Storage = 4,
    Internal = 5,
    NotFound = 6,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_tls_identity_create(
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        let rcgen::CertifiedKey { cert, key_pair } =
            rcgen::generate_simple_self_signed(vec!["getfor.local".to_owned()])
                .map_err(|_| GetforStatus::Internal)?;
        let json = serde_json::to_vec(&serde_json::json!({
            "certificatePem": cert.pem(),
            "privateKeyPem": key_pair.serialize_pem(),
        }))
        .map_err(|_| GetforStatus::Internal)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

impl From<VaultError> for GetforStatus {
    fn from(error: VaultError) -> Self {
        match error {
            VaultError::InvalidArgument => Self::InvalidArgument,
            VaultError::AlreadyExists => Self::AlreadyExists,
            VaultError::NotFound => Self::NotFound,
            VaultError::InvalidCredentialsOrCorrupt => Self::InvalidCredentialsOrCorrupt,
            VaultError::Storage => Self::Storage,
            VaultError::Internal => Self::Internal,
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_vault_create(
    path: *const u8,
    path_len: usize,
    password: *const u8,
    password_len: usize,
    out_vault: *mut *mut c_void,
) -> GetforStatus {
    // SAFETY: this function forwards the C caller's pointer validity contract.
    unsafe {
        vault_from_ffi(
            path,
            path_len,
            password,
            password_len,
            out_vault,
            Vault::create,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_vault_open(
    path: *const u8,
    path_len: usize,
    password: *const u8,
    password_len: usize,
    out_vault: *mut *mut c_void,
) -> GetforStatus {
    // SAFETY: this function forwards the C caller's pointer validity contract.
    unsafe {
        vault_from_ffi(
            path,
            path_len,
            password,
            password_len,
            out_vault,
            Vault::open,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_vault_open_with_key(
    path: *const u8,
    path_len: usize,
    key: *const u8,
    key_len: usize,
    out_vault: *mut *mut c_void,
) -> GetforStatus {
    // SAFETY: this function forwards the C caller's pointer validity contract.
    unsafe { vault_from_ffi(path, path_len, key, key_len, out_vault, Vault::open_with_key) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_vault_quick_unlock_key(
    vault: *mut c_void,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(vault.quick_unlock_key(), out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_vault_change_password(
    vault: *mut c_void,
    current_password: *const u8,
    current_password_len: usize,
    new_password: *const u8,
    new_password_len: usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: both password buffers are readable for their declared lengths.
        let current_password =
            unsafe { required_bytes(current_password, current_password_len, MAX_PASSWORD_LEN) }?;
        // SAFETY: both password buffers are readable for their declared lengths.
        let new_password =
            unsafe { required_bytes(new_password, new_password_len, MAX_PASSWORD_LEN) }?;
        vault
            .change_password(current_password, new_password)
            .map_err(GetforStatus::from)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_vault_lock(vault: *mut c_void) -> GetforStatus {
    ffi_guard(|| {
        if vault.is_null() {
            return Err(GetforStatus::InvalidArgument);
        }
        // SAFETY: the C ABI requires exactly one lock call for a handle returned by this library.
        drop(unsafe { Box::from_raw(vault.cast::<Vault>()) });
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_record_list(
    vault: *mut c_void,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        let json = vault.record_list_json().map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_record_get(
    vault: *mut c_void,
    id: *const u8,
    id_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let id = unsafe { required_bytes(id, id_len, 32) }?;
        let id = str::from_utf8(id).map_err(|_| GetforStatus::InvalidArgument)?;
        let json = vault.record_get_json(id).map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_record_put(
    vault: *mut c_void,
    json: *const u8,
    json_len: usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let json = unsafe { required_bytes(json, json_len, MAX_RECORD_JSON_LEN) }?;
        vault.record_put_json(json).map_err(GetforStatus::from)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_record_delete(
    vault: *mut c_void,
    id: *const u8,
    id_len: usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let id = unsafe { required_bytes(id, id_len, 32) }?;
        let id = str::from_utf8(id).map_err(|_| GetforStatus::InvalidArgument)?;
        vault.record_delete(id).map_err(GetforStatus::from)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_sync_state(
    vault: *mut c_void,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        let json = vault.sync_state_json().map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_device_info(
    vault: *mut c_void,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        let json = vault.device_info_json().map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_sync_proof(
    vault: *mut c_void,
    challenge: *const u8,
    challenge_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: the challenge is readable for its declared length.
        let challenge = unsafe { required_bytes(challenge, challenge_len, 24) }?;
        let proof = vault.sync_proof(challenge).map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(proof, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_sync_export(
    vault: *mut c_void,
    peer_state: *const u8,
    peer_state_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: input is readable for the declared length.
        let peer_state =
            unsafe { required_bytes(peer_state, peer_state_len, MAX_SYNC_JSON_LEN) }?;
        let json = vault
            .sync_export_json(peer_state)
            .map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_sync_import(
    vault: *mut c_void,
    bundle: *const u8,
    bundle_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        // SAFETY: input is readable for the declared length.
        let bundle = unsafe { required_bytes(bundle, bundle_len, MAX_SYNC_JSON_LEN) }?;
        let imported = vault.sync_import_json(bundle).map_err(GetforStatus::from)?;
        let json = serde_json::to_vec(&serde_json::json!({ "imported": imported }))
            .map_err(|_| GetforStatus::Internal)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_pairing_offer_create(
    vault: *mut c_void,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let vault = unsafe { required_vault(vault) }?;
        let json = vault.pairing_offer_json().map_err(GetforStatus::from)?;
        // SAFETY: output pointers are writable according to the C ABI contract.
        unsafe { return_bytes(json, out_data, out_len) }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_pairing_accept(
    vault: *mut c_void,
    offer: *const u8,
    offer_len: usize,
    password: *const u8,
    password_len: usize,
) -> GetforStatus {
    ffi_guard(|| {
        // SAFETY: the handle must be live and uniquely called from the Dart isolate.
        let vault = unsafe { required_vault_mut(vault) }?;
        // SAFETY: both inputs are readable for their declared lengths.
        let offer = unsafe { required_bytes(offer, offer_len, MAX_SYNC_JSON_LEN) }?;
        // SAFETY: both inputs are readable for their declared lengths.
        let password = unsafe { required_bytes(password, password_len, MAX_PASSWORD_LEN) }?;
        vault
            .pairing_accept_json(offer, password)
            .map_err(GetforStatus::from)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getfor_bytes_free(data: *mut u8, len: usize) -> GetforStatus {
    ffi_guard(|| {
        if data.is_null() || len == 0 {
            return Err(GetforStatus::InvalidArgument);
        }
        // SAFETY: the pointer and exact length must come from a getfor output function once.
        let mut bytes = unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(data, len)) };
        bytes.zeroize();
        Ok(())
    })
}

unsafe fn vault_from_ffi(
    path: *const u8,
    path_len: usize,
    password: *const u8,
    password_len: usize,
    out_vault: *mut *mut c_void,
    operation: fn(&Path, &[u8]) -> Result<Vault, VaultError>,
) -> GetforStatus {
    ffi_guard(|| {
        if out_vault.is_null() {
            return Err(GetforStatus::InvalidArgument);
        }
        // SAFETY: the caller supplied writable storage for the output pointer.
        unsafe { out_vault.write(ptr::null_mut()) };
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let path = unsafe { required_bytes(path, path_len, MAX_PATH_LEN) }?;
        // SAFETY: pointer validity is required by this function's C ABI contract.
        let password = unsafe { required_bytes(password, password_len, MAX_PASSWORD_LEN) }?;
        let path = str::from_utf8(path).map_err(|_| GetforStatus::InvalidArgument)?;
        let vault = operation(Path::new(path), password).map_err(GetforStatus::from)?;
        // SAFETY: the non-null output pointer was checked above and ownership transfers to C.
        unsafe { out_vault.write(Box::into_raw(Box::new(vault)).cast::<c_void>()) };
        Ok(())
    })
}

unsafe fn required_bytes<'a>(
    pointer: *const u8,
    length: usize,
    maximum: usize,
) -> Result<&'a [u8], GetforStatus> {
    if pointer.is_null() || length == 0 || length > maximum {
        return Err(GetforStatus::InvalidArgument);
    }
    // SAFETY: the C ABI requires pointer to reference `length` readable bytes for this call.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

unsafe fn required_vault<'a>(vault: *mut c_void) -> Result<&'a Vault, GetforStatus> {
    if vault.is_null() {
        return Err(GetforStatus::InvalidArgument);
    }
    // SAFETY: the pointer must be a live handle returned by this library.
    Ok(unsafe { &*vault.cast::<Vault>() })
}

unsafe fn required_vault_mut<'a>(vault: *mut c_void) -> Result<&'a mut Vault, GetforStatus> {
    if vault.is_null() {
        return Err(GetforStatus::InvalidArgument);
    }
    // SAFETY: callers serialize access to a live handle returned by this library.
    Ok(unsafe { &mut *vault.cast::<Vault>() })
}

unsafe fn return_bytes(
    bytes: Vec<u8>,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), GetforStatus> {
    if out_data.is_null() || out_len.is_null() || bytes.is_empty() {
        return Err(GetforStatus::InvalidArgument);
    }
    let length = bytes.len();
    let pointer = Box::into_raw(bytes.into_boxed_slice()).cast::<u8>();
    // SAFETY: both pointers were checked and the caller provides writable output storage.
    unsafe {
        out_data.write(pointer);
        out_len.write(length);
    }
    Ok(())
}

fn ffi_guard(operation: impl FnOnce() -> Result<(), GetforStatus>) -> GetforStatus {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation)) {
        Ok(Ok(())) => GetforStatus::Ok,
        Ok(Err(status)) => status,
        Err(_) => GetforStatus::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_rejects_nulls_and_round_trips_a_handle() {
        let mut output = ptr::null_mut();
        assert_eq!(
            unsafe { getfor_vault_open(ptr::null(), 0, ptr::null(), 0, &mut output) },
            GetforStatus::InvalidArgument
        );

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.db");
        let path = path.to_str().unwrap().as_bytes();
        let password = b"correct horse battery staple";
        assert_eq!(
            unsafe {
                getfor_vault_create(
                    path.as_ptr(),
                    path.len(),
                    password.as_ptr(),
                    password.len(),
                    &mut output,
                )
            },
            GetforStatus::Ok
        );
        assert!(!output.is_null());

        let record = br#"{"title":"Example","password":"secret"}"#;
        assert_eq!(
            unsafe { getfor_record_put(output, record.as_ptr(), record.len()) },
            GetforStatus::Ok
        );
        let mut records = ptr::null_mut();
        let mut records_len = 0;
        assert_eq!(
            unsafe { getfor_record_list(output, &mut records, &mut records_len) },
            GetforStatus::Ok
        );
        let records_json = unsafe { slice::from_raw_parts(records, records_len) }.to_vec();
        assert_eq!(
            unsafe { getfor_bytes_free(records, records_len) },
            GetforStatus::Ok
        );
        let records: serde_json::Value = serde_json::from_slice(&records_json).unwrap();
        assert_eq!(records[0]["title"], "Example");
        assert!(records[0].get("password").is_none());

        assert_eq!(unsafe { getfor_vault_lock(output) }, GetforStatus::Ok);
    }
}
