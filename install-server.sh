#!/usr/bin/env bash
# install-server.sh — Phase 2 (csserver user, non-root). LinuxGSM bootstrap +
# ReHLDS swap (GPG-checked, not gated). Run bootstrap-root.sh first, or ensure your own
# fresh VPS setup matches what env.conf expects.
#
# Must be run as the service user (env.conf: SERVICE_USER), NOT root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.conf
source "${SCRIPT_DIR}/env.conf"

log()   { printf '[install-server] %s\n' "$*"; }
warn()  { printf '[install-server][WARN] %s\n' "$*" >&2; }
fail()  { printf '[install-server][FAIL] %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/gpg-verify.sh
source "${SCRIPT_DIR}/lib/gpg-verify.sh"

# ── flags ────────────────────────────────────────────────────────────────
UNATTENDED="no"
USE_LATEST="no"
RCON_PASSWORD_ARG=""
INSTALL_REUNION_FLAG="${INSTALL_REUNION}"       # from env.conf, overridable per-run
INSTALL_REGAMEDLL_FLAG="${INSTALL_REGAMEDLL}"
HARDENED_FLAG="${INSTALL_HARDENED_IPTABLES}"
SKIP_LINUXGSM="no"

usage() {
  cat <<EOF
Usage: ./install-server.sh [options]

  --unattended              Non-interactive. Safe defaults everywhere except
                             GPG/signature failures and rcon validation,
                             which always fail closed (non-zero exit).
  --latest                  IGNORED for now — all downloads are stubbed out
                             (see LOCAL_ASSET_DIR). Every component installs
                             from a local file matching its pinned tag,
                             regardless of this flag.
  --rcon-password=PASS      Use this rcon password instead of prompting or
                             auto-generating.
  --no-reunion               Skip Reunion (non-Steam client support).
  --no-regamedll             Skip ReGameDLL_CS.
  --hardened                 EXPERIMENTAL: also apply the A2S iptables rules.
  --skip-linuxgsm            Skip LinuxGSM bootstrap (assume already installed).
  -h, --help                  Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --unattended) UNATTENDED="yes" ;;
    --latest) USE_LATEST="yes" ;;
    --rcon-password=*) RCON_PASSWORD_ARG="${arg#*=}" ;;
    --no-reunion) INSTALL_REUNION_FLAG="no" ;;
    --no-regamedll) INSTALL_REGAMEDLL_FLAG="no" ;;
    --hardened) HARDENED_FLAG="yes" ;;
    --skip-linuxgsm) SKIP_LINUXGSM="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

confirm() {
  # Same pattern as bootstrap-root.sh: unattended takes the safe default and
  # logs it. This script's genuinely unsafe-default cases (GPG/signature
  # failure, rcon validation) don't go through confirm() at all — they fail
  # via fail() directly, with no bypass.
  local question="$1"
  if [[ "$UNATTENDED" == "yes" ]]; then
    log "[unattended] auto-confirming: ${question}"
    return 0
  fi
  read -r -p "${question} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_non_root() {
  [[ "$(id -u)" -ne 0 ]] || fail "Do not run this script as root — it must run as the service user (${SERVICE_USER}). Run 'su - ${SERVICE_USER}' first."
  if [[ "$(id -un)" != "$SERVICE_USER" ]]; then
    warn "Running as '$(id -un)', not the configured SERVICE_USER ('${SERVICE_USER}'). Continuing, but paths in env.conf assume ${SERVICE_USER}'s home directory — make sure that's intentional."
  fi
}

# ── Local asset resolution (network downloads stubbed out) ───────────────
# All GitHub API/download logic is disabled for now. Every component
# (ReHLDS, ReGameDLL_CS, Metamod-R, AMX Mod X, ReAPI, Reunion) now installs
# from a file you copy into LOCAL_ASSET_DIR ahead of time, instead of
# fetching it. The filename just needs to match that component's
# *_ASSET_REGEX from env.conf (same regex that used to be matched against
# GitHub release asset names) — resolve_local_asset finds it for you.
#
# For ReHLDS specifically: if you also drop the matching ".asc" signature
# file next to the archive (same filename + ".asc"), GPG verification still
# runs against it locally. If it's missing, we say so and proceed
# unverified, same "check not a gate" policy as before.
LOCAL_ASSET_DIR="${LOCAL_ASSET_DIR:-${SERVICE_HOME}/.cs16-installer-local}"

# resolve_local_asset <label> <pinned_tag> <asset_regex> <out_path_var>
# Looks for a file under LOCAL_ASSET_DIR (non-recursive) whose name matches
# asset_regex. Fails with a copy-paste-friendly instruction if none is
# found. If more than one matches, uses the first and warns about the rest.
resolve_local_asset() {
  local label="$1" pinned_tag="$2" regex="$3" out_path="$4"
  mkdir -p "$LOCAL_ASSET_DIR"

  local -a matches=()
  local f
  while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" =~ $regex ]] && matches+=("$f")
  done < <(find "$LOCAL_ASSET_DIR" -maxdepth 1 -type f -print0 | sort -z)

  if (( ${#matches[@]} == 0 )); then
    fail "${label}: download is not available. Please copy your ${label} release file (pinned tag ${pinned_tag}; filename must match '${regex}') into ${LOCAL_ASSET_DIR}, then re-run."
  fi
  if (( ${#matches[@]} > 1 )); then
    warn "${label}: multiple files in ${LOCAL_ASSET_DIR} matched '${regex}' — using '${matches[0]}'. Remove the others if this wasn't intended: ${matches[*]:1}"
  fi

  printf -v "$out_path" '%s' "${matches[0]}"
  log "${label}: using local file ${matches[0]}"
}

# ── LinuxGSM install ─────────────────────────────────────────────────────

step_linuxgsm_install() {
  if [[ "$SKIP_LINUXGSM" == "yes" ]]; then
    log "Step: LinuxGSM install — SKIPPED by flag"
    return 0
  fi
  log "Step: LinuxGSM install (${LGSM_SERVER_NAME})"
  # NOTE: bootstrap-root.sh's step_lgsm_and_engine_deps already installs
  # LinuxGSM's and the engine's real, confirmed dependency list as root in
  # Phase 1 (not a guess — see that step's comments), and
  # step_linuxgsm_bootstrap fetches the ./csserver launcher itself. So by
  # the time this runs, everything below should work as a plain,
  # non-privileged user — no sudo/root needed, since there's nothing left
  # for LGSM to self-install. This function still does the actual
  # branch-config + "install" call itself (it's idempotent — if
  # ./csserver already exists, the bootstrap part below is a no-op), and
  # remains the whole path if you skip bootstrap-root.sh's LGSM steps or
  # skip bootstrap-root.sh entirely — in which case expect LGSM's "missing
  # dependencies... run as root" warning if the OS image isn't already
  # fully provisioned.

  cd "$HOME"

  if [[ -x "./${LGSM_SERVER_NAME}" && -d "${CSTRIKE_DIR}" ]]; then
    warn "LinuxGSM (${LGSM_SERVER_NAME}) and serverfiles/cstrike already present — leaving as-is. Use --skip-linuxgsm explicitly if you want this assumed next time."
    return 0
  fi

  if [[ ! -x "./${LGSM_SERVER_NAME}" ]]; then
    confirm "About to download linuxgsm.sh and bootstrap the '${LGSM_SERVER_NAME}' script in ${HOME}. Proceed?" \
      || fail "LinuxGSM bootstrap is required to continue."
    curl -Lo linuxgsm.sh https://linuxgsm.sh
    chmod +x linuxgsm.sh
    bash linuxgsm.sh "${LGSM_SERVER_NAME}"
    [[ -x "./${LGSM_SERVER_NAME}" ]] || fail "LinuxGSM bootstrap did not produce an executable ./${LGSM_SERVER_NAME} — check the output above."
  fi

  # ── Steam branch config — must be written BEFORE the first LGSM install ──
  # LGSM's own generated config does not reliably ship "branch"/"betapassword"
  # pre-populated with anything useful. Left unset, LGSM's SteamCMD call
  # defaults to the modern "public" branch — NOT compatible with ReHLDS,
  # which needs the pre-anniversary "steam_legacy" branch (engine build
  # <= 8684; see https://github.com/rehlds/ReHLDS#readme). Setting this after
  # the fact doesn't help — the base engine has already been pulled wrong by
  # then — so this has to happen here, before step_linuxgsm_install ever
  # calls "install".
  #
  # IMPORTANT: this writes to common.cfg, NOT _default.cfg. Per LinuxGSM's
  # own docs, _default.cfg is regenerated/overwritten by LinuxGSM (e.g. on
  # "update-lgsm") and must never be hand-edited — common.cfg and
  # <instance>.cfg are the two files LGSM guarantees it won't touch.
  local lgsm_cfg_dir="${HOME}/lgsm/config-lgsm/${LGSM_SERVER_NAME}"
  local lgsm_cfg="${lgsm_cfg_dir}/common.cfg"
  mkdir -p "$lgsm_cfg_dir"
  touch "$lgsm_cfg"

  if grep -q '^branch=' "$lgsm_cfg"; then
    sed -i "s|^branch=.*|branch=\"${STEAM_BRANCH}\"|" "$lgsm_cfg"
  else
    printf 'branch="%s"\n' "$STEAM_BRANCH" >> "$lgsm_cfg"
  fi
  if grep -q '^betapassword=' "$lgsm_cfg"; then
    sed -i 's|^betapassword=.*|betapassword=""|' "$lgsm_cfg"
  else
    printf 'betapassword=""\n' >> "$lgsm_cfg"
  fi
  log "LinuxGSM branch set in ${lgsm_cfg}: branch=\"${STEAM_BRANCH}\" (betapassword left blank)."
  if ! grep -q "^branch=\"${STEAM_BRANCH}\"" "$lgsm_cfg"; then
    warn "Wrote to ${lgsm_cfg} but couldn't confirm the value stuck — double check it by hand before continuing (do NOT edit _default.cfg instead; LGSM overwrites that one)."
  fi

  log "Running LinuxGSM install (this downloads CS1.6 server files via SteamCMD and can take a while)..."
  if [[ "$UNATTENDED" == "yes" ]]; then
    ./"${LGSM_SERVER_NAME}" auto-install
  else
    confirm "About to run './${LGSM_SERVER_NAME} install' (interactive LinuxGSM installer). Proceed?" \
      || fail "LinuxGSM server install is required to continue."
    ./"${LGSM_SERVER_NAME}" install
  fi

  # Validation
  if [[ ! -d "$CSTRIKE_DIR" ]]; then
    fail "Expected ${CSTRIKE_DIR} to exist after LinuxGSM install but it doesn't. Check the installer output above for errors."
  fi
  if [[ ! -f "${SERVERFILES_DIR}/engine_i486.so" ]]; then
    fail "Expected ${SERVERFILES_DIR}/engine_i486.so after LinuxGSM install but it's missing — the base HLDS engine may not have downloaded correctly."
  fi
  log "LinuxGSM install confirmed: ${CSTRIKE_DIR} and base engine present."

  # GoldSrc apps (id 90 and siblings) are known to sometimes report success
  # while having failed to fully materialize every file in the depot —
  # commonly surfacing later as "_stat on file .../which appeared to exist
  # failed!!!" or a missing steam.inf. We don't auto-retry here (that's a
  # judgment call for you to make, not something to loop on silently) — just
  # flag it clearly so you know to act on it before trusting this install.
  local steam_inf="${SERVERFILES_DIR}/steam.inf"
  if [[ ! -f "$steam_inf" ]]; then
    warn "No steam.inf found at ${steam_inf} after LinuxGSM install. This is a known GoldSrc/SteamCMD quirk (app ${STEAM_APPID} commonly fails to fully download on the first pass) — run './${LGSM_SERVER_NAME} validate' a few times until it completes with no missing-file errors, then re-check this before continuing to the ReHLDS step."
  else
    log "steam.inf present: $(grep -i '^PatchVersion' "$steam_inf" 2>/dev/null || echo '(no PatchVersion line found)')"
    warn "Confirm the PatchVersion above is 1.1.2.2 (pre-anniversary, engine build <= 8684) before proceeding — ReHLDS is not compatible with the modern build. If it's anything else, or if './${LGSM_SERVER_NAME} install' printed any '_stat on file ... failed' errors, run './${LGSM_SERVER_NAME} validate' a few times (a known GoldSrc quirk) before continuing."
  fi
}

# ── ReHLDS swap ──────────────────────────────────────────────────────────

step_rehlds_swap() {
  log "Step: ReHLDS engine swap (GPG-checked, not gated — see lib/gpg-verify.sh)"

  [[ "$USE_LATEST" != "yes" ]] || warn "ReHLDS: --latest is ignored — downloads are stubbed out, installing from LOCAL_ASSET_DIR regardless."
  [[ -n "$REHLDS_PINNED_TAG" ]] || fail "REHLDS_PINNED_TAG is empty in env.conf. Set a pinned tag matching the file you're copying into ${LOCAL_ASSET_DIR}."
  local tag="$REHLDS_PINNED_TAG"

  local archive_path
  resolve_local_asset "ReHLDS" "$tag" "$REHLDS_ASSET_REGEX" archive_path

  local work_dir archive_file
  work_dir="$(mktemp -d)"
  archive_file="${work_dir}/$(basename "$archive_path")"
  cp -a "$archive_path" "$archive_file"

  local verified=0
  local sig_path="${archive_path}.asc"
  if [[ -f "$sig_path" ]]; then
    if gpg_ensure_key_imported "$REHLDS_GPG_KEY_ID" "$REHLDS_GPG_KEYSERVER"; then
      local sig_file="${archive_file}.sig"
      cp -a "$sig_path" "$sig_file"
      local verify_output
      if verify_output="$(gpg --homedir "$GPG_VERIFY_HOME" --verify "$sig_file" "$archive_file" 2>&1)"; then
        if grep -qi "$REHLDS_GPG_KEY_ID" <<<"$verify_output" || grep -qi "${REHLDS_GPG_KEY_ID: -16}" <<<"$verify_output"; then
          verified=1
        else
          warn "ReHLDS ${tag}: signature verified against a DIFFERENT key than expected (${REHLDS_GPG_KEY_ID}) — continuing WITHOUT full verification."
          warn "$verify_output"
        fi
      else
        warn "ReHLDS ${tag}: GPG signature verification FAILED against the local .asc file — continuing WITHOUT verification."
        warn "$verify_output"
      fi
    else
      warn "ReHLDS ${tag}: found a local .asc file but could not import the GPG key (keyserver unreachable?) — continuing WITHOUT verification."
    fi
  else
    warn "ReHLDS ${tag}: no local signature file found at ${sig_path} — continuing WITHOUT verification. Copy the .asc alongside the archive in ${LOCAL_ASSET_DIR} if you want this checked."
  fi

  if [[ "$verified" == "1" ]]; then
    log "ReHLDS ${tag}: GPG signature verification PASSED."
  else
    warn "ReHLDS ${tag}: proceeding WITHOUT a fully verified signature (see warnings above). GPG here is a check, not a hard gate — if that matters for your deployment, treat the warnings above as a signal to verify manually before going further."
  fi

  log "Extracting archive..."
  local extract_dir="${work_dir}/extracted"
  mkdir -p "$extract_dir"
  case "$archive_file" in
    *.tar.gz|*.tgz) tar -xzf "$archive_file" -C "$extract_dir" ;;
    *.zip) unzip -q "$archive_file" -d "$extract_dir" ;;
    *) fail "Don't know how to extract ${archive_file} (unrecognized extension)." ;;
  esac

  # The archive contains both bin/linux32 and bin/win32 — we only want
  # linux32, and everything inside it overlays FLAT onto SERVERFILES_DIR
  # (e.g. bin/linux32/engine_i486.so -> SERVERFILES_DIR/engine_i486.so,
  # bin/linux32/valve/dlls/director.so -> SERVERFILES_DIR/valve/dlls/director.so).
  # Confirmed layout: core.so, demoplayer.so, engine_i486.so,
  # filesystem_stdio.so, hlds_linux, hltv, proxy.so, valve/dlls/director.so.
  local linux32_dir
  linux32_dir="$(find "$extract_dir" -type d -name 'linux32' -print -quit)"
  [[ -n "$linux32_dir" ]] || fail "Could not find a 'linux32' directory inside the ReHLDS archive — archive layout may have changed upstream."

  confirm "About to replace the ReHLDS engine files under ${SERVERFILES_DIR} (engine_i486.so, filesystem_stdio.so, hlds_linux, hltv, core.so, demoplayer.so, proxy.so, valve/dlls/director.so) with the build (${tag}). Originals will be backed up to ${BINARY_VAULT_DIR}. Proceed?" \
    || fail "ReHLDS swap declined — cannot continue without it (this installer targets ReHLDS specifically, not stock HLDS)."

  mkdir -p "$BINARY_VAULT_DIR"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"

  local rel_path dest_path backed_up=0 installed=0
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$linux32_dir"/}"
    dest_path="${SERVERFILES_DIR}/${rel_path}"
    mkdir -p "$(dirname "$dest_path")"
    if [[ -f "$dest_path" ]]; then
      local vault_subpath="${BINARY_VAULT_DIR}/orig-${stamp}/${rel_path}"
      mkdir -p "$(dirname "$vault_subpath")"
      cp -a "$dest_path" "$vault_subpath"
      backed_up=$((backed_up + 1))
    fi
    cp -a "$src_file" "$dest_path"
    chmod 755 "$dest_path"
    installed=$((installed + 1))
  done < <(find "$linux32_dir" -type f -print0)

  log "Backed up ${backed_up} existing file(s) to ${BINARY_VAULT_DIR}/orig-${stamp}/"
  log "Installed ${installed} ReHLDS file(s) into ${SERVERFILES_DIR}."

  # Also stash a copy of the whole verified linux32 tree as a known-good
  # reference for a future repair/update script, without re-downloading.
  cp -a "$linux32_dir" "${BINARY_VAULT_DIR}/verified-${tag}"
  # Also stash a fixed-name copy the update wrapper can restore from
  # without re-downloading/needing GitHub reachable at cron time.
  rm -rf "${BINARY_VAULT_DIR}/verified-latest"
  cp -a "$linux32_dir" "${BINARY_VAULT_DIR}/verified-latest"

  rm -rf "$work_dir"

  # Validation: the two files most critical to a working server, plus a
  # sanity check that we actually installed the full expected set.
  [[ -x "${SERVERFILES_DIR}/engine_i486.so" ]] || fail "engine_i486.so missing/not executable at ${SERVERFILES_DIR} after swap — check permissions."
  [[ -x "${SERVERFILES_DIR}/filesystem_stdio.so" ]] || fail "filesystem_stdio.so missing/not executable at ${SERVERFILES_DIR} after swap — check permissions."
  [[ -x "${SERVERFILES_DIR}/hlds_linux" ]] || warn "hlds_linux missing/not executable at ${SERVERFILES_DIR} after swap — expected it as part of the ReHLDS archive."
  (( installed >= 7 )) || warn "Only installed ${installed} file(s) from the ReHLDS archive — expected 8 (7 flat + director.so). Archive contents may have changed; double-check ${SERVERFILES_DIR} manually."
  log "ReHLDS ${tag} installed at ${SERVERFILES_DIR} (signature verified: $([[ "$verified" == "1" ]] && echo yes || echo no))."

  # Non-blocking manual engine-version checkpoint (automated confirmation
  # isn't reliable — see design discussion).
  warn "MANUAL CHECK RECOMMENDED: automated confirmation of the underlying HLDS engine build (must be <= 8684, pre-anniversary) isn't reliable from install output alone."
  warn "After starting the server, check the console/log banner for the engine version and confirm it does NOT indicate a post-anniversary build. See https://github.com/rehlds/ReHLDS for details on compatible engine versions."
  confirm "Acknowledge the above and continue?" || fail "Stopped for manual verification per your choice."
}

# ── shared helpers for the addon components ─────────────────────────────

# resolve_release_asset <label> <releases_api> <pinned_tag> <asset_regex> <out_tag_var> <out_path_var>
# STUBBED: no GitHub API involved. Resolves to the pinned tag (for logging)
# and a local file path found via resolve_local_asset. <releases_api> is
# accepted but ignored, kept so call sites below don't need reshuffling.
resolve_release_asset() {
  local label="$1" api="$2" pinned="$3" regex="$4" out_tag="$5" out_path="$6"
  [[ "$USE_LATEST" != "yes" ]] || warn "${label}: --latest is ignored — downloads are stubbed out, installing from LOCAL_ASSET_DIR regardless."
  [[ -n "$pinned" ]] || fail "${label}: no pinned tag set in env.conf."

  local path
  resolve_local_asset "$label" "$pinned" "$regex" path

  printf -v "$out_tag" '%s' "$pinned"
  printf -v "$out_path" '%s' "$path"
}

# overlay_dir <label> <src_dir> <dest_dir> <vault_subdir> [exclude_bash_regex]
# Walks every file under src_dir, backs up any existing file at the
# corresponding dest_dir path into BINARY_VAULT_DIR/vault_subdir, then
# copies the new file in. Same tested pattern as the ReHLDS swap, factored
# out for reuse by the addon components below.
overlay_dir() {
  local label="$1" src_dir="$2" dest_dir="$3" vault_subdir="$4" exclude_regex="${5:-}"
  local stamp rel_path dest_path src_file vault_path backed_up=0 installed=0
  stamp="$(date +%Y%m%d-%H%M%S)"

  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_dir"/}"
    if [[ -n "$exclude_regex" && "$rel_path" =~ $exclude_regex ]]; then
      continue
    fi
    dest_path="${dest_dir}/${rel_path}"
    mkdir -p "$(dirname "$dest_path")"
    if [[ -f "$dest_path" ]]; then
      vault_path="${BINARY_VAULT_DIR}/${vault_subdir}/orig-${stamp}/${rel_path}"
      mkdir -p "$(dirname "$vault_path")"
      cp -a "$dest_path" "$vault_path"
      backed_up=$((backed_up + 1))
    fi
    cp -a "$src_file" "$dest_path"
    case "$rel_path" in
      *.so|*.so.*) chmod 755 "$dest_path" ;;
      *.*) chmod 644 "$dest_path" ;;
      *) chmod 755 "$dest_path" ;;   # no extension: treat as a binary (e.g. hlds_linux)
    esac
    installed=$((installed + 1))
  done < <(find "$src_dir" -type f -print0)

  log "${label}: installed ${installed} file(s) (${backed_up} backed up) into ${dest_dir}"
  (( installed > 0 )) || fail "${label}: no files found to install from ${src_dir} — archive layout may have changed."
}

# ── ReGameDLL_CS ─────────────────────────────────────────────────────────

step_regamedll_install() {
  if [[ "$INSTALL_REGAMEDLL_FLAG" != "yes" ]]; then
    log "Step: ReGameDLL_CS — SKIPPED (--no-regamedll)"
    return 0
  fi
  log "Step: ReGameDLL_CS"

  local tag archive_path
  resolve_release_asset "ReGameDLL_CS" "$REGAMEDLL_RELEASES_API" "$REGAMEDLL_PINNED_TAG" "$REGAMEDLL_ASSET_REGEX" tag archive_path

  local work_dir archive_file
  work_dir="$(mktemp -d)"
  archive_file="${work_dir}/$(basename "$archive_path")"
  cp -a "$archive_path" "$archive_file"

  local extract_dir="${work_dir}/extracted"
  mkdir -p "$extract_dir"
  unzip -q "$archive_file" -d "$extract_dir"

  local cstrike_src
  cstrike_src="$(find "$extract_dir" -type d -path '*/linux32/cstrike' -print -quit)"
  [[ -n "$cstrike_src" ]] || fail "Could not find a linux32/cstrike directory inside the ReGameDLL_CS archive — archive layout may have changed upstream."

  confirm "About to replace cs.so (and delta.lst/game.cfg/game_init.cfg) under ${CSTRIKE_DIR} with ReGameDLL_CS ${tag} (from local copy, NOT cryptographically verified — see env.conf). Proceed?" \
    || fail "ReGameDLL_CS install declined — this installer's stack requires it."

  overlay_dir "ReGameDLL_CS" "$cstrike_src" "$CSTRIKE_DIR" "regamedll"
  # Stash a fixed-name copy for the update wrapper to restore from later
  # without re-downloading.
  rm -rf "${BINARY_VAULT_DIR}/regamedll/verified-latest"
  cp -a "$cstrike_src" "${BINARY_VAULT_DIR}/regamedll/verified-latest"
  rm -rf "$work_dir"

  [[ -f "${CSTRIKE_DIR}/dlls/cs.so" ]] || fail "cs.so missing at ${CSTRIKE_DIR}/dlls after ReGameDLL_CS install."
  log "ReGameDLL_CS ${tag} installed."
}

# ── Metamod-R ────────────────────────────────────────────────────────────

edit_liblist_gam_for_metamod() {
  local liblist="${CSTRIKE_DIR}/liblist.gam"
  [[ -f "$liblist" ]] || fail "liblist.gam not found at ${liblist} — was the LinuxGSM install step run first?"

  if grep -q 'addons/metamod/metamod_i386.so' "$liblist"; then
    log "liblist.gam already points at Metamod-R — not editing again."
    return 0
  fi

  cp -a "$liblist" "${BINARY_VAULT_DIR}/liblist.gam.orig-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^gamedll_linux' "$liblist"; then
    sed -i 's|^gamedll_linux.*|gamedll_linux		"addons/metamod/metamod_i386.so"|' "$liblist"
  else
    printf 'gamedll_linux\t\t"addons/metamod/metamod_i386.so"\n' >> "$liblist"
  fi

  grep -q 'addons/metamod/metamod_i386.so' "$liblist" \
    || fail "Failed to edit liblist.gam as expected — check ${liblist} manually (a backup was saved to ${BINARY_VAULT_DIR})."
  log "liblist.gam updated: gamedll_linux -> addons/metamod/metamod_i386.so (backup saved)."
}

step_metamod_install() {
  log "Step: Metamod-R"

  local tag archive_path
  resolve_release_asset "Metamod-R" "$METAMOD_R_RELEASES_API" "$METAMOD_R_PINNED_TAG" "$METAMOD_R_ASSET_REGEX" tag archive_path

  local work_dir archive_file
  work_dir="$(mktemp -d)"
  archive_file="${work_dir}/$(basename "$archive_path")"
  cp -a "$archive_path" "$archive_file"

  local extract_dir="${work_dir}/extracted"
  mkdir -p "$extract_dir"
  unzip -q "$archive_file" -d "$extract_dir"
  # Zip root already mirrors the gamedir-relative layout (addons/metamod/...).

  confirm "About to install Metamod-R ${tag} into ${CSTRIKE_DIR}/addons/metamod and edit liblist.gam to load it (from local copy, NOT cryptographically verified). Proceed?" \
    || fail "Metamod-R is required by this installer's stack (AMX Mod X/ReAPI/Reunion all load through it) — cannot continue without it."

  overlay_dir "Metamod-R" "$extract_dir" "$CSTRIKE_DIR" "metamod" '\.dll$'
  rm -rf "$work_dir"

  [[ -f "${CSTRIKE_DIR}/addons/metamod/metamod_i386.so" ]] || fail "metamod_i386.so missing at ${CSTRIKE_DIR}/addons/metamod after install."
  edit_liblist_gam_for_metamod
  log "Metamod-R ${tag} installed and registered."
}

# append_line_if_missing <label> <file> <line> <match_regex>
# Idempotent ini-file registration: creates the file if it doesn't exist,
# appends the line if a matching entry isn't already present, backs up
# before any real edit. Used for plugins.ini (AMX Mod X) and modules.ini
# (ReAPI) registration.
append_line_if_missing() {
  local label="$1" file="$2" line="$3" match_regex="$4"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -q "$match_regex" "$file"; then
    log "${label}: ${file} already contains a matching entry — not editing again."
    return 0
  fi
  if [[ -f "$file" ]]; then
    cp -a "$file" "${BINARY_VAULT_DIR}/$(basename "$file").orig-$(date +%Y%m%d-%H%M%S)"
  else
    touch "$file"
    log "${label}: ${file} did not exist — created."
  fi
  printf '%s\n' "$line" >> "$file"
  grep -q "$match_regex" "$file" || fail "${label}: failed to register expected line in ${file} — check it manually."
  log "${label}: registered in ${file}."
}

# ── AMX Mod X ────────────────────────────────────────────────────────────

step_amxmodx_install() {
  log "Step: AMX Mod X"

  local tag archive_path
  resolve_release_asset "AMX Mod X" "$AMXMODX_RELEASES_API" "$AMXMODX_PINNED_TAG" "$AMXMODX_ASSET_REGEX" tag archive_path

  local work_dir archive_file
  work_dir="$(mktemp -d)"
  archive_file="${work_dir}/$(basename "$archive_path")"
  cp -a "$archive_path" "$archive_file"

  local extract_dir="${work_dir}/extracted"
  mkdir -p "$extract_dir"
  tar -xzf "$archive_file" -C "$extract_dir"
  # Archive root already mirrors the gamedir-relative layout (addons/amxmodx/...).

  confirm "About to install AMX Mod X ${tag} into ${CSTRIKE_DIR}/addons/amxmodx and register it in plugins.ini (from local copy, NOT cryptographically verified). Proceed?" \
    || fail "AMX Mod X is required by this installer's stack (ReAPI and most plugins load through it) — cannot continue without it."

  overlay_dir "AMX Mod X" "$extract_dir" "$CSTRIKE_DIR" "amxmodx" '\.dll$'
  rm -rf "$work_dir"

  [[ -f "${CSTRIKE_DIR}/addons/amxmodx/dlls/amxmodx_mm_i386.so" ]] \
    || fail "amxmodx_mm_i386.so missing at ${CSTRIKE_DIR}/addons/amxmodx/dlls after install."

  append_line_if_missing "AMX Mod X" "${CSTRIKE_DIR}/addons/metamod/plugins.ini" \
    "linux addons/amxmodx/dlls/amxmodx_mm_i386.so" \
    "addons/amxmodx/dlls/amxmodx_mm_i386.so"

  log "AMX Mod X ${tag} installed and registered."
}

# ── ReAPI ────────────────────────────────────────────────────────────────

step_reapi_install() {
  log "Step: ReAPI"

  local tag archive_path
  resolve_release_asset "ReAPI" "$REAPI_RELEASES_API" "$REAPI_PINNED_TAG" "$REAPI_ASSET_REGEX" tag archive_path

  local work_dir archive_file
  work_dir="$(mktemp -d)"
  archive_file="${work_dir}/$(basename "$archive_path")"
  cp -a "$archive_path" "$archive_file"

  local extract_dir="${work_dir}/extracted"
  mkdir -p "$extract_dir"
  unzip -q "$archive_file" -d "$extract_dir"

  confirm "About to install ReAPI ${tag} into ${CSTRIKE_DIR}/addons/amxmodx (from local copy, NOT cryptographically verified). Proceed?" \
    || { warn "ReAPI install declined — skipping (plugins depending on ReAPI natives will not load)."; rm -rf "$work_dir"; return 0; }

  overlay_dir "ReAPI" "$extract_dir" "$CSTRIKE_DIR" "reapi" '\.dll$'
  rm -rf "$work_dir"

  [[ -f "${CSTRIKE_DIR}/addons/amxmodx/modules/reapi_amxx_i386.so" ]] || fail "reapi_amxx_i386.so missing at ${CSTRIKE_DIR}/addons/amxmodx/modules after install."

  append_line_if_missing "ReAPI" "${CSTRIKE_DIR}/addons/amxmodx/configs/modules.ini" \
    "reapi" '^reapi$'

  log "ReAPI ${tag} installed and registered."
}

# ── Reunion ──────────────────────────────────────────────────────────────

step_reunion_install() {
  if [[ "$INSTALL_REUNION_FLAG" != "yes" ]]; then
    log "Step: Reunion — SKIPPED (--no-reunion)"
    return 0
  fi
  log "Step: Reunion"

  local tag archive_path
  resolve_release_asset "Reunion" "$REUNION_RELEASES_API" "$REUNION_PINNED_TAG" "$REUNION_ASSET_REGEX" tag archive_path

  local work_dir archive_file
  work_dir="$(mktemp -d)"
  archive_file="${work_dir}/$(basename "$archive_path")"
  cp -a "$archive_path" "$archive_file"

  local extract_dir="${work_dir}/extracted"
  mkdir -p "$extract_dir"
  unzip -q "$archive_file" -d "$extract_dir"

  confirm "About to install Reunion ${tag} (non-Steam client support): creates ${CSTRIKE_DIR}/addons/reunion, edits plugins.ini, copies reunion.cfg (from local copy, NOT cryptographically verified). Proceed?" \
    || { warn "Reunion install declined — skipping (optional component; non-Steam clients won't be able to connect)."; rm -rf "$work_dir"; return 0; }

  local so_src cfg_src
  so_src="$(find "$extract_dir" -name 'reunion_mm_i386.so' -print -quit)"
  cfg_src="$(find "$extract_dir" -name 'reunion.cfg' -print -quit)"
  [[ -n "$so_src" ]] || fail "reunion_mm_i386.so not found inside the Reunion archive — layout may have changed upstream."
  [[ -n "$cfg_src" ]] || fail "reunion.cfg not found inside the Reunion archive — layout may have changed upstream."

  mkdir -p "${CSTRIKE_DIR}/addons/reunion"
  cp -a "$so_src" "${CSTRIKE_DIR}/addons/reunion/reunion_mm_i386.so"
  chmod 755 "${CSTRIKE_DIR}/addons/reunion/reunion_mm_i386.so"

  if [[ -f "${CSTRIKE_DIR}/reunion.cfg" ]]; then
    warn "reunion.cfg already exists at ${CSTRIKE_DIR} — not overwriting it, to preserve any existing config. Delete it manually first if you want the fresh upstream default."
  else
    cp -a "$cfg_src" "${CSTRIKE_DIR}/reunion.cfg"
    chmod 644 "${CSTRIKE_DIR}/reunion.cfg"
    warn "reunion.cfg installed with upstream defaults. SteamIdHashSalt should be replaced with a locally-generated random value, not left at any shipped default — this happens in the cvar/hardening step (not yet implemented)."
  fi

  local plugins_ini="${CSTRIKE_DIR}/addons/metamod/plugins.ini"
  [[ -f "$plugins_ini" ]] || fail "plugins.ini not found at ${plugins_ini} — was the Metamod-R step run first?"
  if grep -q 'addons/reunion/reunion_mm_i386.so' "$plugins_ini"; then
    log "plugins.ini already references Reunion — not editing again."
  else
    cp -a "$plugins_ini" "${BINARY_VAULT_DIR}/plugins.ini.orig-$(date +%Y%m%d-%H%M%S)"
    { printf 'linux addons/reunion/reunion_mm_i386.so\n'; cat "$plugins_ini"; } > "${plugins_ini}.new"
    mv "${plugins_ini}.new" "$plugins_ini"
    grep -q 'addons/reunion/reunion_mm_i386.so' "$plugins_ini" \
      || fail "Failed to edit plugins.ini as expected — check ${plugins_ini} manually (a backup was saved to ${BINARY_VAULT_DIR})."
    log "plugins.ini updated: Reunion line prepended (backup saved)."
  fi

  rm -rf "$work_dir"
  log "Reunion ${tag} installed."
}

# ── Hardened mode (--hardened) — STUBBED, not implemented ────────────────
#
# This step intentionally does nothing yet beyond logging. Implementing the
# actual iptables rules needs real research into current A2S
# amplification/flood mitigation practice (the source plan flagged this as
# the one component prone to false positives — hiding the server from
# master-server queries/legitimate clients if done wrong), which wasn't
# done yet. Notes on what this step should eventually cover:
#
#   - Rate-limit incoming UDP to GAME_PORT_UDP (A2S_INFO/A2S_PLAYER/
#     A2S_RULES query floods are the typical abuse vector for GoldSrc
#     servers) — likely via iptables `hashlimit` or `recent` module,
#     matched on new/query-sized packets rather than all game traffic
#     (real player traffic must not be rate-limited the same way).
#   - Needs to be scoped narrowly enough not to throttle legitimate churn
#     during e.g. a full 32-player map change, where many clients query/
#     reconnect close together — this is exactly the "breaking" behavior
#     the original research flagged, so whatever rule set lands here needs
#     real testing against a populated server before being a default.
#   - Should almost certainly be additive to, not a replacement for, the
#     plain ufw allow rule bootstrap-root.sh already sets up for
#     GAME_PORT_UDP — this step would add a stricter iptables rule in
#     front of/alongside that, not instead of it.
#   - Whatever rule set is chosen needs a documented rollback (a single
#     command or flag to remove just these rules) since it's the
#     EXPERIMENTAL flag — see bootstrap-root.sh's step_firewall for the
#     "labeled experimental" precedent this should follow.
#   - Worth checking whether ReHLDS's own sv_rehlds_* rate-limit cvars
#     (movecmdrate/stringcmdrate, already handled in the not-yet-built cvar
#     step) make some of this redundant at the engine level, vs. genuinely
#     needing a network-layer answer for pure A2S query floods that never
#     reach the game engine at all.
#
step_hardened_iptables() {
  if [[ "$HARDENED_FLAG" != "yes" ]]; then
    return 0
  fi
  warn "Step: --hardened iptables — NOT IMPLEMENTED YET. Skipping. See the comment block above step_hardened_iptables() in this script for what's intended here. No iptables rules were changed."
}

# ── Server config: hardening cvars, rcon password, Reunion salt ─────────

# set_cvar_unquoted <file> <key> <value>
# server.cfg here uses plain "key value" with no quotes (confirmed against
# a real config, e.g. "sv_minrate 5000"). Idempotent: replaces an existing
# line for the same key rather than appending a duplicate.
set_cvar_unquoted() {
  local file="$1" key="$2" value="$3"
  if grep -q "^[[:space:]]*${key}[[:space:]]" "$file" 2>/dev/null; then
    sed -i "s|^[[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$file"
  else
    printf '%s %s\n' "$key" "$value" >> "$file"
  fi
}

generate_random_token() {
  local len="${1:-20}"
  # openssl is present on essentially every Debian install; fall back to
  # /dev/urandom if it's somehow missing.
  if command -v openssl &>/dev/null; then
    openssl rand -hex "$((len / 2 + 1))" | head -c "$len"
  else
    head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$len"
  fi
}

step_configure_server() {
  log "Step: server.cfg cvars, rcon password, Reunion salt"

  local server_cfg="${CSTRIKE_DIR}/server.cfg"
  if [[ ! -f "$server_cfg" ]]; then
    touch "$server_cfg"
    log "server.cfg did not exist at ${server_cfg} — created."
  fi

  # sv_rehlds_force_dlmax: its own y/n, no env.conf default (per design).
  local dlmax_value="0"
  if confirm "Enable sv_rehlds_force_dlmax (forces cl_dlmax=1024, avoids download fragmentation)?"; then
    dlmax_value="1"
  fi

  local -a cvar_lines=(
    "sv_rehlds_maxclients_from_single_ip ${CVAR_MAXCLIENTS_FROM_SINGLE_IP}"
    "sv_rehlds_movecmdrate_max_avg ${CVAR_MOVECMDRATE_MAX_AVG}"
    "sv_rehlds_movecmdrate_avg_punish ${CVAR_MOVECMDRATE_AVG_PUNISH}"
    "sv_rehlds_movecmdrate_max_burst ${CVAR_MOVECMDRATE_MAX_BURST}"
    "sv_rehlds_movecmdrate_burst_punish ${CVAR_MOVECMDRATE_BURST_PUNISH}"
    "sv_rehlds_stringcmdrate_max_avg ${CVAR_STRINGCMDRATE_MAX_AVG}"
    "sv_rehlds_stringcmdrate_avg_punish ${CVAR_STRINGCMDRATE_AVG_PUNISH}"
    "sv_rehlds_stringcmdrate_max_burst ${CVAR_STRINGCMDRATE_MAX_BURST}"
    "sv_rehlds_stringcmdrate_burst_punish ${CVAR_STRINGCMDRATE_BURST_PUNISH}"
    "sv_rehlds_force_dlmax ${dlmax_value}"
  )

  log "About to write the following cvars to ${server_cfg}:"
  local line
  for line in "${cvar_lines[@]}"; do
    log "    ${line}"
  done

  if confirm "Write these cvars to ${server_cfg}?"; then
    cp -a "$server_cfg" "${BINARY_VAULT_DIR}/server.cfg.orig-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    local key value
    for line in "${cvar_lines[@]}"; do
      key="${line%% *}"
      value="${line#* }"
      set_cvar_unquoted "$server_cfg" "$key" "$value"
    done
    log "Hardening cvars written to ${server_cfg}."
  else
    warn "Skipped writing hardening cvars — server.cfg left unchanged."
  fi

  # rcon password: never empty, per design.
  local rcon_password="$RCON_PASSWORD_ARG"
  if [[ -z "$rcon_password" ]]; then
    if [[ "$UNATTENDED" == "yes" ]]; then
      rcon_password="$(generate_random_token 20)"
      log "No --rcon-password given in unattended mode — generated a random rcon password."
    else
      local choice
      read -r -p "Set your own rcon password, or auto-generate one? [s/g] (default: g) " choice
      if [[ "$choice" =~ ^[Ss]$ ]]; then
        read -r -s -p "Enter rcon password (input hidden; avoid double-quote characters): " rcon_password
        echo
      else
        rcon_password="$(generate_random_token 20)"
        log "Generated a random rcon password."
      fi
    fi
  fi
  [[ -n "$rcon_password" ]] || fail "rcon password is empty — refusing to write an empty rcon_password. Re-run and provide one."
  [[ "$rcon_password" != *'"'* ]] || fail "rcon password contains a double-quote character — this would break server.cfg's quoted rcon_password field. Re-run and choose a password without quote characters."
  set_cvar_unquoted "$server_cfg" "rcon_password" "\"${rcon_password}\""
  log "rcon_password set in ${server_cfg} (quoted, not printed here — see the file, or './${LGSM_SERVER_NAME} details', to retrieve it)."

  # Reunion SteamIdHashSalt: generated locally, never fetched/typed from any
  # third party. Confirmed format is INI-style "SteamIdHashSalt = value"
  # (NOT the quoted engine-cvar style server.cfg uses) — different parser,
  # different file. Recommended length >= 32 chars; generate_random_token
  # 32 already meets that.
  local reunion_cfg="${CSTRIKE_DIR}/reunion.cfg"
  if [[ -f "$reunion_cfg" ]]; then
    if grep -qiE '^[[:space:]]*SteamIdHashSalt[[:space:]]*=' "$reunion_cfg"; then
      local salt
      salt="$(generate_random_token 32)"
      cp -a "$reunion_cfg" "${BINARY_VAULT_DIR}/reunion.cfg.orig-$(date +%Y%m%d-%H%M%S)"
      if sed -i -E "s|^([[:space:]]*SteamIdHashSalt[[:space:]]*=)[[:space:]]*.*|\1 ${salt}|I" "$reunion_cfg" \
        && grep -qiE "^[[:space:]]*SteamIdHashSalt[[:space:]]*=[[:space:]]${salt}[[:space:]]*$" "$reunion_cfg"; then
        log "Reunion SteamIdHashSalt set to a locally-generated random value (32 chars)."
      else
        warn "Could not confirm SteamIdHashSalt was updated in ${reunion_cfg}. Check the file manually and set it to a random value >= 32 chars yourself — do not leave it empty or at any shipped default."
      fi
    else
      warn "SteamIdHashSalt line not found in ${reunion_cfg} — could not set it automatically. Check the file manually."
    fi
  fi
}

# ── Update-safety wrapper install + cron ─────────────────────────────────

step_install_update_wrapper() {
  log "Step: install update-safety wrapper"

  mkdir -p "$WRAPPER_INSTALL_DIR"
  cp -a "${SCRIPT_DIR}/env.conf" "${WRAPPER_INSTALL_DIR}/env.conf"
  cp -a "${SCRIPT_DIR}/wrapper-update.sh" "$WRAPPER_INSTALL_PATH"
  chmod +x "$WRAPPER_INSTALL_PATH"
  log "Wrapper installed at ${WRAPPER_INSTALL_PATH} (with its own copy of env.conf alongside it)."

  local current_cron
  current_cron="$(crontab -l 2>/dev/null || true)"

  # Remove LinuxGSM's own "./csserver update" cron entry, if present — this
  # is the entry that can silently overwrite ReHLDS/ReGameDLL_CS.
  if grep -qE "${LGSM_SERVER_NAME}[[:space:]]+update([[:space:]]|\$)" <<<"$current_cron"; then
    if confirm "Found an existing cron entry running './${LGSM_SERVER_NAME} update' directly (editing crontab for $(id -un)). This is the entry that can silently overwrite ReHLDS/ReGameDLL_CS files. Remove it?"; then
      local tmp_cron
      tmp_cron="$(mktemp)"
      grep -vE "${LGSM_SERVER_NAME}[[:space:]]+update([[:space:]]|\$)" <<<"$current_cron" > "$tmp_cron"
      crontab "$tmp_cron"
      rm -f "$tmp_cron"
      log "Removed the existing './${LGSM_SERVER_NAME} update' cron entry."
      current_cron="$(crontab -l 2>/dev/null || true)"
    else
      warn "Left the existing './${LGSM_SERVER_NAME} update' cron entry in place — it can still overwrite ReHLDS/ReGameDLL_CS files independently of this wrapper. Consider removing it manually."
    fi
  else
    log "No existing './${LGSM_SERVER_NAME} update' cron entry found — nothing to remove."
  fi

  # Add our own cron entry calling the wrapper instead.
  if grep -qF "$WRAPPER_INSTALL_PATH" <<<"$current_cron"; then
    log "Cron already has an entry for ${WRAPPER_INSTALL_PATH} — not adding a duplicate."
    return 0
  fi
  local cron_line="${WRAPPER_CRON_SCHEDULE} ${WRAPPER_INSTALL_PATH} >> ${SERVICE_HOME}/logs/wrapper-update.log 2>&1"
  if confirm "Add a cron entry to run the safe update wrapper (editing crontab for $(id -un)): '${cron_line}'?"; then
    mkdir -p "${SERVICE_HOME}/logs"
    local tmp_cron
    tmp_cron="$(mktemp)"
    {
      [[ -n "$current_cron" ]] && printf '%s\n' "$current_cron"
      printf '%s\n' "$cron_line"
    } > "$tmp_cron"
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    log "Cron entry added — wrapper now runs on schedule '${WRAPPER_CRON_SCHEDULE}', logging to ${SERVICE_HOME}/logs/wrapper-update.log."
  else
    warn "Skipped adding a cron entry — the wrapper is installed at ${WRAPPER_INSTALL_PATH} but won't run automatically. Add your own cron entry, or run it manually when you want to update safely."
  fi
}

# ── main ─────────────────────────────────────────────────────────────────

main() {
  require_non_root
  log "CS 1.6 ReHLDS installer — server install phase (user: $(id -un))"
  log "Unattended: ${UNATTENDED} | Latest: ${USE_LATEST} | ReGameDLL: ${INSTALL_REGAMEDLL_FLAG} | Reunion: ${INSTALL_REUNION_FLAG} | Hardened: ${HARDENED_FLAG}"
  log "Downloads are stubbed out — components install from local files in: ${LOCAL_ASSET_DIR}"
  [[ "$USE_LATEST" != "yes" ]] || warn "--latest was passed but is ignored while downloads are stubbed out."
  if [[ -n "$RCON_PASSWORD_ARG" ]]; then
    log "rcon password override supplied via --rcon-password (will be used once the cvar-write step is implemented)."
  fi

  step_linuxgsm_install
  step_rehlds_swap
  step_regamedll_install
  step_metamod_install
  step_amxmodx_install
  step_reapi_install
  step_reunion_install
  step_configure_server
  step_install_update_wrapper
  step_hardened_iptables

  log "Phase 2 complete: LinuxGSM + ReHLDS + ReGameDLL_CS + Metamod-R + AMX Mod X + ReAPI + Reunion + server.cfg/rcon/salt + update-safety wrapper."
  log "Not yet implemented: --hardened iptables (stubbed, see comments)."
}

main "$@"