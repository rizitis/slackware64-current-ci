#!/bin/bash

# ========================
# Slackware64-current Minimal Docker Image Builder (LOCAL MODE)
# ========================

set -e

# root
if [ "$EUID" -ne 0 ]; then
    echo " root or sudo!"
    exit 1
fi


# ============================================================================
# EDIT THESE for your setup:
#   SLACKWARE_TREE  - your local Slackware64-current package tree (a/ ap/ l/
#                     n/ ...), e.g. an rsync of osuosl.org/slackware/slackware64-current/
#   IMAGE_NAME      - YOUR registry/namespace (you cannot push to rizitis'!)
#                     e.g. ghcr.io/<your-github-user>/slackware64-current-ci:tag
#                     or a plain local name like slackware-mini:testing
#   DOCKERHUB_IMAGE - your Docker Hub name for the same image (optional)
#   BINS/           - put your slacker-*.txz next to this script (see the
#                     wiki's Docker page, "Building the image yourself")
# The push at the end is commented out by default - local build only.
# ============================================================================
SLACKWARE_TREE="/home/omen/DOCKER_IMAGES/docker-slackware/TREE/slackware64"
ROOTFS_DIR="/tmp/slackware-rootfs"
LOG_FILE="/tmp/slackware-docker-build.log"
ROOTFS_TARBALL="slackware-rootfs.tar.gz"
IMAGE_NAME="ghcr.io/rizitis/slackware64-current-ci:slacker-very_mini-testing"
DOCKERHUB_IMAGE="rizitis/slackware-slacker:slacker-very_mini-testing"

echo " Clean up old files..."
rm -rf "$ROOTFS_DIR" "$LOG_FILE" "$ROOTFS_TARBALL" 2>/dev/null || true

echo " Create folders..."
mkdir -p "$ROOTFS_DIR"
mkdir -p /run/lock/pkgtools

# ============================================================================
# MINIMAL md5-bootstrap package set — just enough to (1) boot in Docker and
# (2) let slacker install its FIRST package (gnupg2) verified by md5 over HTTPS.
# After that first install, `slacker update gpg` switches on full GPG checking.
# Plus nano to edit.
#
# Derived from the real linked-dependency graph (depgraph.db), NOT
# guessed. Note from that graph: a naive "install every linked dep" explodes to
# ~267 packages (the whole distro) because Slackware builds every optional
# backend into its libs — e.g. gnupg2 -> openldap -> libiodbc -> gtk+2 -> cups
# -> avahi -> qt5 -> ffmpeg/samba, and openldap -> cyrus-sasl -> mariadb. Those
# are dirmngr's LDAP keyserver / SASL / ODBC paths, which `gpg --verify` never
# touches, so they are deliberately excluded here. libstdc++/libgcc_s come from
# aaa_libraries (that is why the compiler packages are not listed).
#
# Package names only — found anywhere in the tree, anchored on the version digit
# (`-[0-9]*`) so a name is never confused with a longer one (libcap vs
# libcap-ng, pcre2 vs pcre, libidn2 vs libidn).
# ============================================================================
pkgs=(
    # ---- base: boot + a working shell (aaa_glibc-solibs FIRST: libc + ldconfig) ----
    aaa_glibc-solibs   # glibc runtime (libc, libm, ld-linux) + ldconfig
    aaa_libraries      # bundled critical .so (libstdc++, libgcc_s, ...)
    aaa_base           # base filesystem layout + /etc skeleton
    etc                # /etc/profile (sources profile.d/*) + base skeleton
    bash               # the shell (container CMD; pkgtools are bash scripts)
    coreutils          # cat, cp, id, date, df, sha256sum, install, cut, tr ...
    findutils          # find — used by removepkg/installpkg
    gawk               # awk — used by pkgtools
    grep               # used by pkgtools + this script
    sed                # used by pkgtools
    gzip               # gzip + .tgz doinst
    tar                # unpack packages
    xz                 # .txz decompression
    file               # libmagic — needed by nano (and handy in general)
    util-linux         # needed from pkgtools (rev)
    pkgtools           # installpkg / upgradepkg / removepkg — no install without it

    # ---- base libs the tools above load (per the graph) ----
    ncurses            # bash / nano
    readline           # gawk / gnupg2
    zlib               # nano / gnupg2 / gnutls
    bzip2              # gnupg2 / tar (.tbz)
    acl                # coreutils / sed / tar
    attr               # coreutils / sed
    libcap             # coreutils
    gmp                # gawk / coreutils / nettle
    mpfr               # gawk
    pcre2              # grep

    # ---- NO gnupg2 here: this is the md5-bootstrap image. slacker installs the
    #      first package (gnupg2) verified by md5 over HTTPS from the official
    #      mirror; after that, `slacker update gpg` pins the key (TOFU) and every
    #      later package is GPG-verified. gnupg2 + its chain (gnutls, nettle,
    #      libgcrypt, sqlite, icu4c, ...) are pulled by slacker on demand, not
    #      baked into the image. ----
    zstd               # gnutls / xz compression
    lz4
    lzlib

    # ---- editor ----
    nano
    less # needed for slacker show-changelog

)
# NOTE: no ca-certificates / openssl here on purpose. slacker's TLS uses rustls
# with roots bundled INTO the binary (ldd shows only glibc), so it verifies the
# mirror without the system CA store. Nothing else in this image reads it either
# (curl/wget/cargo/go are not installed), so the whole CA/SSL setup is dropped.

echo " Install minimal package set (${#pkgs[@]} packages)..."
for pkg_name in "${pkgs[@]}"; do
    pkg_file=$(find "$SLACKWARE_TREE" -name "$pkg_name-[0-9]*.txz" -type f | sort -V | tail -1)
    if [ -z "$pkg_file" ]; then
        echo " NOT FOUND: $pkg_name  (image may be broken!)"
        continue
    fi
    echo " Installation: $(basename "$pkg_file")"
    installpkg --root "$ROOTFS_DIR" "$pkg_file" >> "$LOG_FILE" 2>&1
done

# ========================
# Install local files that i added in BINS/ folder — slacker goes here
# ========================
BINS_DIR="$(dirname "$0")/BINS"
if [ -d "$BINS_DIR" ]; then
    echo " Install local packages from folder BINS/..."
    for pkg_file in "$BINS_DIR"/*.txz "$BINS_DIR"/*.tgz; do
        [ -f "$pkg_file" ] || continue
        echo " Installation: $(basename "$pkg_file")"
        installpkg --root "$ROOTFS_DIR" "$pkg_file" 2>&1 | tee -a "$LOG_FILE"
    done
else
    echo " Local folder BINS/ NOT FOUND ? SKIP local pkg install... "
fi

# ========================
# Post-install
# ========================

# Copy host version files so slacker's release detection sees this as -current
# (VERSION_CODENAME=current: the release-mismatch guard + revert-pkg guard).
echo " Copy version files from host..."
cp /etc/slackware-version "$ROOTFS_DIR/etc/slackware-version"
cp /etc/os-release "$ROOTFS_DIR/etc/os-release"
echo " slackware-version: $(cat "$ROOTFS_DIR/etc/slackware-version")"
echo " VERSION_CODENAME: $(grep VERSION_CODENAME "$ROOTFS_DIR/etc/os-release")"


# Bootstrap config: this image ships WITHOUT a gpg binary, and gnupg2's own lib
# chain (gnutls, nettle, libgcrypt, sqlite, icu4c, ...) is NOT baked in. So:
#   VERIFY=md5      -> the first `slacker update`/`install` verifies via md5 over
#                      HTTPS (default VERIFY=all would fail: a missing gpg makes
#                      slacker invalidate the repo).
#   RESOLVE_STOCK=yes + STOCK_DB_URL
#                   -> `slacker install gnupg2` pulls gnupg2's stock deps (the
#                      whole crypto chain) from the depgraph.db, md5-verified.
# After that: `slacker update gpg` pins the Slackware key (TOFU) and you may flip
# VERIFY back to all for full signature checking from then on.
echo " Write bootstrap config (VERIFY=md5 + resolve-stock)..."
SLK_CONF="$ROOTFS_DIR/etc/slacker/slacker.conf"
set_conf() {   # set_conf KEY VALUE  — replace the (possibly commented) key, else append
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$SLK_CONF"; then
        sed -i "s|^[[:space:]]*#\?[[:space:]]*${key}=.*|${key}=${val}|" "$SLK_CONF"
    else
        echo "${key}=${val}" >> "$SLK_CONF"
    fi
}
if [ -f "$SLK_CONF" ]; then
    set_conf VERIFY md5
    set_conf RESOLVE_STOCK yes
    set_conf STOCK_DB_URL https://raw.githubusercontent.com/rizitis/Slackware64-Current-sofiles/main
    echo " bootstrap conf set: VERIFY=md5, RESOLVE_STOCK=yes, STOCK_DB_URL=..."
else
    echo " NOTE: $SLK_CONF not found (is slacker in BINS/?) — set VERIFY=md5,"
    echo "       RESOLVE_STOCK=yes and STOCK_DB_URL there yourself."
fi

echo " Update ldconfig..."
chroot "$ROOTFS_DIR" /sbin/ldconfig

# NOTE: the old "Fix slackpkg gpg error" step (wget GPG-KEY + gpg1 --import) was
# slackpkg-specific and used gnupg 1.x. This image uses SLACKER, which manages
# its own GPG keyring (TOFU-pinned under STATE_DIR) via `slacker update gpg`, so
# that manual import is neither needed nor applicable here and has been removed.

echo " Set up .bashrc..."
mkdir -p "$ROOTFS_DIR/root"
echo '. /etc/profile' >> "$ROOTFS_DIR/root/.bashrc"

echo " Basic set up of system..."

mkdir -p "$ROOTFS_DIR"/{dev,proc,sys,etc,home,tmp,usr,var}

echo "nameserver 8.8.8.8"  > "$ROOTFS_DIR/etc/resolv.conf"
echo "nameserver 1.1.1.1" >> "$ROOTFS_DIR/etc/resolv.conf"
echo "slackware" > "$ROOTFS_DIR/etc/hostname"
echo "root:x:0:0:root:/root:/bin/bash" > "$ROOTFS_DIR/etc/passwd"
echo "root::19499:0:::::" > "$ROOTFS_DIR/etc/shadow"
echo "root:x:0:" > "$ROOTFS_DIR/etc/group"

cat > "$ROOTFS_DIR/etc/fstab" <<EOF
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
tmpfs /tmp tmpfs defaults 0 0
EOF

echo "Clean files we dont need..."
# Slackware installs docs/manuals under /usr/doc, /usr/man, /usr/info (NOT
# usr/share/*) — that was ~15MB nobody reads in a CI container. Dropping them
# also drops usr/doc/slacker-*/ (NEWS etc.), which is fine here.
rm -rf "$ROOTFS_DIR/usr/share/locale" \
       "$ROOTFS_DIR/usr/share/i18n" \
       "$ROOTFS_DIR/usr/share/doc" \
       "$ROOTFS_DIR/usr/share/man" \
       "$ROOTFS_DIR/usr/share/info" \
       "$ROOTFS_DIR/usr/include" \
       "$ROOTFS_DIR/usr/doc" \
       "$ROOTFS_DIR/usr/man" \
       "$ROOTFS_DIR/usr/info" \
       2>/dev/null || true

echo " Debug the size of rootfs:"
du -sh "$ROOTFS_DIR"/usr/* 2>/dev/null | sort -rh | head -20
echo "---"
du -sh "$ROOTFS_DIR" 2>/dev/null


echo " Create tarball..."
tar -czf "$ROOTFS_TARBALL" -C "$ROOTFS_DIR" .


echo " Create Dockerfile..."
cat > Dockerfile <<'EOF'
FROM scratch
LABEL maintainer="Ioannis Anagnostakis"
LABEL org.opencontainers.image.description="Minimal bootstrappable Slackware64-current (~54MB pull): pkgtools + slacker with resolve-stock. md5-bootstrap: install gnupg2, then 'slacker update gpg' for full GPG verification."
LABEL org.opencontainers.image.source="https://github.com/rizitis/slackware64-current-ci"
LABEL org.opencontainers.image.url="https://github.com/rizitis/slacker"
LABEL org.opencontainers.image.documentation="https://forge.slackware.nl/rizitis/slacker/wiki/Docker"
LABEL org.opencontainers.image.licenses="Apache-2.0"
ADD slackware-rootfs.tar.gz /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CMD ["/usr/bin/bash"]
EOF
# NOTE: the golang-detection RUN and the CARGO/GO ENVs from the big CI images
# were dropped here on purpose: this mini image ships no go and no cargo, so
# that RUN only produced an empty extra layer. Single ADD layer = smaller,
# cleaner image.

# ========================
# Build Docker image
# ========================
echo " Build Docker image..."
docker build --no-cache -t "$IMAGE_NAME" .

# ========================
# Push (both optional — uncomment what you use)
# ========================
# Docker Hub name for the SAME image (docker.io implied).
# NOTE: needs a one-time `docker login -u <user>` (with sudo if you build with
# sudo — root has its own ~/.docker/config.json!).

echo " Push GHCR..."
#docker push "$IMAGE_NAME"

echo " Push Docker Hub..."
#docker tag "$IMAGE_NAME" "$DOCKERHUB_IMAGE"
#docker push "$DOCKERHUB_IMAGE"

echo " clean up..."
rm -f "$ROOTFS_TARBALL" Dockerfile
rm -rf "$ROOTFS_DIR"

echo " Done! image is ready: $IMAGE_NAME"
