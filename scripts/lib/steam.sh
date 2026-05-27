#!/usr/bin/env bash
# steam.sh — steamcmd wrappers.
# shellcheck shell=bash

[[ -n "${STAR_STEAM_LOADED:-}" ]] && return 0
readonly STAR_STEAM_LOADED=1

# Resolve steamcmd binary: prefer pre-installed image binary, fall back to PATH.
star::steam::cmd() {
  local bin="${STEAMCMD_BIN:-/home/steam/steamcmd/steamcmd.sh}"
  if [[ ! -x "$bin" ]]; then
    bin=$(command -v steamcmd || true)
    [[ -z "$bin" ]] && star::die "steamcmd not found (set STEAMCMD_BIN or install steamcmd)"
  fi
  "$bin" "$@"
}

# Internal: app_update, optionally appending the `validate` token.
#
# IMPORTANT: Starrupture ships only a Windows server binary
# (StarRuptureServerEOS-Win64-Shipping.exe). steamcmd on Linux
# defaults to the Linux platform and will return `Invalid platform`
# for an app that has no Linux depot. `+@sSteamCmdForcePlatformType
# windows` flips the depot selector before login so the Windows
# files are fetched instead.
#
# Unlike Last Oasis, Starrupture uses a single app id for both the
# installer and the runtime — no steam_appid.txt fixup needed
# post-install.
star::steam::_app_update() {
  local mode=${1:-}
  local -a extra=()
  if [[ "$mode" == "validate" ]]; then
    extra+=(validate)
  fi

  star::config::require INSTALL_DIR STEAM_APP_ID STEAM_USER
  install -d -m 0755 "$INSTALL_DIR"

  star::log::info "steamcmd app_update ${STEAM_APP_ID} [windows] (user=${STEAM_USER}) → ${INSTALL_DIR}"
  # Flags:
  #   +@sSteamCmdForcePlatformType windows
  #                               — fetch the Windows depot (Starrupture
  #     has no Linux build; without this the update aborts with
  #     `Invalid platform`).
  #   +@ShutdownOnFailedCommand 1 — exit non-zero on first failed step
  #     (otherwise steamcmd may swallow errors and return 0).
  #   +@NoPromptForPassword 1     — fail fast on bad creds instead of
  #     blocking on an interactive prompt.
  #   +app_license_request        — pre-warm the anonymous license
  #     cache; avoids transient "Missing configuration" on first run.
  star::retry star::steam::cmd \
    +@sSteamCmdForcePlatformType windows \
    +@ShutdownOnFailedCommand 1 \
    +@NoPromptForPassword 1 \
    +force_install_dir "$INSTALL_DIR" \
    +login "$STEAM_USER" \
    +app_license_request "$STEAM_APP_ID" \
    +app_update "$STEAM_APP_ID" "${extra[@]}" \
    +quit

  star::log::ok "steamcmd app_update finished"
}

star::steam::install()  { star::steam::_app_update validate; }
star::steam::update()   { star::steam::_app_update; }
star::steam::validate() { star::steam::_app_update validate; }

star::steam::login() {
  star::config::require STEAM_USER
  if [[ "$STEAM_USER" == "anonymous" ]]; then
    star::log::info "STEAM_USER=anonymous — login not required"
    return 0
  fi
  star::log::info "interactive steamcmd login as ${STEAM_USER}"
  star::steam::cmd +login "$STEAM_USER" +quit
}
