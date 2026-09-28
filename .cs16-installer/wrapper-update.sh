#!/usr/bin/env bash
# wrapper-update.sh — safe LinuxGSM update wrapper.
#
# Problem this solves: LinuxGSM's own "./csserver update" re-syncs the base
# HLDS/CS Steam depot via SteamCMD. That depot includes engine_i486.so,
# filesystem_stdio.so, hlds_linux, hltv, cs.so, and liblist.gam — i.e.
# exactly the files ReHLDS and ReGameDLL_CS replace. A plain LinuxGSM
# update can silently revert the server back to stock HLDS/CS and reset
# liblist.gam to point at the stock gamedll.
#
# This wrapper: runs the normal LinuxGSM update, then restores the
# installer-verified files from the LOCAL vault (no network/GitHub calls —
# fast, and doesn't depend on GitHub being reachable at cron time), then
# re-applies the liblist.gam edit (idempotent — a no-op if it's already
# correct).
#
# Metamod-R/AMX Mod X/ReAPI/Reunion live entirely under addons/, which is
# NOT part of the Steam depot, so a plain update never touches them — no
# restore needed for those, only the liblist.gam re-patch (since THEY
# depend on liblist.gam still pointing at Metamod to load at all).
#
# Deliberately does NOT touch server.cfg, rcon_password, or reunion.cfg's
# SteamIdHashSalt — those are ongoing operator config, never regenerated
# by an automated update.
#
# Designed to be cron-safe: no prompts, deterministic, exits non-zero on
# real problems so cron mail/logging surfaces them. Deployed with its own
# copy of env.conf alongside it (see install-server.sh's
# step_install_update_wrapper) since cron doesn't run from a fixed cwd.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.conf
source "${SCRIPT_DIR}/env.conf"

log()  { printf '[wrapper-update] %s\n' "$*"; }
warn() { printf '[wrapper-update][WARN] %s\n' "$*" >&2; }
fail() { printf '[wrapper-update][FAIL] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] || fail "Do not run as root — run as ${SERVICE_USER} (this is how cron should be configured to call it)."

# restore_from_vault <label> <vault_snapshot_dir> <dest_dir>
# Copies every file from a previously-stashed "verified-latest" vault
# snapshot back onto dest_dir, overwriting whatever LinuxGSM's update just
# wrote there.
restore_from_vault() {
  local label="$1" vault_dir="$2" dest_dir="$3"
  if [[ ! -d "$vault_dir" ]]; then
    warn "${label}: no vault snapshot found at ${vault_dir} — skipping restore. (Was the initial install done via install-server.sh? A snapshot is created automatically during that install.)"
    return 0
  fi
  local rel_path dest_path src_file restored=0
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$vault_dir"/}"
    dest_path="${dest_dir}/${rel_path}"
    mkdir -p "$(dirname "$dest_path")"
    cp -a "$src_file" "$dest_path"
    restored=$((restored + 1))
  done < <(find "$vault_dir" -type f -print0)
  log "${label}: restored ${restored} file(s) from vault into ${dest_dir}."
}

# Same idempotent liblist.gam edit as install-server.sh's
# edit_liblist_gam_for_metamod — duplicated here rather than shared, since
# this script is deployed standalone (no lib/ directory copied alongside).
reapply_liblist_gam() {
  local liblist="${CSTRIKE_DIR}/liblist.gam"
  if [[ ! -f "$liblist" ]]; then
    warn "liblist.gam not found at ${liblist} — skipping re-patch."
    return 0
  fi
  if grep -q 'addons/metamod/metamod_i386.so' "$liblist"; then
    log "liblist.gam already points at Metamod-R — no re-patch needed."
    return 0
  fi
  cp -a "$liblist" "${BINARY_VAULT_DIR}/liblist.gam.orig-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^gamedll_linux' "$liblist"; then
    sed -i 's|^gamedll_linux.*|gamedll_linux		"addons/metamod/metamod_i386.so"|' "$liblist"
  else
    printf 'gamedll_linux\t\t"addons/metamod/metamod_i386.so"\n' >> "$liblist"
  fi
  if grep -q 'addons/metamod/metamod_i386.so' "$liblist"; then
    log "liblist.gam re-patched (the update likely reset it to stock, as expected — this is exactly what this wrapper is for)."
  else
    warn "Failed to re-patch liblist.gam — check ${liblist} manually. Metamod-R and everything loaded through it (AMX Mod X, ReAPI, Reunion) will not load until this is fixed."
  fi
}

main() {
  log "Starting safe update: $(date -Iseconds)"

  cd "$SERVICE_HOME"
  [[ -x "./${LGSM_SERVER_NAME}" ]] || fail "./${LGSM_SERVER_NAME} not found in ${SERVICE_HOME} — is env.conf's SERVICE_HOME/LGSM_SERVER_NAME correct?"

  log "Running LinuxGSM update check..."
  ./"${LGSM_SERVER_NAME}" update

  log "Restoring installer-managed files from the local vault..."
  restore_from_vault "ReHLDS" "${BINARY_VAULT_DIR}/verified-latest" "$SERVERFILES_DIR"
  restore_from_vault "ReGameDLL_CS" "${BINARY_VAULT_DIR}/regamedll/verified-latest" "$CSTRIKE_DIR"

  reapply_liblist_gam

  # Quick post-restore validation — warn, don't hard-fail, since a problem
  # here shouldn't take the whole cron job's exit code down if the server
  # might still be limping along; the warnings are what surface in cron logs.
  [[ -x "${SERVERFILES_DIR}/engine_i486.so" ]] || warn "engine_i486.so missing/not executable after update+restore — check manually."
  [[ -f "${CSTRIKE_DIR}/dlls/cs.so" ]] || warn "cs.so missing after update+restore — check manually."

  log "Safe update complete: $(date -Iseconds)"
}

main "$@"
