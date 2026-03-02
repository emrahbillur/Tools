#!/usr/bin/env bash
set -euo pipefail

# make-disk-from-template.sh
#
# Build a GPT disk image from ESP + ROOT images using the layout implied by the
# provided Tegra-style partition template:
#   - Reserve 10MiB at the front (MBR + primary_gpt: 512 + 19968 sectors)
#   - Place ESP near the beginning (after the reservation)
#   - Place APP (rootfs) ALIGNED to 8MiB and AT THE END of the disk
#   - Partition numbers: APP = #1, ESP = #2
#
# Usage:
#   ./make-disk-from-template.sh --esp esp.img[.zst] --root root.img[.zst] --out disk.img.zst
#
# Options:
#   --sector-size 512         # logical sector size; keep 512 unless you know otherwise
#   --esp-name esp            # GPT name for ESP
#   --app-name APP            # GPT name for root
#   --esp-type EF00           # GPT type for ESP (default EF00)
#   --app-type 8300           # GPT type for root (default 8300)
#   --app-guid <UUID>         # Optional fixed PARTITION GUID for APP (root)
#   --keep-raw                # Keep uncompressed raw disk.img alongside output
#
# Notes:
# - We accept .zst or plain .img inputs for ESP/ROOT.
# - The script computes LBAs and writes payloads with 'dd' at exact offsets.
# - Backup GPT area is assumed to be 33 sectors (32 for table + 1 header).
#
# Template-derived constants:
#   HEAD_GAP_SECTORS = 512 (MBR) + 19968 (primary_gpt) = 20480 = 10MiB @ 512B sectors
#   APP_ALIGN_SECTORS = 16384 (8MiB alignment)
#   BACKUP_GPT_SECTORS = 33 (typical for 128 entries GPT; 32 table + 1 header)

SECTOR_SIZE=512
ESP_NAME="esp"
APP_NAME="APP"
ESP_TYPE="EF00"
APP_TYPE="8300"
APP_GUID=""
KEEP_RAW=0

ESP_IN=""
ROOT_IN=""
OUT_ZST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --esp) ESP_IN="$2"; shift 2 ;;
    --root) ROOT_IN="$2"; shift 2 ;;
    --out) OUT_ZST="$2"; shift 2 ;;
    --sector-size) SECTOR_SIZE="$2"; shift 2 ;;
    --esp-name) ESP_NAME="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --esp-type) ESP_TYPE="$2"; shift 2 ;;
    --app-type) APP_TYPE="$2"; shift 2 ;;
    --app-guid) APP_GUID="$2"; shift 2 ;;
    --keep-raw) KEEP_RAW=1; shift 1 ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${ESP_IN}" || -z "${ROOT_IN}" || -z "${OUT_ZST}" ]]; then
  echo "Error: --esp, --root and --out are required." >&2
  echo "make-disk-from-template.sh"
  echo "Build a GPT disk image from ESP + ROOT images using the layout implied by the"
  echo "provided Tegra-style partition template:"
  echo "   - Reserve 10MiB at the front (MBR + primary_gpt: 512 + 19968 sectors)"
  echo "   - Place ESP near the beginning (after the reservation)"
  echo "   - Place APP (rootfs) ALIGNED to 8MiB and AT THE END of the disk"
  echo "   - Partition numbers: APP = #1, ESP = #2"
  echo ""
  echo "# Usage:
  echo "#   ./make-disk-from-template.sh --esp esp.img[.zst] --root root.img[.zst] --out disk.img.zst
  echo ""
  echo " Options:"
  echo "   --sector-size 512         # logical sector size; keep 512 unless you know otherwise"
  echo "   --esp-name esp            # GPT name for ESP"
  echo "   --app-name APP            # GPT name for root"
  echo "   --esp-type EF00           # GPT type for ESP (default EF00)"
  echo "   --app-type 8300           # GPT type for root (default 8300)"
  echo "   --app-guid <UUID>         # Optional fixed PARTITION GUID for APP (root)"
  echo "   --keep-raw                # Keep uncompressed raw disk.img alongside output"
  exit 1
fi

for cmd in zstd sgdisk dd stat truncate; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required"; exit 1; }
done

# Workspace
WORKDIR="$(mktemp -d -t diskxml-XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Decompress inputs if they are .zst; otherwise copy as-is
decompress_if_needed() {
  local in="$1" out="$2"
  if [[ "$in" == *.zst ]]; then
    unzstd -f -o "$out" "$in"
  else
    cp -f "$in" "$out"
  fi
}

ESP_IMG="$WORKDIR/esp.img"
ROOT_IMG="$WORKDIR/root.img"
DISK_IMG="$WORKDIR/disk.img"

echo "==> Preparing inputs in: $WORKDIR"
decompress_if_needed "$ESP_IN" "$ESP_IMG"
decompress_if_needed "$ROOT_IN" "$ROOT_IMG"

# Sizes -> sectors (round up)
bytes_to_sectors() {
  local bytes="$1" ; local sect="$2"
  echo $(( (bytes + sect - 1) / sect ))
}
ceil_div() { # ceil_div a b
  echo $(( ($1 + $2 - 1) / $2 ))
}
floor_align() { # floor_align value align
  local v="$1" a="$2"
  echo $(( (v / a) * a ))
}
ceil_align() { # ceil_align value align
  local v="$1" a="$2"
  echo $(( ((v + a - 1) / a) * a ))
}

ESP_SIZE_BYTES=$(stat -c%s "$ESP_IMG")
ROOT_SIZE_BYTES=$(stat -c%s "$ROOT_IMG")

ESP_NSECT=$(bytes_to_sectors "$ESP_SIZE_BYTES" "$SECTOR_SIZE")
ROOT_NSECT=$(bytes_to_sectors "$ROOT_SIZE_BYTES" "$SECTOR_SIZE")

# Template-driven constants
HEAD_GAP_SECTORS=$((512 + 19968))  # 10MiB at 512B sectors
APP_ALIGN_SECTORS=16384            # 8MiB
ESP_ALIGN_SECTORS=$((2048))        # 1MiB alignment for ESP (reasonable)
BACKUP_GPT_SECTORS=33              # default GPT backup size (128 entries)

# Place ESP right after the reserved front area, aligned
ESP_START_LBA=$(ceil_align "$HEAD_GAP_SECTORS" "$ESP_ALIGN_SECTORS")
ESP_END_LBA=$((ESP_START_LBA + ESP_NSECT - 1))

# We'll place APP (root) at the END of disk, aligned to 8MiB boundary.
# To do this, we must choose a disk size (in sectors). We can start with a lower bound and
# then compute the aligned APP start from the end. If APP would overlap ESP, we increase the disk size.

# Start with a minimal "base" size:
#   base = space up to end of ESP + a small mid-gap + APP size + backup GPT
MID_GAP_SECTORS=$((2048)) # 1MiB safety gap between ESP and APP (not required but nice)
BASE_MIN_END=$((ESP_END_LBA + MID_GAP_SECTORS + ROOT_NSECT + BACKUP_GPT_SECTORS))
# Round the provisional disk end up to an 8MiB boundary so APP can align nicely at the end
DSECT=$(ceil_align "$BASE_MIN_END" "$APP_ALIGN_SECTORS")

# Compute APP from the end
compute_app_from_end() {
  local disk_last_lba=$((DSECT - 1))
  # The last usable LBA is *before* the backup GPT area (header + table)
  local app_last_usable=$((disk_last_lba - BACKUP_GPT_SECTORS))  # <-- FIXED (no -1)
  local app_end=$app_last_usable
  local app_start_unaligned=$((app_end - ROOT_NSECT + 1))
  local app_start
  app_start=$(floor_align "$app_start_unaligned" "$APP_ALIGN_SECTORS")
  echo "$app_start $app_end"
}

APP_POS=($(compute_app_from_end))
APP_START_LBA="${APP_POS[0]}"
APP_END_LBA="${APP_POS[1]}"

# Ensure APP does not overlap ESP; if it does, grow the disk until they don't
while (( APP_START_LBA <= ESP_END_LBA + MID_GAP_SECTORS )); do
  # Increase disk by one alignment chunk and recompute
  DSECT=$((DSECT + APP_ALIGN_SECTORS))
  APP_POS=($(compute_app_from_end))
  APP_START_LBA="${APP_POS[0]}"
  APP_END_LBA="${APP_POS[1]}"
done

DISK_SIZE_BYTES=$(( DSECT * SECTOR_SIZE ))

echo "==> Computed layout (sector size = ${SECTOR_SIZE}B)"

to_mib() { echo $(( ($1 * SECTOR_SIZE) / 1024 / 1024 )); }

printf "    Reserved head (MBR+primary_gpt): %d sectors (~%d MiB)\n" \
  "$HEAD_GAP_SECTORS" "$(to_mib "$HEAD_GAP_SECTORS")"
printf "    ESP : start=%-10d end=%-10d size=%-10d sectors (~%d MiB)\n" \
  "$ESP_START_LBA" "$ESP_END_LBA" "$ESP_NSECT" $(( (ESP_NSECT * SECTOR_SIZE) / 1024 / 1024 ))
printf "    APP : start=%-10d end=%-10d size=%-10d sectors (~%d MiB) [aligned 8MiB]\n" \
  "$APP_START_LBA" "$APP_END_LBA" "$ROOT_NSECT" $(( (ROOT_NSECT * SECTOR_SIZE) / 1024 / 1024 ))
printf "    Disk last LBA = %d  (backup GPT = %d sectors at end)\n" $((DSECT - 1)) "$BACKUP_GPT_SECTORS"
printf "    Disk size ≈ %d MiB\n" $(( DISK_SIZE_BYTES / 1024 / 1024 ))

echo "==> Creating sparse disk image"
truncate -s "$DISK_SIZE_BYTES" "$DISK_IMG"

echo "==> Creating GPT and partitions with sgdisk"
# Clear any residual GPT
sgdisk --clear "$DISK_IMG" >/dev/null

# Create ESP as partition #2 at computed LBAs
# Create APP (root) as partition #1 at computed LBAs (so it shows as /dev/mmcblk0p1)
if [[ -n "$APP_GUID" ]]; then
  sgdisk \
    --new=2:${ESP_START_LBA}:${ESP_END_LBA} --typecode=2:${ESP_TYPE} --change-name=2:"${ESP_NAME}" \
    --new=1:${APP_START_LBA}:${APP_END_LBA} --typecode=1:${APP_TYPE} --change-name=1:"${APP_NAME}" \
    --partition-guid=1:"${APP_GUID}" \
    "$DISK_IMG" >/dev/null
else
  sgdisk \
    --new=2:${ESP_START_LBA}:${ESP_END_LBA} --typecode=2:${ESP_TYPE} --change-name=2:"${ESP_NAME}" \
    --new=1:${APP_START_LBA}:${APP_END_LBA} --typecode=1:${APP_TYPE} --change-name=1:"${APP_NAME}" \
    "$DISK_IMG" >/dev/null
fi

echo "==> Writing ESP payload -> partition #2 at LBA ${ESP_START_LBA}"
dd if="$ESP_IMG" of="$DISK_IMG" bs="$SECTOR_SIZE" seek="$ESP_START_LBA" conv=notrunc status=progress

echo "==> Writing APP (root) payload -> partition #1 at LBA ${APP_START_LBA}"
dd if="$ROOT_IMG" of="$DISK_IMG" bs="$SECTOR_SIZE" seek="$APP_START_LBA" conv=notrunc status=progress

echo "==> Partition table summary:"
sgdisk -p "$DISK_IMG" || true
echo

if command -v fdisk >/dev/null 2>&1; then
  echo "==> fdisk -l (for reference):"
  fdisk -l "$DISK_IMG" || true
fi

echo "==> Compressing disk -> $OUT_ZST"
zstd -T0 -f -o "$OUT_ZST" "$DISK_IMG"

if [[ "$KEEP_RAW" -eq 1 ]]; then
  RAW_OUT="$(dirname "$OUT_ZST")/$(basename "$OUT_ZST" .zst)"
  cp -f "$DISK_IMG" "$RAW_OUT"
  echo "==> Kept raw image at: $RAW_OUT"
fi

echo "-> Done. Output: $OUT_ZST"
