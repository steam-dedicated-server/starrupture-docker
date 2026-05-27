#!/usr/bin/env bash
# backup.sh — save-data backup.
# shellcheck shell=bash

[[ -n "${STAR_BACKUP_LOADED:-}" ]] && return 0
readonly STAR_BACKUP_LOADED=1

star::backup::create() {
  star::config::require INSTALL_DIR
  local src="${INSTALL_DIR}/StarRupture/Saved"
  local dest="${BACKUP_DIR:-${INSTALL_DIR}/backups}"

  if [[ ! -d "$src" ]]; then
    star::die "save directory not found: $src"
  fi

  install -d -m 0755 "$dest"
  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  local archive="$dest/starrupture-saved-${SERVER_NAME:-server}-${ts}.tar.gz"

  star::log::info "backing up ${src} → ${archive}"
  tar -C "${INSTALL_DIR}/StarRupture" -czf "$archive" Saved
  local size
  size=$(stat -c%s "$archive" 2>/dev/null || echo "?")
  star::log::ok "backup complete: $archive (${size} bytes)"
}
