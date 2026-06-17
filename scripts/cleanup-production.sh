#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"
SYSTEMCTL="${AUTOPOIESIS_SYSTEMCTL_BIN:-systemctl}"
STRICT="${AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT:-0}"
ALLOW_SSH="${AUTOPOIESIS_PRODUCTION_ALLOW_SSH:-0}"
FAILURES=0
WARNINGS=0
HOME_DIRS=()

usage() {
  cat <<'EOF'
Usage: scripts/cleanup-production.sh [--strict] [--allow-ssh] [--app-dir=PATH] [--home-dir=PATH]

Read-only production hygiene audit for final Raspberry Pi images.

Checks for:
- secret-looking files in the installed app tree
- tracked secret-looking files when the app tree is a Git checkout
- Git metadata left in the installed app
- Codex/OpenClaw/OpenAI credential homes
- shell history files that contain obvious secret hints
- development package caches
- SSH enabled or active when production policy does not allow it

Environment:
  AUTOPOIESIS_APP_DIR
  AUTOPOIESIS_USER
  AUTOPOIESIS_PRODUCTION_HOME_DIRS      colon-separated home dirs to inspect
  AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT 1 converts cleanup warnings to failures
  AUTOPOIESIS_PRODUCTION_ALLOW_SSH      1 allows active/enabled ssh/sshd
  AUTOPOIESIS_SYSTEMCTL_BIN             systemctl override for isolated tests
EOF
}

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

warn() {
  if [[ "$STRICT" == "1" ]]; then
    fail "$*"
  else
    echo "WARN: $*" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
}

pass() {
  echo "OK: $*"
}

add_home_dir() {
  local dir="$1"
  [[ -n "$dir" ]] || return
  HOME_DIRS+=("$dir")
}

for arg in "$@"; do
  case "$arg" in
    --strict)
      STRICT=1
      ;;
    --allow-ssh)
      ALLOW_SSH=1
      ;;
    --app-dir=*)
      APP_DIR="${arg#--app-dir=}"
      ;;
    --home-dir=*)
      add_home_dir "${arg#--home-dir=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${#HOME_DIRS[@]} -eq 0 ]]; then
  if [[ -n "${AUTOPOIESIS_PRODUCTION_HOME_DIRS:-}" ]]; then
    IFS=':' read -r -a HOME_DIRS <<< "$AUTOPOIESIS_PRODUCTION_HOME_DIRS"
  else
    add_home_dir /root
    if command -v getent >/dev/null 2>&1; then
      APPLIANCE_HOME="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6 || true)"
      add_home_dir "$APPLIANCE_HOME"
    fi
    add_home_dir "/home/$USER_NAME"
  fi
fi

is_ignored_secret_path() {
  local path="$1"
  local base
  base="$(basename "$path")"
  case "$base" in
    .env.example|env.example)
      return 0
      ;;
  esac
  return 1
}

check_app_tree() {
  if [[ ! -d "$APP_DIR" ]]; then
    fail "app directory does not exist: $APP_DIR"
    return
  fi

  pass "app directory exists: $APP_DIR"

  if [[ -d "$APP_DIR/.git" ]]; then
    fail "installed app still contains Git metadata: $APP_DIR/.git"
  else
    pass "installed app does not contain .git metadata"
  fi

  local findings=()
  while IFS= read -r path; do
    if is_ignored_secret_path "$path"; then
      continue
    fi
    findings+=("$path")
  done < <(
    find "$APP_DIR" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' \) -prune -o \
      \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -iname '*secret*' -o -iname '*token*' -o -name 'secrets' -o -path '*/secrets/*' \) \
      -print 2>/dev/null
  )

  if [[ ${#findings[@]} -gt 0 ]]; then
    printf '%s\n' "${findings[@]}" >&2
    fail "secret-looking files or directories remain in the installed app tree"
  else
    pass "no secret-looking file names found in installed app tree"
  fi

  if git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local tracked
    tracked="$(git -C "$APP_DIR" ls-files | grep -E '(^|/)(\.env|.*\.pem|.*\.key|secrets?)(/|$)' || true)"
    if [[ -n "$tracked" ]]; then
      echo "$tracked" >&2
      fail "secret-looking files are tracked in Git"
    else
      pass "Git-tracked files do not include obvious secret paths"
    fi
  else
    pass "installed app is not a Git checkout"
  fi
}

check_home_dirs() {
  local inspected=0
  local agent_findings=()
  local history_findings=()
  local cache_findings=()

  for home_dir in "${HOME_DIRS[@]}"; do
    [[ -n "$home_dir" && -d "$home_dir" ]] || continue
    inspected=$((inspected + 1))

    for dir in \
      "$home_dir/.codex" \
      "$home_dir/.openclaw" \
      "$home_dir/.openai" \
      "$home_dir/.config/openai"; do
      [[ -e "$dir" ]] && agent_findings+=("$dir")
    done

    for file in \
      "$home_dir/.bash_history" \
      "$home_dir/.zsh_history" \
      "$home_dir/.sh_history" \
      "$home_dir/.node_repl_history"; do
      if [[ -f "$file" ]] && grep -Eiq 'OPENAI_API_KEY|FAL_KEY|GOG_KEYRING_PASSWORD|api[_-]?key|secret|token|password' "$file" 2>/dev/null; then
        history_findings+=("$file")
      fi
    done

    for dir in \
      "$home_dir/.npm/_cacache" \
      "$home_dir/.cache/pip" \
      "$home_dir/.cache/ms-playwright" \
      "$home_dir/.cache/playwright" \
      "$home_dir/.local/share/pnpm" \
      "$home_dir/.yarn"; do
      [[ -e "$dir" ]] && cache_findings+=("$dir")
    done
  done

  if [[ "$inspected" -eq 0 ]]; then
    warn "no production home directories were available to inspect"
  else
    if [[ "$inspected" -eq 1 ]]; then
      pass "inspected 1 production home directory"
    else
      pass "inspected $inspected production home directories"
    fi
  fi

  if [[ ${#agent_findings[@]} -gt 0 ]]; then
    printf '%s\n' "${agent_findings[@]}" >&2
    fail "Codex/OpenClaw/OpenAI credential directories remain on the production image"
  else
    pass "no Codex/OpenClaw/OpenAI credential directories found in inspected homes"
  fi

  if [[ ${#history_findings[@]} -gt 0 ]]; then
    printf '%s\n' "${history_findings[@]}" >&2
    fail "shell history files contain obvious secret hints"
  else
    pass "inspected shell histories do not contain obvious secret hints"
  fi

  if [[ ${#cache_findings[@]} -gt 0 ]]; then
    printf '%s\n' "${cache_findings[@]}" >&2
    warn "development package caches remain"
  else
    pass "no common development package caches found in inspected homes"
  fi
}

check_ssh_policy() {
  if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    warn "systemctl is unavailable; cannot verify SSH service exposure"
    return
  fi

  local exposed=()
  for service in ssh.service sshd.service; do
    if "$SYSTEMCTL" is-enabled --quiet "$service" >/dev/null 2>&1 || "$SYSTEMCTL" is-active --quiet "$service" >/dev/null 2>&1; then
      exposed+=("$service")
    fi
  done

  if [[ ${#exposed[@]} -eq 0 ]]; then
    pass "ssh/sshd services are not enabled or active"
    return
  fi

  printf '%s\n' "${exposed[@]}" >&2
  if [[ "$ALLOW_SSH" == "1" ]]; then
    pass "ssh/sshd is exposed and explicitly allowed by policy"
  else
    warn "ssh/sshd is enabled or active; set AUTOPOIESIS_PRODUCTION_ALLOW_SSH=1 only when remote support is intentional"
  fi
}

echo "Autopoiesis OS production cleanup audit"
echo "Date: $(date -Is)"
echo "App: $APP_DIR"
echo "Strict: $STRICT"
echo

check_app_tree
check_home_dirs
check_ssh_policy

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "Production cleanup audit failed with $FAILURES failure(s) and $WARNINGS warning(s)." >&2
  exit 1
fi

echo "Production cleanup audit passed with $WARNINGS warning(s)."
