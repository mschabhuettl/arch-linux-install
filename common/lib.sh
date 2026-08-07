#!/bin/bash
# lib.sh - shared helpers for the Arch install scripts.
# Sourced by 00-pre-chroot.sh and 01-post-chroot.sh; not meant to be executed.

# CACHE_SERVER is provided by defaults.env, sourced by the calling script.
# shellcheck disable=SC2154

verbose() {
  echo -e "\033[1;32m[INFO]\033[0m $1"
}

error_message() {
  echo -e "\033[1;31m[ERROR]\033[0m $1"
}

die() {
  error_message "$1"
  exit 1
}

# Run a plain command, logging it first. The `if !` guard works together with
# `set -e`: without it the shell would exit on failure before we could print
# a useful error message. Not for pipelines or redirections.
run() {
  verbose "Executing: $*"
  if ! "$@"; then
    error_message "Command failed -> $*"
    exit 1
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root."
  fi
}

require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      die "Required tool '$tool' not found. On the live ISO: pacman -Sy $tool"
    fi
  done
}

# Fail early if a variable from the env files is missing (works for arrays too).
require_vars() {
  local var
  for var in "$@"; do
    if ! declare -p "$var" >/dev/null 2>&1; then
      die "Required variable '$var' is not set. Check defaults.env / host env."
    fi
  done
}

# Insert a CacheServer line after the Include line of the [core] and [extra]
# sections. CACHE_SERVER contains literal \$repo/\$arch which pacman expands
# itself; sed treats $ in the replacement as a literal character.
add_cache_server() {
  local conf="$1"
  sed -i "/^\[core\]/,/^Include/ s|^Include.*|&\nCacheServer = ${CACHE_SERVER}|" "$conf"
  sed -i "/^\[extra\]/,/^Include/ s|^Include.*|&\nCacheServer = ${CACHE_SERVER}|" "$conf"
}
