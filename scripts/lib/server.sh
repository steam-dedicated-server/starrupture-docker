#!/usr/bin/env bash
# server.sh — dedicated server lifecycle.
# shellcheck shell=bash

[[ -n "${STAR_SERVER_LOADED:-}" ]] && return 0
readonly STAR_SERVER_LOADED=1

star::server::_binary() {
  printf '%s/StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe' "$INSTALL_DIR"
}

star::server::_assert_installed() {
  local bin
  bin=$(star::server::_binary)
  if [[ ! -f "$bin" ]]; then
    star::die "server binary not found at $bin — run 'star install' first"
  fi
}

# Render DSSettings.txt from environment variables. The game reads
# this on startup to decide session name, autosave interval, and
# whether to start a fresh world or resume a saved one.
#
# Skipped when USE_DSSETTINGS=false — in that mode the in-game
# Server Manager UI controls the session and requires the TCP game
# port (7777) to be reachable from the operator. Reference:
#   https://wiki.starrupture-utilities.com/en/dedicated-server/Vulnerability-Announcement
star::server::_render_dssettings() {
  local file="${INSTALL_DIR}/DSSettings.txt"
  cat > "$file" <<EOF
{
  "SessionName": "${SESSION_NAME:-StarRuptureServer}",
  "SaveGameInterval": "${SAVE_GAME_INTERVAL:-300}",
  "StartNewGame": "${START_NEW_GAME:-false}",
  "LoadSavedGame": "${LOAD_SAVED_GAME:-true}",
  "SaveGameName": "${SAVE_GAME_NAME:-AutoSave0.sav}"
}
EOF
  star::log::info "rendered DSSettings.txt (SessionName=${SESSION_NAME:-StarRuptureServer})"
}

# Wine prefix bootstrap. Creates the WINEPREFIX on first run (cold
# `wineboot --init` takes ~10–30 s the first time, then the prefix
# is cached on the persistent volume).
star::server::_init_wineprefix() {
  if [[ -d "${WINEPREFIX}/drive_c/windows" ]]; then
    return 0
  fi
  star::log::info "initializing WINEPREFIX at ${WINEPREFIX} (first-run, may take ~30s)"
  install -d -m 0755 "$WINEPREFIX"
  wineboot --init >/dev/null 2>&1 || star::log::warn "wineboot exited non-zero (often benign)"
}

star::server::run() {
  star::config::require \
    INSTALL_DIR \
    SERVER_NAME \
    SERVER_PORT \
    SERVER_QUERY_PORT

  star::server::_assert_installed
  star::config::print

  : "${WINEPREFIX:=/mnt/steam/.wine}"
  : "${WINEARCH:=win64}"
  : "${WINEDEBUG:=-all}"
  export WINEPREFIX WINEARCH WINEDEBUG

  star::server::_init_wineprefix

  if [[ "${USE_DSSETTINGS:-false}" == "true" ]]; then
    star::server::_render_dssettings
  else
    star::log::warn "USE_DSSETTINGS=false — DSSettings.txt will NOT be rendered"
    star::log::warn "  the in-game Server Manager UI requires the TCP port (${SERVER_PORT}) to be reachable;"
    star::log::warn "  exposing TCP has had reported vulnerabilities — prefer USE_DSSETTINGS=true."
  fi

  # Headroom for FDs (Wine + many concurrent player connections).
  ulimit -n 65536 2>/dev/null || true

  # Bias the scheduler toward the game thread. Soft-fail: a negative
  # nice value needs CAP_SYS_NICE — without it renice is a no-op and
  # the server runs at default priority. In k8s, grant via:
  #   capabilities: { add: ["SYS_NICE"] }
  renice -n -5 $$ >/dev/null 2>&1 || true

  local bin
  bin=$(star::server::_binary)

  # Built-in flags (matches the in-the-wild docker reference):
  #   -Log                              — write Windows-side log
  #   -Port=<udp>                       — game UDP port
  #   -ServerName=<name>                — display name in matchmaking
  # Optional toggles below.
  local -a args=(
    -Log
    "-Port=${SERVER_PORT}"
    "-ServerName=${SERVER_NAME}"
  )

  # When DSSettings drives the session, disable the in-engine RC web
  # control surfaces — they're redundant and they bind TCP.
  if [[ "${USE_DSSETTINGS:-false}" == "true" ]]; then
    args+=(-RCWebControlDisable -RCWebInterfaceDisable)
  fi

  if [[ -n "${MULTIHOME:-}" ]]; then
    args+=("-MULTIHOME=${MULTIHOME}")
  fi

  # Append extra UE CLI flags verbatim (word-split intentional)
  if [[ -n "${SERVER_OPTIONS:-}" ]]; then
    # shellcheck disable=SC2206
    args+=(${SERVER_OPTIONS})
  fi

  star::log::info "starting dedicated server: ${SERVER_NAME} on port ${SERVER_PORT} (query ${SERVER_QUERY_PORT})"
  star::log::info "binary: ${bin}"
  # exec → become tini's direct child; signals forward cleanly so the
  # save flushes on container stop.
  exec xvfb-run --auto-servernum --server-args="-screen 0 640x480x24" \
    wine "$bin" "${args[@]}"
}
