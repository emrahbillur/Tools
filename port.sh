#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config / Defaults
# -----------------------------
DEFAULT_USB="/run/media/emrah/4a6d542b-dd34-4843-b25b-22644ea41060"
DEFAULT_APP_ATTR="#nvidia-jetson-orin-nx-release-nodemoapps-from-x86_64-flash-qspi-salukiv3"

# Where to fetch the launcher from (you can override via env LAUNCHER_URL)
: "${LAUNCHER_URL:=https://raw.githubusercontent.com/emrahbillur/Tools/main/launcher.sh}"
LAUNCHER_NAME="${LAUNCHER_NAME:-launcher.sh}"

# -----------------------------
# Args
# -----------------------------
USB_ROOT="${1:-$DEFAULT_USB}"
APP_ATTR="${2:-$DEFAULT_APP_ATTR}"

sudo test -d "$USB_ROOT" || { echo "USB root not found: $USB_ROOT" >&2; exit 1; }

echo "→ USB_ROOT : $USB_ROOT"
echo "→ APP_ATTR : $APP_ATTR"
echo "→ LAUNCHER : $LAUNCHER_URL -> $LAUNCHER_NAME"

# -----------------------------
# Build the app
# -----------------------------
echo "→ Building $APP_ATTR"
FLASH_OUT="$(nix build ".$APP_ATTR" --print-out-paths)"

# -----------------------------
# Helper: accumulate extra outputs (each line → one array entry)
# -----------------------------
EXTRA_OUTS=()
append_outs() {
  local p="$1"
  while IFS= read -r line; do
    [[ -n "$line" ]] && EXTRA_OUTS+=("$line")
  done < <(nix build "$p" --print-out-paths)
}

# Optional extras so we *prefer* /nix/store tools if present on the USB
echo "→ Ensuring nixpkgs#bash is included"
append_outs "nixpkgs#bash"
echo "→ Ensuring nixpkgs#coreutils is included (mktemp, dd, head, etc.)"
append_outs "nixpkgs#coreutils"
echo "→ Ensuring nixpkgs#util-linux is included (mount, lsblk, unshare, etc.)"
append_outs "nixpkgs#util-linux"

TARGETS=("$FLASH_OUT" "${EXTRA_OUTS[@]}")

# -----------------------------
# Compute the full runtime closure
# -----------------------------
echo "→ Computing runtime closure"
readarray -t CLOSURE < <(nix-store -qR -- "${TARGETS[@]}")

if [[ ${#CLOSURE[@]} -eq 0 ]]; then
  echo "ERROR: Closure is empty; build likely failed." >&2
  exit 1
fi

# -----------------------------
# Copy the closure reliably
# -----------------------------
echo "→ Copying closure to $USB_ROOT with rsync --relative (preserves links/metadata)"
sudo mkdir -p "$USB_ROOT/nix/store"

# Remove any previous partial tree for main derivation to avoid stale zero-size files
sudo rm -rf "$USB_ROOT$FLASH_OUT" || true

for p in "${CLOSURE[@]}"; do
  if [[ -d "$p" ]]; then
    # Directory: copy contents (trailing slash) and recreate full path
    sudo rsync -aH --relative "$p/" "$USB_ROOT/"
  else
    # File: copy as-is, recreating the full path
    sudo rsync -aH --relative "$p" "$USB_ROOT/"
  fi
done
# -----------------------------
# Record the exact binary path for the launcher (NO trailing newline)
# -----------------------------
FLASH_BIN_ABS="/nix/store/$(basename "$FLASH_OUT")/bin/flash-ghaf-host"
printf '%s' "$FLASH_BIN_ABS" | sudo tee "$USB_ROOT/.flash-bin-path" >/dev/null
echo "→ Recorded flash binary path at $USB_ROOT/.flash-bin-path"

# Verify sizes (source vs destination)
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
echo "   Source size: $SRC_SZ bytes"
echo "   USB size   : $DST_SZ bytes"
if [[ "$SRC_SZ" -eq 0 || "$DST_SZ" -eq 0 || "$SRC_SZ" -ne "$DST_SZ" ]]; then
  echo "ERROR: Size mismatch or zero-byte copy; copy failed. Aborting." >&2
  exit 1
fi

# -----------------------------
# Fetch launcher.sh from GitHub → USB root
# -----------------------------
echo "→ Fetching launcher from GitHub"
TMP_LAUNCHER="$(mktemp)"
fetch_to_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    # Fallback: use Nix-provided curl
    local CURL_OUT
    CURL_OUT="$(nix build nixpkgs#curl --print-out-paths)"
    "$CURL_OUT/bin/curl" -fsSL "$url" -o "$dest"
  fi
}
if ! fetch_to_file "$LAUNCHER_URL" "$TMP_LAUNCHER"; then
  echo "ERROR: Failed to download launcher from $LAUNCHER_URL" >&2
  exit 1
fi

# Install to USB root and make executable
sudo install -Dm755 "$TMP_LAUNCHER" "$USB_ROOT/$LAUNCHER_NAME"
rm -f "$TMP_LAUNCHER"
echo "→ Placed $LAUNCHER_NAME at $USB_ROOT/$LAUNCHER_NAME (executable)"

# -----------------------------
# Finish
# -----------------------------
echo "✅ Done."
sudo du -sh "$USB_ROOT/nix/store" | awk '{print "USB store size:", $1}'
echo "   Run on target: $LAUNCHER_NAME --usb-root=/path/to/USB"
