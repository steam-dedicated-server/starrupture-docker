#!/usr/bin/env bash
# config.sh — env loading and validation.
# shellcheck shell=bash

[[ -n "${STAR_CONFIG_LOADED:-}" ]] && return 0
readonly STAR_CONFIG_LOADED=1

# Load defaults first, then optional user override file.
# Order of precedence (lowest → highest):
#   1. defaults.env
#   2. $STAR_CONFIG_FILE or config/server.env
#   3. existing environment (already exported by caller)
star::config::load() {
  local defaults="${STAR_CONFIG_DIR}/defaults.env"
  local custom="${STAR_CONFIG_FILE:-${STAR_CONFIG_DIR}/server.env}"

  if [[ -f "$defaults" ]]; then
    set -o allexport
    # shellcheck source=/dev/null
    . "$defaults"
    set +o allexport
  fi

  if [[ -f "$custom" ]]; then
    star::log::info "loading config: $custom"
    set -o allexport
    # shellcheck source=/dev/null
    . "$custom"
    set +o allexport
  fi
}

# Fail fast if any of the named variables is empty.
star::config::require() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    star::die "missing required config: ${missing[*]} (see config/server.example.env)"
  fi
}

star::config::print() {
  cat <<EOF
[config]
  INSTALL_DIR         = ${INSTALL_DIR:-(unset)}
  STEAM_USER          = ${STEAM_USER:-(unset)}
  STEAM_APP_ID        = ${STEAM_APP_ID:-(unset)}
  SERVER_NAME         = ${SERVER_NAME:-(unset)}
  SERVER_PORT         = ${SERVER_PORT:-(unset)}
  SERVER_QUERY_PORT   = ${SERVER_QUERY_PORT:-(unset)}
  MULTIHOME           = ${MULTIHOME:-(unset)}
  USE_DSSETTINGS      = ${USE_DSSETTINGS:-(unset)}
  SESSION_NAME        = ${SESSION_NAME:-(unset)}
  SAVE_GAME_INTERVAL  = ${SAVE_GAME_INTERVAL:-(unset)}
  START_NEW_GAME      = ${START_NEW_GAME:-(unset)}
  LOAD_SAVED_GAME     = ${LOAD_SAVED_GAME:-(unset)}
  SAVE_GAME_NAME      = ${SAVE_GAME_NAME:-(unset)}
  BACKUP_DIR          = ${BACKUP_DIR:-(unset)}
  WINEPREFIX          = ${WINEPREFIX:-(unset)}
EOF
}
