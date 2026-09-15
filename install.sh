#!/bin/sh
# Install the Findoc Monitoring exporter on this host.
#
#     sudo ./install.sh                                     # zero-config, if DNS is set up
#     sudo FINDOC_BACKEND=nats.mumbai.internal:4222 ./install.sh
#     sudo FINDOC_URL=http://packages.internal/findoc ./install.sh
#     sudo FINDOC_VERSION=0.2.0 ./install.sh
#
# Detects the OS, picks the right package, verifies its checksum, installs it, and starts both
# services. Safe to re-run: that is how an upgrade is done.
#
# POSIX sh, not bash. This runs on whatever a minimal trading host happens to have, and RHEL
# minimal images have shipped without bash. No pipefail, no arrays, no [[ ]].
set -eu

DEFAULT_VERSION=0.1.0
# Where release assets live. The install repository, not the platform repository: the packages
# are published for hosts to download, and the platform source is not what a monitored host
# needs. https://github.com/ankittshrmaa/findoc_linux_exporter
GITHUB_REPO=ankittshrmaa/findoc_linux_exporter

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mfindoc install failed: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. preconditions ---------------------------------------------------------------------------

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"

[ "$(uname -s)" = Linux ] || die "this installer is for Linux; got $(uname -s).
     Windows hosts use the findoc_win_exporter .exe instead."

# --- 1. identify the OS -------------------------------------------------------------------------
#
# /etc/os-release is the only thing every modern distro agrees on. ID names the distro and
# ID_LIKE names the family it belongs to, which is what lets one branch cover Rocky, Alma,
# Oracle Linux and anything else built on RHEL without listing them.

[ -r /etc/os-release ] || die "/etc/os-release is missing — cannot identify this distribution."
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_NAME="${PRETTY_NAME:-$OS_ID ${VERSION_ID:-}}"

case " $OS_ID $OS_LIKE " in
*" debian "* | *" ubuntu "*) FAMILY=debian ;;
*" rhel "* | *" fedora "* | *" centos "*) FAMILY=rhel ;;
*)
    # Refuse rather than guess. Installing the wrong package format leaves a host that looks
    # installed and monitors nothing, which is worse than a failed install somebody can see.
    die "unsupported distribution: ID=$OS_ID ID_LIKE=${OS_LIKE:-none}
     Supported: Debian/Ubuntu and RHEL/CentOS/Rocky/AlmaLinux.
     If this host really is one of those, its /etc/os-release is unusual — report it."
    ;;
esac

# --- 2. identify the architecture ----------------------------------------------------------------
#
# Only amd64 is built. An arm64 host must fail HERE, loudly, rather than install an amd64
# package whose agent cannot exec — that failure surfaces as a dead liveness plane on a host
# whose metrics plane is fine, which is the single most misleading state this product has.
MACHINE=$(uname -m)
case "$MACHINE" in
x86_64 | amd64) DEB_ARCH=amd64; RPM_ARCH=x86_64 ;;
*)
    die "unsupported architecture: $MACHINE
     Only x86_64 is built today. Do NOT install the x86_64 package here: node_exporter would
     run and the heartbeat agent would not, leaving a host that reports metrics and whose
     death nobody would notice."
    ;;
esac

VERSION="${FINDOC_VERSION:-}"

say "Findoc Monitoring exporter installer"
info "OS       = Linux"
info "Distro   = $OS_NAME  (family: $FAMILY)"
info "Arch     = $MACHINE -> $DEB_ARCH"

# --- 3. locate the package -----------------------------------------------------------------------

# `fetch` RETURNS a status and never exits.
#
# It used to call `die` when no downloader was present, and one call site fetches an optional
# file with `2>/dev/null` — which swallowed die's message while its `exit 1` still fired. The
# script vanished after printing its header, with no error at all. An installer that exits
# silently is worse than one that fails, because the operator has nothing to act on.
#
# So: failure is a return code, every call site decides what it means, and the missing-downloader
# case is checked once, below, where it can say something useful.
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        return 127
    fi
}

need_downloader() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die \
        "neither curl nor wget is installed, so this host cannot download the package.
     Install one, or copy the package next to this script and re-run — a local package needs
     no network at all."
}

if [ "$FAMILY" = debian ]; then
    pkg_name() { printf 'findoc-linux-exporter_%s_%s.deb' "$1" "$DEB_ARCH"; }
else
    pkg_name() { printf 'findoc-linux-exporter-%s-1.el7.%s.rpm' "$1" "$RPM_ARCH"; }
fi

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT INT TERM

PKG=""
SUMFILE=""

# 3a. a package sitting next to this script, or in the build output directory. This is the
#     `git clone`, build, install case, and it needs no network at all.
for dir in "$HERE" "$HERE/dist" "$HERE/packaging/findoc_linux_exporter/out"; do
    [ -d "$dir" ] || continue
    if [ -n "$VERSION" ]; then
        cand="$dir/$(pkg_name "$VERSION")"
    elif [ "$FAMILY" = debian ]; then
        cand=$(ls "$dir"/findoc-linux-exporter_*.deb 2>/dev/null | sort | tail -1 || true)
    else
        cand=$(ls "$dir"/findoc-linux-exporter-*.rpm 2>/dev/null | sort | tail -1 || true)
    fi
    if [ -n "$cand" ] && [ -f "$cand" ]; then
        PKG="$cand"
        [ -f "$cand.sha256" ] && SUMFILE="$cand.sha256"
        say "Using the package already on this host"
        info "$PKG"
        break
    fi
done

# 3b. an internal mirror. The default for an estate that cannot reach the internet, which is the
#     safe assumption for trading infrastructure.
if [ -z "$PKG" ] && [ -n "${FINDOC_URL:-}" ]; then
    BASE="${FINDOC_URL%/}"
    need_downloader
    if [ -z "$VERSION" ]; then
        # A plain HTTP directory has no index, so "latest" is one file saying what latest is.
        if fetch "$BASE/latest.txt" "$WORK/latest.txt"; then
            VERSION=$(tr -d ' \t\r\n' <"$WORK/latest.txt")
        fi
        [ -n "$VERSION" ] || die "could not read $BASE/latest.txt, so there is no way to tell
     which version is current. Either publish a latest.txt containing a version number, or
     pass FINDOC_VERSION=x.y.z explicitly."
    fi
    NAME=$(pkg_name "$VERSION")
    say "Downloading from $BASE"
    info "$NAME"
    fetch "$BASE/$NAME" "$WORK/$NAME" || die "could not download $BASE/$NAME
     Check that version exists on that server — FINDOC_VERSION is currently '$VERSION'."
    PKG="$WORK/$NAME"
    # Optional: a mirror may not carry the checksum. Its absence is reported in step 4, loudly,
    # rather than treated as a download failure here.
    if fetch "$BASE/$NAME.sha256" "$WORK/$NAME.sha256"; then SUMFILE="$WORK/$NAME.sha256"; fi
fi

# 3c. GitHub Releases, last, because a trading host reaching the public internet is the
#     exception rather than the rule.
if [ -z "$PKG" ]; then
    [ -n "$VERSION" ] || VERSION="$DEFAULT_VERSION"
    NAME=$(pkg_name "$VERSION")
    URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$NAME"
    say "Downloading from GitHub Releases"
    info "$URL"
    need_downloader
    fetch "$URL" "$WORK/$NAME" || die "could not download $URL
     If this host has no internet access, publish the package on an internal server and re-run
     with FINDOC_URL=http://your-server/path, or copy the package next to this script."
    PKG="$WORK/$NAME"
    if fetch "$URL.sha256" "$WORK/$NAME.sha256"; then SUMFILE="$WORK/$NAME.sha256"; fi
fi

[ -f "$PKG" ] || die "no package to install."

# --- 4. verify the checksum ------------------------------------------------------------------------
#
# The build publishes a .sha256 beside every artifact. Skipping this on a downloaded file would
# mean installing whatever answered on that hostname, as root, on 5,000 machines.
if [ -n "$SUMFILE" ] && command -v sha256sum >/dev/null 2>&1; then
    EXPECT=$(awk '{print $1; exit}' "$SUMFILE")
    ACTUAL=$(sha256sum "$PKG" | awk '{print $1}')
    if [ "$EXPECT" != "$ACTUAL" ]; then
        die "checksum mismatch for $(basename "$PKG")
     expected $EXPECT
     got      $ACTUAL
     Do not install this. Either the download was corrupted or it was substituted."
    fi
    info "sha256 verified"
elif [ -n "$SUMFILE" ]; then
    info "sha256sum not available — checksum NOT verified"
else
    # Loud, not silent. A missing checksum file is normal for a locally built package and is a
    # warning sign for a downloaded one, and the operator is the one who knows which this is.
    info "no .sha256 alongside the package — checksum NOT verified"
fi

# --- 5. install -------------------------------------------------------------------------------------
#
# Re-running is the upgrade path: both package managers replace in place, the scriptlets keep
# exporter.env and the host identity, and the services are restarted onto the new binaries.
say "Installing"
if [ "$FAMILY" = debian ]; then
    if ! dpkg -i "$PKG"; then
        # `dpkg -i` does not resolve dependencies. The package needs only `adduser`, which is
        # present on any normal Debian host, but a minimal image may not have it.
        info "resolving dependencies"
        apt-get -y -f install || die "dpkg install failed and apt-get -f could not repair it."
    fi
else
    # `yum install`, not `rpm -i`, so shadow-utils resolves rather than failing on a bare
    # dependency the host happens to lack.
    if command -v dnf >/dev/null 2>&1; then
        dnf -y install "$PKG" || die "dnf install failed."
    else
        yum -y install "$PKG" || die "yum install failed."
    fi
fi

# --- 6. start both planes, but only if there is somewhere to report to ---------------------------
#
# **`enable --now` unconditionally is wrong, and the first version of this script did it.** The
# package deliberately refuses to start without a reachable backend; this script then started the
# services anyway, they retried 127.0.0.1 forever, systemctl reported both `active`, and the
# installer printed "This host is monitored" and exited 0. Every word of that was false.
#
# So the same gate the package uses is applied here: ask the agent, with `env -u` so the probe
# sees what the SERVICE will see rather than the environment this script was run in.
#
# `enable` still happens either way, so a host configured later comes up correctly at boot.
# `.target` is required — systemd resolves a bare name to .service and there is deliberately no
# findoc-exporter.service; see the comment block in findoc-exporter.target.
AGENT=/opt/findoc-exporter/bin/findoc-agent/findoc-agent
BACKEND_OK=no
if env -u FINDOC_BACKEND -u FINDOC_SITE "$AGENT" --show-backend >/dev/null 2>&1; then
    BACKEND_OK=yes
fi

if [ ! -d /run/systemd/system ]; then
    info "systemd is not running here; skipping start"
elif [ "$BACKEND_OK" = yes ]; then
    say "Starting both planes"
    systemctl enable --now findoc-exporter.target >/dev/null 2>&1 || true
else
    say "Enabling for boot, NOT starting"
    info "no backend is reachable — starting now would only retry into nothing"
    systemctl enable findoc-exporter.target >/dev/null 2>&1 || true
fi

# --- 7. report what actually happened -------------------------------------------------------------
#
# Reads back the real state rather than claiming success. An installer that prints "done" while
# the liveness plane is dead is the same class of lie as a green dashboard over a broken pipeline.
echo
say "Result"
info "version   $("$AGENT" --version 2>/dev/null || echo 'unknown')"

if [ ! -d /run/systemd/system ]; then
    echo
    echo "Installed. Start it with: systemctl enable --now findoc-exporter.target"
    exit 0
fi

HB=$(systemctl is-active findoc-exporter-heartbeat 2>/dev/null || true)
MX=$(systemctl is-active findoc-exporter-metrics 2>/dev/null || true)
info "heartbeat $HB"
info "metrics   $MX"

# "monitored" requires BOTH that the units are running AND that the agent has somewhere to
# report to. Units alone are not enough: a heartbeat agent retrying an unreachable address sits
# at `active` indefinitely, and calling that monitored is how a host ends up in nobody's
# inventory while its installer said it was fine.
if [ "$HB" = active ] && [ "$MX" = active ] && [ "$BACKEND_OK" = yes ]; then
    info "backend   $(env -u FINDOC_BACKEND -u FINDOC_SITE "$AGENT" --show-backend 2>/dev/null | head -1 | sed 's/^backend: //')"
    echo
    printf '\033[32m%s\033[0m\n' "Both planes are running. This host is monitored."
    exit 0
fi

echo
if [ "$BACKEND_OK" = no ]; then
    printf '\033[33m%s\033[0m\n' "Installed and enabled for boot, but NOT started: no backend is reachable."
    echo
    env -u FINDOC_BACKEND -u FINDOC_SITE "$AGENT" --show-backend 2>&1 | sed 's/^/    /' || true
    echo
    echo "    Fix one of the above, then: systemctl start findoc-exporter.target"
else
    printf '\033[33m%s\033[0m\n' "Installed, a backend is reachable, but a service is not running:"
    echo "    heartbeat $HB / metrics $MX"
    echo
    echo "    systemctl status findoc-exporter-heartbeat findoc-exporter-metrics"
fi
exit 1
