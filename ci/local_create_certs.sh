#!/usr/bin/env bash
set -euo pipefail

BUNDLER_VERSION="${BUNDLER_VERSION:-2.6.2}"

########################################
# This script ensures local certs / provisioning profiles exist.
# It must NOT call or exec the top-level build script to avoid recursion.
########################################

ROOT_DIR="$(pwd)"
BUILD_ARTIFACTS_DIR="${BUILD_ARTIFACTS_DIR:-$ROOT_DIR/build/artifacts}"
mkdir -p "$BUILD_ARTIFACTS_DIR"
umask 0022
LOGFILE="$BUILD_ARTIFACTS_DIR/ci-local-create-certs-$(date +%Y%m%d-%H%M%S).log"

echo "=== ci/local_create_certs.sh starting at $(date -u) ===" | tee -a "$LOGFILE"

# Load environment (if present)
if [[ -f ".trio-env" ]]; then
  echo "[create_certs] Loading environment from .trio-env" | tee -a "$LOGFILE"
  set -a
  # shellcheck disable=SC1091
  source .trio-env
  set +a
fi

# Required envs (warn, but don't crash here — caller can fail if they expect strict)
for var in TEAMID GH_PAT FASTLANE_KEY_ID FASTLANE_ISSUER_ID FASTLANE_KEY MATCH_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "[create_certs] WARNING: Environment variable $var is not set." | tee -a "$LOGFILE"
  fi
done

# Silence Fastlane & Bundler noise (suppress update checks / changelog)
export FASTLANE_SKIP_UPDATE_CHECK=1
export FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_DONT_STORE_PASSWORD=1

export BUNDLE_SILENCE_ROOT_WARNING=1
export BUNDLE_DISABLE_VERSION_CHECK=true

# Quick tool checks
for cmd in ruby bundle git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[create_certs] ERROR: required tool '$cmd' is not available on PATH" | tee -a "$LOGFILE"
    exit 1
  fi
done

echo "[create_certs] Ruby: $(ruby -v)" | tee -a "$LOGFILE"
echo "[create_certs] Bundler: $(bundle _${BUNDLER_VERSION}_ -v 2>/dev/null || echo 'bundler not found for this version')" | tee -a "$LOGFILE"

# Ensure gems are installed (safe)
echo "[create_certs] Running bundle _${BUNDLER_VERSION}_ install" | tee -a "$LOGFILE"
bundle _${BUNDLER_VERSION}_ install 2>&1 | tee -a "$LOGFILE" || {
  echo "[create_certs] bundle install failed; continuing (fastlane steps may fail)." | tee -a "$LOGFILE"
}

# Run fastlane lanes that manage certs/profiles. Non-fatal; we want build script to make a clear decision.
echo "[create_certs] Running fastlane certs/check_and_renew_certificates (non-fatal)" | tee -a "$LOGFILE"
set +e
bundle _${BUNDLER_VERSION}_ exec fastlane certs 2>&1 | tee -a "$LOGFILE"
bundle _${BUNDLER_VERSION}_ exec fastlane check_and_renew_certificates 2>&1 | tee -a "$LOGFILE"
FL_EXIT_CODE=${PIPESTATUS[0]:-0}
set -e

if [[ $FL_EXIT_CODE -ne 0 ]]; then
  echo "[create_certs] fastlane cert lanes finished with exit code $FL_EXIT_CODE (non-fatal to this helper)." | tee -a "$LOGFILE"
else
  echo "[create_certs] fastlane cert lanes finished successfully." | tee -a "$LOGFILE"
fi

echo "=== ci/local_create_certs.sh complete ===" | tee -a "$LOGFILE"
exit 0