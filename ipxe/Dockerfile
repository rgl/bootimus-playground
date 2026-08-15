# syntax=docker/dockerfile:1.26
# see https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/syntax.md

FROM debian:13-slim AS build
RUN bash <<"RUN_EOF"
set -euxo pipefail
apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  gcc-aarch64-linux-gnu \
  ca-certificates \
  git \
  liblzma-dev \
  make \
  wget
RUN_EOF
WORKDIR /build
RUN bash <<"RUN_EOF"
set -euxo pipefail
git clone https://github.com/ipxe/ipxe.git .
# NB ipxe does not do consistent releases, so we checkout a specific commit.
# see https://github.com/ipxe/ipxe/discussions/679#discussioncomment-5214424.
# see https://github.com/ipxe/ipxe/commit/12798ec29aa8a64d8675c4378b99f5fe28447afb 2026-03-06T15:48:55.000Z aka v2.0.0
# see https://github.com/ipxe/ipxe/commit/3ca799eb269c5df414c74b3ae7465ec726fb6372 2026-07-27T14:29:54.000Z
git checkout 3ca799eb269c5df414c74b3ae7465ec726fb6372
RUN_EOF
RUN bash <<"RUN_EOF"
set -euxo pipefail
# configure.
# see https://ipxe.org/buildcfg/cert_cmd
# see https://ipxe.org/buildcfg/download_proto_https
# see https://ipxe.org/buildcfg/image_trust_cmd
# see https://ipxe.org/buildcfg/neighbour_cmd
# see https://ipxe.org/buildcfg/nslookup_cmd
# see https://ipxe.org/buildcfg/ntp_cmd
# see https://ipxe.org/buildcfg/param_cmd
# see https://ipxe.org/buildcfg/ping_cmd
# see https://ipxe.org/buildcfg/poweroff_cmd
# see https://ipxe.org/buildcfg
# see https://ipxe.org/appnote/named_config
cat >src/config/local/general.h <<'EOF'
#define CERT_CMD                /* Certificate management commands */
#define DOWNLOAD_PROTO_HTTPS    /* Secure Hypertext Transfer Protocol */
#define DOWNLOAD_PROTO_TFTP     /* Trivial File Transfer Protocol */
#define IMAGE_TRUST_CMD         /* Image trust management commands */
#define NEIGHBOUR_CMD           /* Neighbour management commands */
#define NSLOOKUP_CMD            /* Name resolution command */
#define NTP_CMD                 /* Network time protocol commands */
#define PARAM_CMD               /* Form parameter commands */
#define PING_CMD                /* Ping command */
#define POWEROFF_CMD            /* Power off command */
#undef  SANBOOT_PROTO_AOE       /* AoE protocol */
EOF
# see https://ipxe.org/buildcfg/keyboard_map
cat >src/config/local/console.h <<'EOF'
// NB this has no effect in EFI mode. you must set the layout in the
//    efi firmware instead.
//#undef KEYBOARD_MAP
//#define KEYBOARD_MAP pt
EOF
RUN_EOF
RUN bash <<"RUN_EOF"
set -euxo pipefail
# build.
# see https://ipxe.org/embed
# see https://ipxe.org/scripting
# see https://ipxe.org/cmd
# see https://ipxe.org/cmd/ifconf
# see https://ipxe.org/appnote/buildtargets
NUM_CPUS=$((`getconf _NPROCESSORS_ONLN` + 2))
# NB sometimes, for some reason, when we change the settings at
#    src/config/local/*.h they will not always work unless we
#    build from scratch.
rm -rf src/bin*
# NB if you are having trouble running iPXE you can make a DEBUG build with,
#    e.g.:
#       make ... DEBUG=init,usb,usbkbd,xhci
#    see iPXE initialising devices... loop at
#        https://lists.ipxe.org/pipermail/ipxe-devel/2021-June/007464.html
make -j $NUM_CPUS -C src \
  bin/undionly.kpxe \
  bin-x86_64-efi/ipxe-legacy.efi \
  DEBUG=init,usb,usbkbd,xhci
# build arm64.
CROSS_COMPILE=aarch64-linux-gnu- \
make -j $NUM_CPUS -C src \
  bin-arm64-efi/ipxe-legacy.efi \
  DEBUG=init,usb,usbkbd,xhci
RUN_EOF

# NB ipxe publishes the latest, unversioned, artifacts at
#    https://boot.ipxe.org, but, to known which revision we are using, we
#    have to build them ourselves.
# NB ipxe.efi from boot.ipxe.org does not support HTTPS.
# NB since ipxe 2.0.0, to work in my machines, I have to use ipxe-legacy.efi.
#    see https://github.com/ipxe/ipxe/issues/1643
# NB snponly.efi is also available.
FROM scratch AS artifacts-amd64
COPY --from=build /build/src/bin/undionly.kpxe /amd64/
COPY --from=build /build/src/bin-x86_64-efi/ipxe-legacy.efi /amd64/ipxe.efi
ADD --chmod=644 https://github.com/ipxe/wimboot/releases/download/v2.9.0/wimboot /amd64/

FROM scratch AS artifacts-arm64
COPY --from=build /build/src/bin-arm64-efi/ipxe-legacy.efi /arm64/ipxe-arm64.efi
ADD --chmod=644 https://github.com/ipxe/wimboot/releases/download/v2.9.0/wimboot.arm64 /arm64/wimboot-arm64
