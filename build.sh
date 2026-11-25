#!/usr/bin/env bash
# LAN Mic build helper. Run from anywhere.
#   ./build.sh                    debug APK, phone + tv
#   ./build.sh release [app]      release APK + AAB (checks signing keys first)
#   ./build.sh debug [app]        debug APK
#   ./build.sh test               analyze + tests for protocol, pcm_out, phone, tv
#   ./build.sh keys [app]         verify key.properties and keystore (no build)
# app = phone | tv | all (default all)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

cmd="${1:-debug}"
app="${2:-all}"
apps() { [[ $app == all ]] && echo "phone tv" || echo "$app"; }

prop() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2- || true; }

check_keys() { # $1 = phone|tv. Prints the key fingerprint, never the passwords.
  local f="$ROOT/$1/android/key.properties"
  [[ -f $f ]] || { echo "[$1] missing $f"; return 1; }
  local store alias spw
  store=$(prop "$f" storeFile); alias=$(prop "$f" keyAlias); spw=$(prop "$f" storePassword)
  for v in "$store" "$alias" "$spw" "$(prop "$f" keyPassword)"; do
    [[ -n $v && $v != *CHANGE_ME* ]] || { echo "[$1] $f still has empty or CHANGE_ME values"; return 1; }
  done
  [[ $store == /* ]] || store="$ROOT/$1/android/$store"
  [[ -f $store ]] || { echo "[$1] keystore not found: $store"; return 1; }
  # shortcut: keytool checks the store password and alias only, not keyPassword; a wrong keyPassword fails at build time.
  SP="$spw" keytool -list -v -keystore "$store" -alias "$alias" -storepass:env SP 2>&1 \
    | grep -E "Alias name|Valid from|SHA256" || { echo "[$1] keytool could not open the keystore (wrong password or alias?)"; return 1; }
  echo "[$1] keys OK"
}

build() { # $1 = phone|tv, $2 = debug|release
  echo "== $1 $2 =="
  cd "$ROOT/$1"
  flutter pub get >/dev/null
  if [[ $2 == release ]]; then
    flutter build apk --release
    flutter build appbundle --release
    echo "-- APK signer:"
    # v2-only signature (minSdk 26), so keytool -jarfile can't read it; use apksigner.
    local signer
    signer=$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/build-tools/*/apksigner | sort -V | tail -1)
    "$signer" verify --print-certs build/app/outputs/flutter-apk/app-release.apk 2>/dev/null | grep -iE "DN|SHA-256"
  else
    flutter build apk --debug
  fi
}

run_tests() {
  echo "== protocol =="; (cd "$ROOT/protocol" && dart pub get >/dev/null && dart analyze && dart test)
  for p in pcm_out phone tv; do
    echo "== $p =="
    (cd "$ROOT/$p" && flutter pub get >/dev/null && flutter analyze)
    # phone: skip the real-socket loopback tests; run `flutter test` in phone/ to include them.
    if [[ $p == phone ]]; then (cd "$ROOT/$p" && flutter test --exclude-tags integration)
    else (cd "$ROOT/$p" && flutter test); fi
  done
}

case "$cmd" in
  debug) for a in $(apps); do build "$a" debug; done ;;
  release) for a in $(apps); do check_keys "$a"; done; for a in $(apps); do build "$a" release; done ;;
  keys) for a in $(apps); do check_keys "$a"; done ;;
  test) run_tests ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
