# Golden image builder container - loop-mounts and chroots into an existing
# Raspberry Pi OS Lite (arm64) image, strips everything a k3s/kube node
# doesn't need, then shrinks the result.
#
# See README.md for usage. This container only holds the build tools; the
# actual image is bind-mounted in at run time (-v).

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-user-static \
        binfmt-support \
        parted \
        util-linux \
        e2fsprogs \
        zerofree \
        xz-utils \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# PiShrink to shrink the finished image (MIT licensed, single-file script).
# Pinned to an exact commit, not the moving "latest".
RUN curl -fsSL -o /usr/local/bin/pishrink.sh \
        https://raw.githubusercontent.com/Drewsif/PiShrink/a5f9463c01607ab07402c7e75c9cfd4bb3a0e886/pishrink.sh \
    && chmod +x /usr/local/bin/pishrink.sh

COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

ENTRYPOINT ["/usr/local/bin/build.sh"]
