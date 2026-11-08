mod ffi;
mod vault;

pub const ABI_VERSION: u32 = 3;

/// Returns the C ABI version implemented by this core library.
#[unsafe(no_mangle)]
pub extern "C" fn getfor_core_abi_version() -> u32 {
    ABI_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_current_abi_version() {
        assert_eq!(getfor_core_abi_version(), ABI_VERSION);
    }
}
