#!/usr/bin/env bash
# =============================================================================
# Legisell Production — Pre-flight Check
#
# Validates all deployment dependencies before running docker compose.
# Safe to run repeatedly — only creates missing ./backups directory.
#
# Usage:
#   chmod +x preflight.sh
#   ./preflight.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
declare -a REPORT_LINES=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  local msg="$1"
  REPORT_LINES+=("  ${GREEN}✔${RESET}  ${msg}")
  (( PASS_COUNT++ )) || true
}

warn() {
  local msg="$1"
  REPORT_LINES+=("  ${YELLOW}⚠${RESET}  ${YELLOW}${msg}${RESET}")
  (( WARN_COUNT++ )) || true
}

fail() {
  local msg="$1"
  REPORT_LINES+=("  ${RED}✘${RESET}  ${RED}${msg}${RESET}")
  (( FAIL_COUNT++ )) || true
}

section() {
  local title="$1"
  REPORT_LINES+=("")
  REPORT_LINES+=("  ${CYAN}${BOLD}── $title${RESET}")
}

# ---------------------------------------------------------------------------
# Helper: load .env without executing arbitrary code
# ---------------------------------------------------------------------------
load_env() {
  local env_file="$1"
  # Strip comments and blank lines; export KEY=VALUE pairs
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Only process KEY=VALUE lines
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      # Strip surrounding quotes if present
      val="${val#\"}" ; val="${val%\"}"
      val="${val#\'}" ; val="${val%\'}"
      export "$key=$val"
    fi
  done < "$env_file"
}

# ---------------------------------------------------------------------------
# Helper: check if a value looks like a placeholder (still has < > brackets)
# ---------------------------------------------------------------------------
is_placeholder() {
  local val="$1"
  [[ "$val" == *"<"*">"* ]] && return 0 || return 1
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Toolchain
# ---------------------------------------------------------------------------
section "1  Toolchain"

if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  pass "docker found  ${DIM}(${DOCKER_VERSION})${RESET}"
else
  fail "docker not found — install Docker Engine"
fi

if docker compose version &>/dev/null 2>&1; then
  DC_VERSION=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  pass "docker compose plugin found  ${DIM}(${DC_VERSION})${RESET}"
else
  fail "docker compose plugin not found — 'docker-compose' (v1) is not supported"
fi

if docker info &>/dev/null 2>&1; then
  pass "Docker daemon is running"
else
  fail "Docker daemon is not running — run: sudo systemctl start docker"
fi

# ---------------------------------------------------------------------------
# 2. Required files & directories
# ---------------------------------------------------------------------------
section "2  Files & Directories"

ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  if [[ -s "$ENV_FILE" ]]; then
    pass ".env exists and is non-empty"
  else
    fail ".env exists but is empty — cp .env.example .env && fill in values"
  fi
else
  fail ".env not found — run: cp .env.example .env && nano .env"
fi

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
  pass "docker-compose.yml exists"
else
  fail "docker-compose.yml not found in ${SCRIPT_DIR}"
fi

# SSL directory — read value from .env if possible, fallback to ./ssl
SSL_DIR_RAW=""
if [[ -f "$ENV_FILE" ]]; then
  SSL_DIR_RAW=$(grep -E '^SSL_CERT_DIR=' "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"'"'" | xargs)
fi
SSL_DIR="${SSL_DIR_RAW:-./ssl}"
# Expand ~ and relative paths
SSL_DIR="${SSL_DIR/#\~/$HOME}"
[[ "$SSL_DIR" != /* ]] && SSL_DIR="$SCRIPT_DIR/${SSL_DIR#./}"

if [[ -d "$SSL_DIR" ]]; then
  CERT_FILE="$SSL_DIR/fullchain.pem"
  KEY_FILE="$SSL_DIR/privkey.pem"
  if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    # Check cert expiry
    EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null | cut -d'=' -f2 || true)
    if [[ -n "$EXPIRY" ]]; then
      EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || echo 0)
      NOW_EPOCH=$(date +%s)
      DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
      if (( DAYS_LEFT < 0 )); then
        fail "SSL certificate has EXPIRED  (${EXPIRY})"
      elif (( DAYS_LEFT < 30 )); then
        warn "SSL certificate expires in ${DAYS_LEFT} days  (${EXPIRY})"
      else
        pass "SSL certificates found and valid  ${DIM}(expires in ${DAYS_LEFT} days)${RESET}"
      fi
    else
      pass "SSL certificates found  ${DIM}(fullchain.pem + privkey.pem)${RESET}"
    fi
  elif [[ -f "$CERT_FILE" ]]; then
    fail "SSL key missing: ${SSL_DIR}/privkey.pem"
  elif [[ -f "$KEY_FILE" ]]; then
    fail "SSL certificate missing: ${SSL_DIR}/fullchain.pem"
  else
    fail "SSL directory ${SSL_DIR} exists but is missing fullchain.pem and privkey.pem"
  fi
else
  fail "SSL directory not found: ${SSL_DIR}"
fi

# backups/ directory — create if missing (only auto-created directory)
BACKUPS_DIR="$SCRIPT_DIR/backups"
if [[ -d "$BACKUPS_DIR" ]]; then
  pass "./backups directory exists"
else
  mkdir -p "$BACKUPS_DIR"
  warn "./backups directory did not exist — created it"
fi
# The backup container runs as backupuser (UID 1000). Pre-set ownership so the
# container can write backups and state.json without needing root at runtime.
if chown 1000:1000 "$BACKUPS_DIR" 2>/dev/null; then
  pass "./backups ownership set to UID/GID 1000 (backupuser)"
else
  warn "Could not chown ./backups to UID 1000 — re-run with sudo or the backup container may get Permission denied"
fi

# ---------------------------------------------------------------------------
# 3. .env — Required variables
# ---------------------------------------------------------------------------
section "3  Environment Variables  ${DIM}(.env)${RESET}"

if [[ -f "$ENV_FILE" && -s "$ENV_FILE" ]]; then
  load_env "$ENV_FILE"

  check_var() {
    local var="$1"
    local desc="$2"
    local val="${!var:-}"
    if [[ -z "$val" ]]; then
      fail "${var} is not set  ${DIM}(${desc})${RESET}"
    elif is_placeholder "$val"; then
      fail "${var} still has placeholder value  ${DIM}(${desc})${RESET}"
    else
      pass "${var} is set  ${DIM}(${desc})${RESET}"
    fi
  }

  # Images
  check_var IMAGE_BACKEND       "GHCR backend image"
  check_var IMAGE_FRONTEND      "GHCR frontend image"
  check_var IMAGE_UPDATER       "GHCR updater image"
  check_var IMAGE_BACKUP        "GHCR backup image"

  # Network
  check_var TAILSCALE_LOCAL_IP  "Tailscale private IPv4"
  check_var DOMAIN              "primary domain"

  # Database
  check_var POSTGRES_USER       "database username"
  check_var POSTGRES_PASSWORD   "database password"
  check_var POSTGRES_DB         "database name"

  # Cache
  check_var REDIS_PASSWORD      "Redis password"

  # Security
  check_var JWT_SECRET          "JWT access token secret"
  check_var JWT_REFRESH_SECRET  "JWT refresh token secret"
  check_var SECRETS_ENCRYPTION_KEY "Fernet encryption key"

  # Initial admin
  check_var ADMIN_USERNAME      "initial admin username"
  check_var ADMIN_PASSWORD      "initial admin password"
  check_var ADMIN_EMAIL         "initial admin e-mail"

  # Backup service
  check_var BACKUP_USER         "backup web UI username"
  check_var BACKUP_PASSWORD     "backup web UI password"
  check_var BACKUP_DIR          "absolute container-side path for backup files"

  # BACKUP_DIR must be absolute — the Pydantic validator in the image enforces this
  BACKUP_DIR_VAL="${BACKUP_DIR:-}"
  if [[ -n "$BACKUP_DIR_VAL" ]] && ! is_placeholder "$BACKUP_DIR_VAL"; then
    if [[ "$BACKUP_DIR_VAL" != /* ]]; then
      fail "BACKUP_DIR must be an absolute path (got: '${BACKUP_DIR_VAL}') — change to /backups"
    fi
  fi

  # Warn if JWT_SECRET == JWT_REFRESH_SECRET
  JS="${JWT_SECRET:-}"
  JRS="${JWT_REFRESH_SECRET:-}"
  if [[ -n "$JS" && -n "$JRS" && "$JS" == "$JRS" ]]; then
    warn "JWT_SECRET and JWT_REFRESH_SECRET are identical — they should differ"
  fi
else
  warn "Skipping variable checks — .env is missing or empty"
fi

# ---------------------------------------------------------------------------
# 4. GHCR authentication
# ---------------------------------------------------------------------------
section "4  GHCR Authentication"

DOCKER_CFG_DIR_RAW="${DOCKER_CONFIG_DIR:-~/.docker}"
DOCKER_CFG_DIR="${DOCKER_CFG_DIR_RAW/#\~/$HOME}"
DOCKER_CFG_FILE="$DOCKER_CFG_DIR/config.json"

if [[ -f "$DOCKER_CFG_FILE" ]]; then
  if grep -q "ghcr.io" "$DOCKER_CFG_FILE" 2>/dev/null; then
    pass "GHCR credentials found in ${DOCKER_CFG_FILE}"
  else
    warn "docker config.json exists but contains no ghcr.io entry — run: echo \"\$TOKEN\" | docker login ghcr.io -u \$USER --password-stdin"
  fi
else
  fail "Docker config not found at ${DOCKER_CFG_FILE} — login to GHCR first"
fi

# ---------------------------------------------------------------------------
# 5. Tailscale
# ---------------------------------------------------------------------------
section "5  Tailscale"

TS_IP="${TAILSCALE_LOCAL_IP:-}"

if [[ -n "$TS_IP" ]] && ! is_placeholder "$TS_IP"; then
  # Validate format: basic IPv4 check
  if [[ "$TS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    pass "TAILSCALE_LOCAL_IP format is valid  ${DIM}(${TS_IP})${RESET}"
  else
    fail "TAILSCALE_LOCAL_IP is not a valid IPv4 address: '${TS_IP}'"
  fi

  # Check Tailscale daemon
  if command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ "$TS_STATUS" == "Running" ]]; then
      # Verify the configured IP is actually assigned to this node
      if tailscale ip -4 2>/dev/null | grep -qF "$TS_IP"; then
        pass "Tailscale is running and IP matches  ${DIM}(${TS_IP})${RESET}"
      else
        ACTUAL_TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
        warn "Tailscale is running but TAILSCALE_LOCAL_IP (${TS_IP}) differs from actual IP (${ACTUAL_TS_IP:-unknown})"
      fi
    else
      warn "Tailscale daemon found but status is '${TS_STATUS:-unknown}' — run: sudo tailscale up"
    fi
  else
    # tailscale CLI not in PATH — check if IP is assigned to any interface
    if ip addr show 2>/dev/null | grep -qF "$TS_IP"; then
      pass "Tailscale CLI not in PATH, but ${TS_IP} is assigned to a network interface"
    else
      warn "tailscale CLI not in PATH and ${TS_IP} is not found on any interface — verify Tailscale is active"
    fi
  fi
else
  warn "TAILSCALE_LOCAL_IP not set or is placeholder — skipping Tailscale checks"
fi

# ---------------------------------------------------------------------------
# 6. Port availability
# ---------------------------------------------------------------------------
section "6  Port Availability"

check_port() {
  local port="$1"
  local desc="$2"
  # ss is preferred; fall back to netstat
  if command -v ss &>/dev/null; then
    if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
      fail "Port ${port}/tcp is already in use  ${DIM}(${desc})${RESET}"
    else
      pass "Port ${port}/tcp is free  ${DIM}(${desc})${RESET}"
    fi
  elif command -v netstat &>/dev/null; then
    if netstat -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
      fail "Port ${port}/tcp is already in use  ${DIM}(${desc})${RESET}"
    else
      pass "Port ${port}/tcp is free  ${DIM}(${desc})${RESET}"
    fi
  else
    warn "Cannot check port ${port} — neither ss nor netstat available"
  fi
}

check_port 80    "HTTP → HTTPS redirect (Tailscale only)"
check_port 443   "Admin HTTPS (Tailscale only)"
check_port 8443  "POS License API (public)"
check_port 8400  "Backup UI (Tailscale only)"



# =============================================================================
# FINAL REPORT
# =============================================================================

echo ""
echo ""
printf "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}${CYAN}║        Legisell Production — Pre-flight Check Report         ║${RESET}\n"
printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}\n"

for line in "${REPORT_LINES[@]}"; do
  echo -e "$line"
done

echo ""
printf "${BOLD}${CYAN}──────────────────────────────────────────────────────────────${RESET}\n"
printf "  ${GREEN}${BOLD}%-4s passed${RESET}   ${YELLOW}${BOLD}%-4s warnings${RESET}   ${RED}${BOLD}%-4s failed${RESET}\n" \
  "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
printf "${BOLD}${CYAN}──────────────────────────────────────────────────────────────${RESET}\n"
echo ""

if (( FAIL_COUNT > 0 )); then
  printf "${RED}${BOLD}  ✘  Deployment is NOT ready. Fix the %d failing check(s) above.${RESET}\n\n" "$FAIL_COUNT"
  exit 1
elif (( WARN_COUNT > 0 )); then
  printf "${YELLOW}${BOLD}  ⚠  Deployment MAY proceed, but review the %d warning(s) above.${RESET}\n\n" "$WARN_COUNT"
  exit 0
else
  printf "${GREEN}${BOLD}  ✔  All checks passed. Ready to run: docker compose up -d${RESET}\n\n"
  exit 0
fi
