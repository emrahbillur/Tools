port.sh

Builds a Nix flake app and copies its runtime closure and launcher.sh to a
destination. The destination may be a local directory or a remote SSH/rsync
location, so USB storage is optional. Remote destinations require SSH access,
rsync on the remote host, and write permission for the SSH user.

Examples:
  ./port.sh /mnt/runtime
  ./port.sh user@host:/srv/runtime
  ./port.sh --help

launcher.sh

Runs flash-ghaf-host from the copied runtime on a Linux host. Specify the
directory containing nix/store with --runtime-root, or set RUNTIME_ROOT. If
launcher.sh is located inside that directory, it can detect the runtime root
automatically.

Examples:
  ./launcher.sh --runtime-root=/path/to/runtime
  ./launcher.sh --runtime-root /path/to/runtime --debug
  ./launcher.sh --runtime-root=/path/to/runtime -- --flash-option value
  ./launcher.sh --help

Launcher options are handled by launcher.sh. Other arguments are passed to
flash-ghaf-host; use -- to explicitly mark the beginning of flash options.

makediskimage.sh

Merges esp.img.zst and root.img.zst into a single nixos.img.zst with the
expected partition structure. It is used by ghafdd.sh.

ghafdd.sh

Writes NixOS images to USB drives. It checks image and target sizes, detects
mounted USB drives, and can merge separate ESP and root images automatically.

On NixOS, ghafdd.sh and makediskimage.sh can be added to environment.systemPackages
with writeShellScriptBin wrappers. On other Linux distributions, add the scripts
to PATH as needed.
