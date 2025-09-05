#!/usr/bin/env bash
set -euo pipefail

# --- Locate USB root with nix/store ---
resolve_usb_root() {
  if [[ "${1:-}" == --usb-root=* ]]; then echo "${1#--usb-root=}"; return 0; fi
  if [[ -n "${USB_ROOT:-}" ]]; then echo "$USB_ROOT"; return 0; fi
  # Script directory (works if launcher lives on the USB)
  local d; d="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -d "$d/nix/store" ]]; then echo "$d"; return 0; fi
  # Common mounts you've used
  if [[ -d "/media/ghaf/4a6d542b-dd34-4843-b25b-22644ea41060/nix/store" ]]; then
    echo "/media/ghaf/4a6d542b-dd34-4843-b25b-22644ea41060"; return 0
  fi
  if [[ -d "/run/media/emrah/4a6d542b-dd34-4843-b25b-22644ea41060/nix/store" ]]; then
    echo "/run/media/emrah/4a6d542b-dd34-4843-b25b-22644ea41060"; return 0
  fi
  if [[ -d "/run/media/emrah/A54E-0B0B/nix/store" ]]; then
    echo "/run/media/emrah/A54E-0B0B"; return 0
  fi
  return 1
}

# Parse args
DEBUG="false"
USB_ROOT=""
for arg in "$@"; do
  case "$arg" in
    --usb-root=*) USB_ROOT="${arg#--usb-root=}";;
    --debug) DEBUG="true";;
  esac
done
if [[ -z "$USB_ROOT" ]]; then
  USB_ROOT="$(resolve_usb_root "${1:-}")" || {
    echo "Could not find the USB root with nix/store." >&2
    echo "Usage: $0 --usb-root=/path/to/USB [--debug]" >&2
    exit 1
  }
fi

# Determine exact binary path; prefer recorded file if present
if [[ -f "$USB_ROOT/.flash-bin-path" ]]; then
  FLASH_PATH_ABS="$(tr -d '\r\n' < "$USB_ROOT/.flash-bin-path")"
else
  shopt -s nullglob
  matches=("$USB_ROOT"/nix/store/*-flash-ghaf-host/bin/flash-ghaf-host)
  shopt -u nullglob
  [[ ${#matches[@]} -gt 0 ]] || { echo "flash-ghaf-host not found on USB"; exit 1; }
  FLASH_PATH_ABS="/nix/store/$(basename "$(dirname "${matches[0]}")")/bin/flash-ghaf-host"
fi
[[ -x "$USB_ROOT${FLASH_PATH_ABS}" ]] || { echo "Missing: $USB_ROOT${FLASH_PATH_ABS}"; exit 1; }

command -v sudo >/dev/null 2>&1 || { echo "sudo required"; exit 1; }

echo "→ Creating private mount namespace and running $FLASH_PATH_ABS (no args)"

# If unshare exists, prefer private mount namespace; otherwise, global mount fallback.
if command -v unshare >/dev/null 2>&1; then
  # Build inner script (runs as root in a private mount ns)
  read -r -d '' INNER <<'EOSH' || true
set -euo pipefail

# Inputs: USB_ROOT, FLASH_PATH_ABS, DEBUG, HOST_PATH

# 1) Create /nix and bind the USB's nix (only in this mount ns)
mkdir -p /nix
mount --bind "$USB_ROOT/nix" /nix || { echo "ERROR: bind-mount failed"; exit 1; }
# 1a) Ensure exec on the bind mount even if USB is 'noexec'
mount -o remount,bind,exec /nix 2>/dev/null || mount -o remount,exec /nix 2>/dev/null || true

# 2) PATH: prefer all /nix/store/*/bin, then fall back to host PATH
PATH_BUILT=""
for d in /nix/store/*/bin; do
  [ -d "$d" ] && PATH_BUILT="$d:$PATH_BUILT"
done
export PATH="${PATH_BUILT}${HOST_PATH:+:$HOST_PATH}"

if [[ "${DEBUG:-false}" == "true" ]]; then
  echo "DEBUG: USB_ROOT=$USB_ROOT"
  echo "DEBUG: FLASH_PATH_ABS=$FLASH_PATH_ABS"
  echo "DEBUG: PATH=$PATH"
fi
# 3) Decide how to exec flash-ghaf-host:
#    - If ELF: exec directly
#    - If script: use shebang interpreter if present; else fallback to same interpreter by basename from PATH

# Detect if script via shebang magic
magic="$(dd if="$FLASH_PATH_ABS" bs=2 count=1 status=none 2>/dev/null || true)"
if [[ "$magic" == "#!"* ]]; then
  IFS= read -r firstline < "$FLASH_PATH_ABS" || true
  interp="${firstline#\#!}"     # remove "#!"
  set -- $interp                # split shebang into interpreter + args
  interpreter="${1:-}"; shift || true
  if [[ -n "$interpreter" && -x "$interpreter" ]]; then
    [[ "$DEBUG" == "true" ]] && echo "DEBUG: Using shebang interpreter: $interpreter $*"
    exec "$interpreter" "$FLASH_PATH_ABS" "$@"
  else
    base="${interpreter##*/}"
    if [[ -n "$base" ]] && command -v "$base" >/dev/null 2>&1; then
      [[ "$DEBUG" == "true" ]] && echo "DEBUG: Shebang interp not on /nix; using host PATH: $base $*"
      exec "$base" "$FLASH_PATH_ABS" "$@"
    else
      if command -v bash >/dev/null 2>&1; then
        [[ "$DEBUG" == "true" ]] && echo "DEBUG: Falling back to 'bash' from host PATH"
        exec bash "$FLASH_PATH_ABS"
      fi
      echo "ERROR: Cannot resolve interpreter for shebang: '$interp'" >&2
      exit 127
    fi
  fi
else
  [[ "$DEBUG" == "true" ]] && echo "DEBUG: Detected ELF; exec directly"
  exec "$FLASH_PATH_ABS"
fi
EOSH

  # Run inner script with environment propagated
  exec sudo --preserve-env=USB_ROOT,FLASH_PATH_ABS,DEBUG \
    env USB_ROOT="$USB_ROOT" FLASH_PATH_ABS="$FLASH_PATH_ABS" DEBUG="$DEBUG" HOST_PATH="$PATH" \
    unshare -m --propagation private bash -c "$INNER"
else
  # Fallback: global bind mount (safe on non-Nix hosts; avoid on NixOS workstations)
  echo "WARN: 'unshare' not found; using global /nix bind mount (requires sudo)."
  sudo mkdir -p /nix
  sudo mount --bind "$USB_ROOT/nix" /nix
  sudo mount -o remount,bind,exec /nix 2>/dev/null || sudo mount -o remount,exec /nix 2>/dev/null || true
  trap 'sudo umount /nix || true' EXIT

  # Prefer /nix/store/*/bin tools, then host PATH
  PATH_BUILT=""
  for d in /nix/store/*/bin; do
    [ -d "$d" ] && PATH_BUILT="$d:$PATH_BUILT"
  done
  export PATH="${PATH_BUILT}:$PATH"

  exec "$FLASH_PATH_ABS"
fi
