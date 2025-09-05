#!/usr/bin/env bash
set -euo pipefail

# Usage: ./port.sh [/path/to/USB]
USB_ROOT="${1:-/run/media/emrah/4a6d542b-dd34-4843-b25b-22644ea41060}"
sudo test -d "$USB_ROOT" || { echo "USB root not found: $USB_ROOT" >&2; exit 1; }

APP_ATTR="#nvidia-jetson-orin-nx-release-nodemoapps-from-x86_64-flash-qspi-salukiv3"

echo "→ Building $APP_ATTR"
FLASH_OUT="$(nix build ".$APP_ATTR" --print-out-paths)"

# (Optional but recommended) Include a few basics so launcher can prefer /nix tools if present
EXTRA_OUTS=()
append_outs() {
  local p="$1"
  while IFS= read -r line; do
    [[ -n "$line" ]] && EXTRA_OUTS+=("$line")
  done < <(nix build "$p" --print-out-paths)
}
echo "→ Ensuring nixpkgs#bash is included (interpreter for shell wrappers)"
append_outs "nixpkgs#bash"
echo "→ Ensuring nixpkgs#coreutils is included (mktemp, head, dd, etc.)"
append_outs "nixpkgs#coreutils"
echo "→ Ensuring nixpkgs#util-linux is included (mount, lsblk, unshare, etc.)"
append_outs "nixpkgs#util-linux"

TARGETS=("$FLASH_OUT" "${EXTRA_OUTS[@]}")

echo "→ Computing runtime closure"
readarray -t CLOSURE < <(nix-store -qR -- "${TARGETS[@]}")

echo "→ Copying closure paths with rsync --relative (preserves links/metadata)"
sudo mkdir -p "$USB_ROOT/nix/store"

# Remove any previous partial tree for the main derivation to avoid stale zero-size files
sudo rm -rf "$USB_ROOT$FLASH_OUT" || true

for p in "${CLOSURE[@]}"; do
  if [[ -d "$p" ]]; then
    # Directory: copy contents (note trailing slash) and recreate full path
    sudo rsync -aH --relative "$p/" "$USB_ROOT/"
  else
    # File: copy as-is, recreating the full path
    sudo rsync -aH --relative "$p" "$USB_ROOT/"
  fi
done

# Record the exact binary path for the launcher (NO trailing newline)
FLASH_BIN_ABS="/nix/store/$(basename "$FLASH_OUT")/bin/flash-ghaf-host"
printf '%s' "$FLASH_BIN_ABS" | sudo tee "$USB_ROOT/.flash-bin-path" >/dev/null

# Verify the binary exists and is non-zero on BOTH source & USB
SRC_BIN="$FLASH_OUT/bin/flash-ghaf-host"
DST_BIN="$USB_ROOT$FLASH_BIN_ABS"
if [[ ! -f "$SRC_BIN" ]]; then
  echo "ERROR: Source binary missing: $SRC_BIN" >&2
  exit 1
fi
if [[ ! -f "$DST_BIN" ]]; then
  echo "ERROR: Destination binary missing: $DST_BIN" >&2
  exit 1
fi

SRC_SZ="$(stat -c '%s' "$SRC_BIN")"
DST_SZ="$(stat -c '%s' "$DST_BIN")"
echo "Source size: $SRC_SZ bytes"
echo "USB size:    $DST_SZ bytes"
if [[ "$SRC_SZ" -eq 0 || "$DST_SZ" -eq 0 || "$SRC_SZ" -ne "$DST_SZ" ]]; then
  echo "ERROR: Size mismatch or zero-byte copy; copy failed. Aborting." >&2
  exit 1
fi

echo "✅ Done. Store size on USB:"
sudo du -sh "$USB_ROOT/nix/store" | cat
echo "   flash binary recorded at: $FLASH_BIN_ABS"

sync

