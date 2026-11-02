#!/usr/bin/env bash
# Upload the Android upload key to this repo's GitHub Actions secrets.
# Usage: tool/set_release_secrets.sh [path/to/key.properties]
# key.properties must hold storeFile, storePassword, keyAlias and keyPassword.
set -euo pipefail
props="${1:-android/key.properties}"
get() { grep "^$1=" "$props" | cut -d= -f2-; }
store="$(get storeFile)"
[ -f "$store" ] || { echo "Keystore not found: $store" >&2; exit 1; }
base64 < "$store" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64
get storePassword | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD
get keyPassword | tr -d '\n' | gh secret set ANDROID_KEY_PASSWORD
get keyAlias | tr -d '\n' | gh secret set ANDROID_KEY_ALIAS
gh secret list
