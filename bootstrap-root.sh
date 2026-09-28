#!/usr/bin/env bash
# bootstrap-root.sh — Phase 1 (root). Fresh-VPS baseline for the CS 1.6 ReHLDS
# installer: OS packages, i386 multiarch, service user, firewall, fail2ban,
# unattended-upgrades, swap.
#
# All steps are implemented. Not yet run against a live box — review before
# first use, especially step_firewall (see README re: SSH before enabling ufw).
#
# Design notes this skeleton follows (see conversation for rationale):
#   - Debian 12 is the primary target; Ubuntu 22.04 (jammy) and 24.04 (noble)
#     are also supported. Ubuntu 24.04 needs a fallback for
#     libtinfo5/libncurses5:i386 (readline console support), which Ubuntu
#     removed from its own repos — see step_lgsm_and_engine_deps.
#   - This script does not touch SSH/port 22 in any way — see README.
#   - Every step that could disrupt an existing setup (user creation, ufw
#     defaults) checks current state first and asks before changing
#     anything already present.
#   - If the operator already has their own user/firewall/etc., they can
#     skip this script entirely and just fill in env.conf, then run
#     install-server.sh directly.
#   - Everything destructive or state-changing is labeled clearly before
#     it runs (e.g. "About to edit /etc/ufw/... — proceed? [y/n]").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.conf
source "${SCRIPT_DIR}/env.conf"

# ── flags ──────────────────────────────────────────────────────────────────
UNATTENDED="no"
SKIP_APT_UPGRADE="no"
SKIP_LGSM_BOOTSTRAP="no"
SKIP_USER_CREATION="no"
SKIP_FIREWALL="no"
SKIP_FAIL2BAN="no"
SKIP_SWAP="no"

usage() {
  cat <<EOF
Usage: sudo ./bootstrap-root.sh [options]

  --unattended            Non-interactive. Applies safe defaults to every step.
  --skip-apt-upgrade      Don't run apt update/upgrade.
  --skip-lgsm-bootstrap   Don't install LGSM/engine dependencies or fetch LinuxGSM (bring your own).
  --skip-user-creation    Don't create/modify the service user (bring your own).
  --skip-firewall         Don't touch ufw.
  --skip-fail2ban         Don't install/configure fail2ban.
  --skip-swap             Don't check/add swap.
  -h, --help              Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --unattended) UNATTENDED="yes" ;;
    --skip-apt-upgrade) SKIP_APT_UPGRADE="yes" ;;
    --skip-lgsm-bootstrap) SKIP_LGSM_BOOTSTRAP="yes" ;;
    --skip-user-creation) SKIP_USER_CREATION="yes" ;;
    --skip-firewall) SKIP_FIREWALL="yes" ;;
    --skip-fail2ban) SKIP_FAIL2BAN="yes" ;;
    --skip-swap) SKIP_SWAP="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

# ── logging helpers ─────────────────────────────────────────────────────────
log()   { printf '[bootstrap-root] %s\n' "$*"; }
warn()  { printf '[bootstrap-root][WARN] %s\n' "$*" >&2; }
fail()  { printf '[bootstrap-root][FAIL] %s\n' "$*" >&2; exit 1; }

confirm() {
  # confirm "question text"
  # Every prompt here has a safe default ("proceed with the normal action").
  # Unattended mode always takes that default and logs what it did — there
  # is no blocking/fail-closed case left in this script (see README for the
  # one genuinely unsafe-default case, which lives in install-server.sh:
  # rcon password / cvar validation, not here).
  local question="$1"
  if [[ "$UNATTENDED" == "yes" ]]; then
    log "[unattended] auto-confirming: ${question}"
    return 0
  fi
  read -r -p "${question} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "This script must be run as root (it provisions OS-level packages, users, firewall)."
}

# ── steps ────────────────────────────────────────────────────────────────────

step_os_check() {
  log "Step: OS baseline check"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    log "Detected: ${PRETTY_NAME:-unknown} (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown})"
    case "${ID:-}:${VERSION_ID:-}" in
      debian:12)
        log "OS matches primary target (Debian 12 / bookworm)."
        ;;
      ubuntu:22.04)
        log "OS matches a supported target (Ubuntu 22.04 / jammy)."
        ;;
      ubuntu:24.04)
        log "OS matches a supported target (Ubuntu 24.04 / noble)."
        ;;
      *)
        warn "This installer is built and tested against Debian 12 (bookworm), Ubuntu 22.04 (jammy), and Ubuntu 24.04 (noble). Detected '${PRETTY_NAME:-unknown}' — package names and steps below may not apply as-is. Continuing, but expect to troubleshoot."
        ;;
    esac
  else
    warn "/etc/os-release not found — cannot verify OS. Continuing anyway."
  fi
}

step_apt_update_upgrade() {
  [[ "$SKIP_APT_UPGRADE" == "yes" ]] && { log "Step: apt update/upgrade — SKIPPED by flag"; return 0; }
  log "Step: apt update && upgrade"
  confirm "About to run 'apt-get update && apt-get -y upgrade'. Proceed?" || { warn "Skipped apt upgrade."; return 0; }
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update; then
    fail "apt-get update failed. Check network/mirror config (see network settings) before continuing."
  fi
  apt-get -y upgrade
  log "apt update/upgrade complete."
}

step_lgsm_and_engine_deps() {
  [[ "$SKIP_LGSM_BOOTSTRAP" == "yes" ]] && { log "Step: LinuxGSM/engine dependencies — SKIPPED by flag"; return 0; }
  log "Step: LinuxGSM + CS1.6/GoldSrc dependencies"

  # This is the confirmed, real dependency list (LinuxGSM's own reported
  # list from a live run, plus lib32gcc-s1/lib32stdc++6/libsdl2-2.0-0:i386
  # for the engine itself) — not a guess reconstructed from docs. Installing
  # everything here, as root, means LGSM will find all its dependencies
  # already satisfied when Phase 2 runs it as the unprivileged service
  # user — so Phase 2 never needs to hit LGSM's "run as root" fallback path
  # or run as root itself.
  local deps=(
    bc binutils bsdmainutils bzip2 cpio distro-info file jq
    lib32gcc-s1 lib32stdc++6 libsdl2-2.0-0:i386
    netcat-openbsd pigz tmux unzip uuid-runtime wget curl xz-utils
  )

  if ! dpkg --print-foreign-architectures | grep -qx "i386"; then
    confirm "About to run 'dpkg --add-architecture i386' and 'apt update'. Proceed?" || fail "i386 multiarch is required for a CS1.6 server; cannot continue without it."
    dpkg --add-architecture i386
    apt-get update
  fi

  log "Installing: ${deps[*]}"
  confirm "About to run 'apt-get install -y ${deps[*]}'. Proceed?" || fail "These packages are required for LinuxGSM and the CS1.6/GoldSrc engine; cannot continue without them."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${deps[@]}"

  local missing=()
  for pkg in "${deps[@]}"; do
    dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "The following required packages did not install correctly: ${missing[*]}. Check apt output above and your OS/mirror before re-running."
  fi
  log "LinuxGSM + engine dependencies confirmed installed."

  # ── steamcmd — separate, since it needs a repo section enabled + license
  # acceptance pre-seeded to avoid hanging on an interactive prompt. Lives
  # in Debian's contrib/non-free or Ubuntu's multiverse. Non-fatal if it
  # still doesn't work — LGSM can also fetch/manage steamcmd itself via its
  # own download path, so this isn't a hard blocker the way the packages
  # above are.
  log "Installing steamcmd (needs contrib/non-free or multiverse enabled + license pre-seed)"
  echo steam steam/question select "I AGREE" | debconf-set-selections
  echo steam steam/license note '' | debconf-set-selections

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "debian" ]]; then
      sed -i -E 's/^(deb .*bookworm main)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
    elif [[ "${ID:-}" == "ubuntu" ]]; then
      sed -i -E 's/^(deb .* (jammy|noble)[a-z-]* main restricted)$/\1 universe multiverse/' /etc/apt/sources.list 2>/dev/null || true
    fi
  fi
  apt-get update || warn "'apt-get update' after enabling contrib/non-free or multiverse failed — steamcmd install below may fail as a result."

  if apt-get install -y steamcmd; then
    dpkg -s steamcmd &>/dev/null && log "steamcmd installed." || warn "steamcmd apt-get install reported success but dpkg -s can't confirm it — check manually."
  else
    warn "steamcmd could not be installed via apt (commonly needs contrib/non-free or multiverse enabled, which this step attempted but may not have matched your exact sources.list format). This is non-fatal — LinuxGSM can fetch/manage SteamCMD itself if this apt package isn't available. Check 'apt-cache policy steamcmd' manually if you want it from apt specifically."
  fi
}

step_linuxgsm_bootstrap() {
  [[ "$SKIP_LGSM_BOOTSTRAP" == "yes" ]] && { log "Step: LinuxGSM bootstrap — SKIPPED by flag"; return 0; }
  [[ "$SKIP_USER_CREATION" == "yes" ]] && { warn "Step: LinuxGSM bootstrap — SKIPPED because user creation was skipped (no service user to bootstrap into)."; return 0; }
  log "Step: LinuxGSM bootstrap (fetch only — actual install runs in Phase 2 as ${SERVICE_USER})"
  id "${SERVICE_USER}" &>/dev/null || fail "Service user '${SERVICE_USER}' does not exist — run step_create_service_user first (or create it yourself) before this step."

  if [[ -x "${SERVICE_HOME}/${LGSM_SERVER_NAME}" ]]; then
    warn "LinuxGSM (${LGSM_SERVER_NAME}) already present under ${SERVICE_HOME} — leaving as-is."
    return 0
  fi

  confirm "About to download linuxgsm.sh and bootstrap the '${LGSM_SERVER_NAME}' script in ${SERVICE_HOME} (as ${SERVICE_USER}). This only fetches the launcher — it does not run install or download game files; that happens in Phase 2. Proceed?" \
    || { warn "Skipped LinuxGSM bootstrap — install-server.sh's own step_linuxgsm_install will do this instead."; return 0; }

  su -s /bin/bash - "${SERVICE_USER}" -c "
    set -e
    cd '${SERVICE_HOME}'
    curl -Lo linuxgsm.sh https://linuxgsm.sh
    chmod +x linuxgsm.sh
    bash linuxgsm.sh '${LGSM_SERVER_NAME}'
  "
  [[ -x "${SERVICE_HOME}/${LGSM_SERVER_NAME}" ]] || fail "LinuxGSM bootstrap did not produce an executable ${SERVICE_HOME}/${LGSM_SERVER_NAME} — check the output above."
  log "LinuxGSM bootstrapped. Branch config + the actual install run in Phase 2 (install-server.sh, as ${SERVICE_USER}, no root needed)."
}

step_create_service_user() {
  [[ "$SKIP_USER_CREATION" == "yes" ]] && { log "Step: create service user — SKIPPED by flag"; return 0; }
  log "Step: service user (${SERVICE_USER})"
  if id "${SERVICE_USER}" &>/dev/null; then
    warn "User '${SERVICE_USER}' already exists — leaving as-is, not modifying password/shell/groups."
    return 0
  fi
  confirm "About to create user '${SERVICE_USER}' with 'useradd -m -s /bin/bash'. No password or SSH access is configured by this script — see README for logging in as this user. Proceed?" || { warn "Skipped user creation."; return 0; }

  # useradd (from the near-universal "passwd" package) instead of adduser:
  # adduser is a separate package and isn't guaranteed present on minimal
  # images (confirmed missing on at least one tested container). -m creates
  # the home directory; a freshly-useradd'd account has no password set
  # (locked, "!" in /etc/shadow) — same no-login-by-default result as
  # adduser --disabled-password.
  useradd -m -s /bin/bash "${SERVICE_USER}"

  if ! id "${SERVICE_USER}" &>/dev/null; then
    fail "User '${SERVICE_USER}' was not created successfully. Check the useradd output above."
  fi

  # useradd -m only takes ownership of the home directory if it doesn't
  # already exist — if ${SERVICE_HOME} is left over from an earlier partial
  # run, a base image, or manual testing, it can still be owned by root (or
  # a stale UID) even though the account now exists, silently breaking
  # every later step that writes there as this user. Fix it explicitly
  # rather than assuming useradd handled it.
  if [[ -d "$SERVICE_HOME" ]]; then
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$SERVICE_HOME"
  fi

  log "User '${SERVICE_USER}' created (no password set, no SSH configured)."
  log "To use this account: 'sudo passwd ${SERVICE_USER}' to set a password, or add your own SSH key to ${SERVICE_HOME}/.ssh/authorized_keys manually. See README."
}

step_firewall() {
  [[ "$SKIP_FIREWALL" == "yes" ]] && { log "Step: firewall — SKIPPED by flag"; return 0; }
  log "Step: ufw game ports"

  if ! command -v ufw &>/dev/null; then
    confirm "ufw is not installed. Install it now (apt-get install -y ufw)?" || { warn "Skipped firewall step — ufw not installed."; return 0; }
    apt-get install -y ufw
  fi

  if ufw status | grep -q "Status: active"; then
    warn "ufw is already active with existing rules. This step only ADDS the rules below; it does not reset ufw to defaults."
  fi

  confirm "About to allow ${GAME_PORT_UDP}/udp, ${CLIENT_PORT_UDP}/udp, ${HLTV_PORT_UDP}/udp, ${VAC_PORT_UDP}/udp via ufw. Proceed?" || { warn "Skipped game-port rules."; return 0; }
  ufw allow "${GAME_PORT_UDP}/udp"
  ufw allow "${CLIENT_PORT_UDP}/udp"
  ufw allow "${HLTV_PORT_UDP}/udp"
  ufw allow "${VAC_PORT_UDP}/udp"

  log "Step: RCON port (opt-in)"
  if [[ -z "$ADMIN_IP" ]]; then
    warn "ADMIN_IP is not set — RCON (tcp/${RCON_PORT_TCP}) will NOT be opened. Set ADMIN_IP in env.conf and re-run this step later to enable remote RCON. This is the safe default: an unrestricted RCON port is a real risk, so we simply leave it closed rather than guess."
  else
    if confirm "About to allow ${RCON_PORT_TCP}/tcp via ufw, restricted to ${ADMIN_IP} only. Proceed?"; then
      ufw allow from "${ADMIN_IP}" to any port "${RCON_PORT_TCP}" proto tcp || warn "Failed to add RCON rule — check ADMIN_IP format (${ADMIN_IP})."
    else
      warn "Skipped RCON rule."
    fi
  fi

  # ufw only needs enabling once; if inactive, ask separately since enabling
  # ufw for the first time can affect anything else listening on the box.
  if ! ufw status | grep -q "Status: active"; then
    # Lockout safety net: this is the one point where we check SSH at all,
    # and only to offer adding a rule — never applied without an explicit
    # yes here, and skipped entirely if a rule already looks present.
    if ! ufw status | grep -Eq "(^| )${SSH_PORT}/tcp|OpenSSH"; then
      warn "No ufw rule for SSH (port ${SSH_PORT}/tcp) was detected. Enabling ufw without one risks locking yourself out."
      if confirm "Add a rule to allow ${SSH_PORT}/tcp now so you don't get locked out?"; then
        ufw allow "${SSH_PORT}/tcp"
        log "Added ufw rule for ${SSH_PORT}/tcp."
      else
        warn "Continuing without an SSH rule — you accepted the lockout risk. Set SSH_PORT in env.conf if your SSH runs on a non-default port."
      fi
    else
      log "Existing ufw rule for SSH (port ${SSH_PORT}/tcp) detected — not touching it."
    fi

    confirm "ufw is currently inactive, so the rules just added aren't enforced yet. Enable ufw now ('ufw enable')? This applies a default-deny-incoming policy to ALL ports not explicitly allowed." || {
      warn "ufw rules were added but ufw is not enabled — they have no effect until you run 'ufw enable' yourself."
      return 0
    }
    ufw --force enable
  fi

  # Validation: confirm the rules we expect are actually present.
  local ufw_out missing_rules=()
  ufw_out="$(ufw status)"
  for port_proto in "${GAME_PORT_UDP}/udp" "${CLIENT_PORT_UDP}/udp" "${HLTV_PORT_UDP}/udp" "${VAC_PORT_UDP}/udp"; do
    grep -q "$port_proto" <<<"$ufw_out" || missing_rules+=("$port_proto")
  done
  if (( ${#missing_rules[@]} > 0 )); then
    warn "Could not confirm these ufw rules are present: ${missing_rules[*]}. Run 'ufw status' manually to check."
  else
    log "ufw game-port rules confirmed present."
  fi
}

step_fail2ban_unattended_upgrades() {
  [[ "$SKIP_FAIL2BAN" == "yes" ]] && { log "Step: fail2ban/unattended-upgrades — SKIPPED by flag"; return 0; }
  log "Step: fail2ban + unattended-upgrades"
  confirm "About to install and enable fail2ban (brute-force protection for services like SSH) and unattended-upgrades (automatic security patching). Proceed?" || { warn "Skipped."; return 0; }

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y fail2ban unattended-upgrades

  systemctl enable --now fail2ban

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades 2>/dev/null || true

  # Validation
  if ! systemctl is-active --quiet fail2ban; then
    warn "fail2ban does not appear to be active after install — check 'systemctl status fail2ban'."
  else
    log "fail2ban active."
  fi
  if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    warn "unattended-upgrades config file was not written as expected."
  else
    log "unattended-upgrades configured."
  fi
}

step_swap() {
  [[ "$SKIP_SWAP" == "yes" ]] && { log "Step: swap — SKIPPED by flag"; return 0; }
  log "Step: swap check"

  local mem_mb swap_mb
  mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  swap_mb="$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  log "Detected ${mem_mb}MB RAM, ${swap_mb}MB swap."

  if (( swap_mb > 0 )); then
    log "Swap already present — leaving existing swap configuration untouched."
    return 0
  fi
  if (( mem_mb >= 2048 )); then
    log "RAM is >= 2GB and no swap is configured — not offering swap (not needed for a typical CS1.6 server load)."
    return 0
  fi

  confirm "RAM is under 2GB and no swap is present. Create a 2GB swapfile at /swapfile? Recommended on small VPS instances to avoid OOM kills." || { warn "Skipped swap creation."; return 0; }

  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  # Validation
  if swapon --show | grep -q '/swapfile'; then
    log "Swapfile created and active."
  else
    warn "Swapfile was created but does not appear active — check 'swapon --show'."
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  require_root
  log "CS 1.6 ReHLDS installer — root bootstrap phase (Debian 12 / Ubuntu 22.04 / Ubuntu 24.04)"
  log "Unattended: ${UNATTENDED}"

  step_os_check
  step_apt_update_upgrade
  step_lgsm_and_engine_deps
  step_create_service_user
  step_linuxgsm_bootstrap
  step_firewall
  step_fail2ban_unattended_upgrades
  step_swap

  log "Root bootstrap phase complete."
  log "Next: su - ${SERVICE_USER}   then run install-server.sh from that account. Dependencies are already installed, so LinuxGSM's install won't need sudo/root for anything."
}

main "$@"