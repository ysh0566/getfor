#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: package_macos.sh VERSION BUILD_NUMBER}"
BUILD_NUMBER="${2:?usage: package_macos.sh VERSION BUILD_NUMBER}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

flutter build macos --release --config-only --build-name "${VERSION%%-*}" --build-number "${BUILD_NUMBER}"
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -derivedDataPath build/macos-ci -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY=' 'DEVELOPMENT_TEAM=' \
  COMPILER_INDEX_STORE_ENABLE=NO build

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/getfor-package.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
APP="${STAGING_DIR}/getfor.app"
ditto build/macos-ci/Build/Products/Release/getfor.app "${APP}"
# Restricted AutoFill entitlements require Developer ID provisioning; omit that extension in community builds.
rm -rf "${APP}/Contents/PlugIns"
find "${APP}" -name embedded.provisionprofile -delete
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"
lipo "${APP}/Contents/MacOS/getfor" -verify_arch arm64
lipo "${APP}/Contents/MacOS/getfor" -verify_arch x86_64

mkdir -p dist
PACKAGE="${ROOT_DIR}/dist/getfor-${VERSION}-macos-unnotarized-universal"
ditto -c -k --keepParent "${APP}" "${PACKAGE}.zip"
ln -s /Applications "${STAGING_DIR}/Applications"
cat > "${STAGING_DIR}/README.txt" <<'NOTES'
Getfor requires macOS 26 or later. Drag getfor.app to Applications.
This community build is ad-hoc signed and not notarized. If blocked, allow it in
System Settings > Privacy & Security. System AutoFill integration is not included;
it requires Developer ID signing and provisioning.
NOTES
hdiutil create -volname "Getfor ${VERSION}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${PACKAGE}.dmg"
