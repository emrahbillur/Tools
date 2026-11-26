# Tools

Personal scripts for building and flashing NixOS images.

## `port.sh`

Builds a Nix flake app and copies its runtime closure, `.flash-bin-path` file,
and executable `launcher.sh` to a destination. The destination can be a local
directory or a remote SSH/rsync destination, so the runtime can be stored on a
USB drive, another mounted disk, or a remote Linux host.

```bash
# Local directory
./port.sh /mnt/runtime

# Remote directory (SSH access and remote rsync required)
./port.sh user@host:/srv/runtime

# Package the runtime in a gzip-compressed tar archive
./port.sh -tar /mnt/usb/flash-runtime.tar.gz

# Choose a different Nix flake attribute
./port.sh /mnt/runtime '#nixosConfigurations.host.config.system.build.toplevel'

# Show all port.sh options
./port.sh --help
```

The remote SSH user must be able to write to the destination. `port.sh` builds
the requested attribute plus the Bash, coreutils, and util-linux closures,
copies them under `nix/store`, installs the repository's `launcher.sh`, and
checks the copied flash binary. Set `LAUNCHER_URL` to fetch a different launcher.

With `-tar`, DESTINATION is the archive file path (local or `user@host:path`).
The runtime is gzip-compressed, and `launcher.sh` is placed in the same
directory. A `.tar` destination is changed to `.tar.gz`; destinations without
an archive suffix have `.tar.gz` appended. When run beside the archive without
an explicit runtime root, the launcher extracts it into a temporary directory,
runs the flash program, and removes the temporary runtime when it exits.
Run tar mode as your regular user; it does not need `sudo`.

## `launcher.sh`

Run the copied flash program on the destination Linux system. The runtime root
is the directory containing `nix/store`; it can be provided with either form
below or through the `RUNTIME_ROOT` environment variable. When the launcher is
inside the runtime root, it can also infer that directory automatically.

```bash
./launcher.sh --runtime-root=/path/to/runtime
./launcher.sh --runtime-root /path/to/runtime

# Launcher options are consumed; other arguments go to flash-ghaf-host
./launcher.sh --runtime-root=/path/to/runtime --debug -- --flash-option value

# Show launcher options
./launcher.sh --help
```

The launcher mounts the runtime's `nix` directory at `/nix` and runs
`flash-ghaf-host` with the supplied flash arguments. It uses a private mount
namespace when `unshare` is available.

## Other scripts

- `makediskimage.sh` merges `esp.img.zst` and `root.img.zst` into a single
  `nixos.img.zst` image with the expected partition structure. It is used by
  `ghafdd.sh`.
- `ghafdd.sh` writes NixOS images to USB drives, checks the image and target
  sizes, and can merge separate ESP and root images automatically.

## Adding scripts to `PATH` on NixOS

You can add `ghafdd.sh` and `makediskimage.sh` to your NixOS configuration.
Replace `/home/emrah/reps/Tools` with the location of this repository.

```nix
environment.systemPackages = with pkgs; [
  wget
  (pkgs.writeShellScriptBin "ghafdd.sh" ''
    exec /home/emrah/reps/Tools/ghafdd.sh "$@"
  '')
  (pkgs.writeShellScriptBin "makediskimage.sh" ''
    exec /home/emrah/reps/Tools/makediskimage.sh "$@"
  '')
];
```

On other Linux distributions, add the scripts to `PATH` as needed.
