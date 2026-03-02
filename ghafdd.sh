#!/run/current-system/sw/bin/bash
set -euo pipefail

# --- Root check ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root. Needed for flashing usb."
  exit 1
fi

# --- Where to find makediskimage.sh ---
# Use env override if provided, otherwise prefer ./makediskimage.sh, else PATH.
MAKE_DISK_IMG_CMD="${MAKE_DISK_IMG_CMD:-}"
if [[ -z "${MAKE_DISK_IMG_CMD}" ]]; then
  if [[ -x "./makediskimage.sh" ]]; then
    MAKE_DISK_IMG_CMD="./makediskimage.sh"
  elif command -v makediskimage.sh >/dev/null 2>&1; then
    MAKE_DISK_IMG_CMD="$(command -v makediskimage.sh)"
  else
    MAKE_DISK_IMG_CMD=""  # only needed if we must merge ESP+ROOT
  fi
fi

# --- Resolve which image to flash ---
FILE=""
echo "Checking if the image file exists..."

# Case A: Use a prebuilt sd-image if available
if [ -d "./result/sd-image" ] && compgen -G "./result/sd-image/*.zst" > /dev/null; then
  # If multiple, pick the newest by mtime
  FILE="$(ls -1t ./result/sd-image/*.zst | head -n1)"
  echo "Found sd-image. Selected image: ${FILE}"

# Case B: No sd-image; try to merge esp+root into a disk image
elif [[ -f "./result/esp.img.zst" && -f "./result/root.img.zst" ]]; then
  echo "No sd-image found. Will merge result/esp.img.zst + result/root.img.zst into disk.img.zst"

  if [[ -z "${MAKE_DISK_IMG_CMD}" ]]; then
    echo "Error: makediskimage.sh not found (neither ./makediskimage.sh nor in PATH)."
    echo "Set MAKE_DISK_IMG_CMD to the script path or place makediskimage.sh next to this script."
    exit 1
  fi

  echo "Merging with: ${MAKE_DISK_IMG_CMD}"
  "${MAKE_DISK_IMG_CMD}" \
    --esp ./result/esp.img.zst \
    --root ./result/root.img.zst \
    --out ./disk.img.zst

  FILE="./disk.img.zst"
  echo "Created merged disk image: ${FILE}"

# Case C: Nothing found
else
  echo "Image file not found!!!"
  echo "Either:"
  echo "  • run: nix build  (so ./result/sd-image/*.zst exists)"
  echo "  • or ensure: ./result/esp.img.zst and ./result/root.img.zst exist (so we can merge)"
  exit 1
fi

echo "Detected the image file: ${FILE}"

# --- Pre-flight: estimate stream size (kept as in your script) ---
echo "Checking the required minimum size for USB drive (streaming test)…"
zstdcat "${FILE}" | pv -b > /dev/null

# --- Prompt to insert USB ---
echo
echo "Please insert a USB drive to flash the Ghaf image and press any key to continue…"
read -s -n 1
echo "You pressed a key! Continuing…"
sleep 1

# --- Detect USB block device ---
# Keep your original approach but fix typos, and add a more robust lsblk-based path.
# 1) Try to find the most recently added 'sdX' from dmesg
DRIVED="$(dmesg | grep -o 'sd[a-z]' | tail -n1 || true)"

# 2) Prefer lsblk filter: non-readonly, size > 0, optional transport=usb
#    Cross-check with DRIVED if available
LSBLK_CANDIDATES="$(lsblk -d -n -b -o NAME,SIZE,RO,TRAN 2>/dev/null | awk '$3=="0" && $2!="0" {print $1,$4}')"
# Filter for USB first, else fallback to any candidate matching DRIVED
DRIVE_NAME=""
while read -r name tran; do
  if [[ "${tran:-}" == "usb" ]]; then
    DRIVE_NAME="$name"
    break
  fi
done <<< "${LSBLK_CANDIDATES}"

if [[ -z "${DRIVE_NAME}" && -n "${DRIVED}" ]]; then
  # Match the name from DRIVED if present
  while read -r name tran; do
    if [[ "$name" == "$DRIVED" ]]; then
      DRIVE_NAME="$name"
      break
    fi
  done <<< "${LSBLK_CANDIDATES}"
fi

# Final fallback: use DRIVED directly if nothing else worked
if [[ -z "${DRIVE_NAME}" && -n "${DRIVED}" ]]; then
  DRIVE_NAME="${DRIVED}"
fi

if [[ -z "${DRIVE_NAME}" ]]; then
  echo "USB not detected automatically."
  echo "Available block devices:"
  lsblk -d -o NAME,SIZE,MODEL,TRAN,RM
  echo
  read -rp "Type the device name to use (e.g., sdb): " DRIVE_NAME
fi

DRIVE="/dev/${DRIVE_NAME}"
DEVICE1="${DRIVE}1"
DEVICE2="${DRIVE}2"

if [ -b "${DRIVE}" ]; then
  echo "The USB drive is ${DRIVE}"
else
  echo "USB not detected as block device: ${DRIVE}"
  echo "Please ensure your system can see the USB device and re-run this script."
  exit 2
fi

# --- Ensure partitions are not mounted ---
echo "Checking if the USB partitions are mounted — will unmount if needed."
while findmnt "${DEVICE1}" >/dev/null 2>&1; do
  umount "${DEVICE1}" >/dev/null 2>&1 || true
done
echo "Device ${DEVICE1} is safe."

while findmnt "${DEVICE2}" >/dev/null 2>&1; do
  umount "${DEVICE2}" >/dev/null 2>&1 || true
done
echo "Device ${DEVICE2} is safe."

# Extra: attempt to unmount any partition of the target device (covers more than p1/p2)
for p in /dev/disk/by-partuuid/*; do
  [ -e "$p" ] || continue
done

# --- Flash ---
echo "Writing the image to USB (this may take a while)…"
# Using pv for progress; zstdcat for decompression; direct write to the block device.
# You can add oflag=direct to reduce page cache effects if desired.
zstdcat -v "${FILE}" | pv -b > "${DRIVE}"

sync
echo "Successfully written image to ${DRIVE}"
exit 0
