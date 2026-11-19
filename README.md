# pi-golden-image

Build the smallest practical Raspberry Pi OS Lite (arm64) image for a
headless k3s / Kubernetes cluster node - or any other Pi cluster node that
doesn't need a desktop, Bluetooth, a camera, or Wi-Fi.

The idea: strip once, flash everywhere. Build a "golden image" that already
has the unneeded packages removed, and just `dd` it to every node's SD card.
No per-card apt work, no repeated boot-time cleanup script - one build
produces one image that every node in the cluster uses as-is.

No Raspberry Pi or arm64 machine required to build it: the build runs
entirely inside a privileged Docker container on any amd64 (or arm64)
machine, or in CI - it loop-mounts the image file and chroots into it with
`qemu-aarch64-static`.

## Usage

```
./run.sh <input.img> <output.img> [strip-list]
```

E.g.:

```
./run.sh raspios-lite-arm64.img raspios-lite-arm64-k3s.img
```

- `input.img`: an already downloaded, decompressed Raspberry Pi OS Lite
  **arm64** image (`.img`, not `.xz`). Get the latest one from
  <https://downloads.raspberrypi.com/raspios_lite_arm64_latest>.
- `output.img`: where the finished, shrunk image goes.
- `strip-list` is optional, defaults to `strip-packages.list` in this
  directory.

`run.sh` builds the build container (`Dockerfile`) and runs it in
`--privileged` mode (needed for loop devices + chroot). Nothing extra needs
installing on the Docker host - `qemu-user-static`, `binfmt-support`, etc.
all live inside the container.

## What it does

1. Makes a working copy of the input image.
2. Reads the partition table and loop-mounts the boot and root partitions.
3. Copies `qemu-aarch64-static` into the chroot, bind-mounts `/dev`,
   `/dev/pts`, `/proc`, `/sys`, and sets `policy-rc.d` so nothing tries to
   start a service while inside the chroot.
4. Removes every installed package listed in `strip-packages.list` in one
   batched `apt-get purge`, then `autoremove --purge` and `apt-get clean`.
5. Cleans up: wipes `machine-id`, log files, the apt cache, bash history -
   a reproducible, "fresh" state.
6. Runs `zerofree` on the root partition, then shrinks the result with
   [PiShrink](https://github.com/Drewsif/PiShrink) (pinned to an exact
   commit in the Dockerfile, MIT licensed, single-file script).

## Editing the strip list

`strip-packages.list`: one dpkg package name per line, `#` for comments.
The default list removes Bluetooth, Avahi/mDNS, camera/GPIO Python
bindings, man pages, and (by default - see the comment in the file) the
Wi-Fi stack, on the assumption that a cluster node is headless and wired.
It deliberately never touches anything boot, network, SSH, or config-
management related. Extend it if you find more dead weight on your
particular node image; comment out a block if you need something back
(e.g. Wi-Fi).

## Automated monthly build

`.github/workflows/build.yml` downloads the latest official Raspberry Pi OS
Lite arm64 image, runs this build against it, and publishes the result as a
GitHub Release asset (compressed with `xz`, plus a `.sha256` checksum file).
It runs on the 1st of every month and can also be triggered manually from
the Actions tab. Being a public repository, this costs nothing to run on
GitHub-hosted runners.

Grab the latest build from the
[Releases](../../releases) page, or build your own locally with `run.sh` if
you want a different strip list.
