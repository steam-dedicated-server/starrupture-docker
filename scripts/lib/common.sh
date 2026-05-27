#!/usr/bin/env bash
# common.sh — logging, retries, basic utilities.
# Sourced by scripts/star. Do NOT enable `set -e` here; the caller decides.
# shellcheck shell=bash

[[ -n "${STAR_COMMON_LOADED:-}" ]] && return 0
readonly STAR_COMMON_LOADED=1

# ---------- Colors (only when stderr is a TTY) ----------
if [[ -t 2 ]]; then
  readonly STAR_RED=$'\033[31m'
  readonly STAR_YELLOW=$'\033[33m'
  readonly STAR_GREEN=$'\033[32m'
  readonly STAR_BLUE=$'\033[34m'
  readonly STAR_DIM=$'\033[2m'
  readonly STAR_RESET=$'\033[0m'
else
  readonly STAR_RED=''  STAR_YELLOW=''  STAR_GREEN=''  STAR_BLUE=''  STAR_DIM=''  STAR_RESET=''
fi

# ---------- Logging ----------
star::log::_write() {
  local level=$1 color=$2 msg=$3
  printf '%s[%s]%s %s%-5s%s %s\n' \
    "$STAR_DIM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STAR_RESET" \
    "$color" "$level" "$STAR_RESET" \
    "$msg" >&2
}

star::log::debug() {
  if [[ "${STAR_LOG_LEVEL:-info}" == "debug" ]]; then
    star::log::_write DEBUG "$STAR_DIM" "$*"
  fi
}

star::log::info()  { star::log::_write INFO  "$STAR_BLUE"   "$*"; }
star::log::warn()  { star::log::_write WARN  "$STAR_YELLOW" "$*"; }
star::log::error() { star::log::_write ERROR "$STAR_RED"    "$*"; }
star::log::ok()    { star::log::_write OK    "$STAR_GREEN"  "$*"; }

star::die() {
  star::log::error "$*"
  exit 1
}

# ---------- Retry with exponential backoff ----------
# Usage: star::retry <cmd> [args...]
# Tunable via STAR_RETRY_MAX (default 5) and STAR_RETRY_DELAY (default 2s, doubles).
star::retry() {
  local max=${STAR_RETRY_MAX:-5}
  local delay=${STAR_RETRY_DELAY:-2}
  local attempt=1
  local rc=0
  while (( attempt <= max )); do
    if "$@"; then return 0; fi
    rc=$?
    if (( attempt == max )); then break; fi
    star::log::warn "attempt ${attempt}/${max} failed (rc=${rc}); retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay * 2 ))
    attempt=$(( attempt + 1 ))
  done
  star::log::error "all ${max} attempts failed"
  return "$rc"
}

# ---------- Require external commands ----------
star::require() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    star::die "missing required commands: ${missing[*]}"
  fi
}

# ---------- Help ----------
star::help() {
  cat <<'EOF'
star — Starrupture dedicated server CLI

Usage: star <command> [args...]

Server lifecycle:
  install         Download / install the dedicated server (validates files)
  update          Update the dedicated server to the latest build
  validate        Re-validate game files via steamcmd
  run, start      Start the dedicated server in the foreground (Wine + Xvfb)
  health          Run A2S healthcheck against SERVER_QUERY_PORT

Steam:
  login           Interactive steamcmd login (only for non-anonymous accounts)

Operations:
  backup          Tar+gzip the Starrupture save directory into BACKUP_DIR
  config          Print effective configuration
  shell           Drop into an interactive bash
  version         Print version
  help            Show this help

Environment:
  See config/server.example.env for the full list of variables.
EOF
}
