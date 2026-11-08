#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"
CORE_DIR="${ROOT_DIR}/native/getfor_core"
OUTPUT_DIR="${ROOT_DIR}/build/rust/apple/${PLATFORM_NAME}/${CONFIGURATION}"

if command -v cargo >/dev/null 2>&1; then
  CARGO_BIN="$(command -v cargo)"
else
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
fi

if [[ ! -x "${CARGO_BIN}" ]]; then
  echo "error: cargo is required to build getfor_core" >&2
  exit 1
fi

# Xcode architecture names differ from Rust target triples.
targets=()
for arch in ${ARCHS}; do
  case "${PLATFORM_NAME}:${arch}" in
    macosx:arm64) target="aarch64-apple-darwin" ;;
    macosx:x86_64) target="x86_64-apple-darwin" ;;
    *)
      echo "error: unsupported macOS build target ${PLATFORM_NAME}:${arch}" >&2
      exit 1
      ;;
  esac

  targets+=("${target}")
done

profile="debug"
if [[ "${CONFIGURATION}" != "Debug" ]]; then
  profile="release"
fi

libraries=()
for target in "${targets[@]}"; do
  if [[ "${profile}" == "release" ]]; then
    "${CARGO_BIN}" build \
      --manifest-path "${CORE_DIR}/Cargo.toml" \
      --target "${target}" \
      --release
  else
    "${CARGO_BIN}" build \
      --manifest-path "${CORE_DIR}/Cargo.toml" \
      --target "${target}"
  fi
  libraries+=("${CORE_DIR}/target/${target}/${profile}/libgetfor_core.a")
done

mkdir -p "${OUTPUT_DIR}"
if [[ ${#libraries[@]} -eq 1 ]]; then
  cp "${libraries[0]}" "${OUTPUT_DIR}/libgetfor_core.a"
else
  xcrun lipo -create "${libraries[@]}" -output "${OUTPUT_DIR}/libgetfor_core.a"
fi
