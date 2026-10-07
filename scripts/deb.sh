#!/usr/bin/env bash
# Packages a Linux bundle as the Presence camera kiosk .deb (Raspberry Pi
# OS 64-bit), from packaging/raspberrypi/. `make deb` builds the bundle and
# runs this; it also runs on its own, on any machine with dpkg-deb:
#
#   bash scripts/deb.sh <bundle dir> <version> <output .deb> [<arch>]
#
# <arch> is the Debian architecture (arm64, amd64); by default the bundle's
# (from the ELF header of bundle/presence_app).
#
# Layout:
#   /opt/presence/bundle/            the Flutter bundle (presence_app, lib/, data/)
#   /opt/presence/lib/kiosk-session  the service's command: cage on tty1
#   /opt/presence/lib/kiosk-app      what cage shows: Chromium or the native app
#   /usr/bin/presence                the native app
#   /usr/sbin/presence-kiosk         enable | disable | restart | status
#   /lib/systemd/system/presence-kiosk.service
#   /etc/default/presence            settings (conffile)
#   /etc/pam.d/presence-kiosk        the kiosk's logind session (conffile)
#   /etc/chromium/policies/managed/presence.json  camera and mic allowed for
#                                    Presence's origins (conffile)
#   /usr/share/polkit-1/rules.d/50-presence-kiosk.rules  denies the kiosk
#                                    user power, network and storage actions
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <bundle dir> <version> <output .deb> [<arch>]" >&2
  exit 2
fi
bundle=$1 version=$2 out=$3 arch=${4:-}
src="$(cd "$(dirname "$0")/../packaging/raspberrypi" && pwd)"

if [[ ! -x "$bundle/presence_app" ]]; then
  echo "error: no bundle at $bundle (expected $bundle/presence_app)" >&2
  exit 1
fi
if [[ ! "$version" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]]; then
  echo "error: '$version' isn't a Debian version" >&2
  exit 1
fi
command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is needed" >&2; exit 1; }

if [[ -z "$arch" ]]; then
  # e_machine, bytes 18-19 of the ELF header (little endian).
  case "$(od -An -tx1 -j18 -N2 "$bundle/presence_app" | tr -d ' \n')" in
    b700) arch=arm64 ;;
    3e00) arch=amd64 ;;
    *) echo "error: can't tell the bundle's architecture; pass it" >&2; exit 1 ;;
  esac
fi
case "$arch" in
  arm64 | amd64) ;;
  *) echo "error: unsupported architecture '$arch' (arm64, amd64)" >&2; exit 1 ;;
esac

umask 022
root=$(mktemp -d)
chmod 0755 "$root"
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/opt/presence" "$root/usr/bin"
cp -R "$bundle" "$root/opt/presence/bundle"
# Readable by all, writable only by root.
chmod -R u=rwX,go=rX "$root/opt/presence/bundle"
ln -s /opt/presence/bundle/presence_app "$root/usr/bin/presence"

install -D -m 0755 "$src/kiosk-session" "$root/opt/presence/lib/kiosk-session"
install -D -m 0755 "$src/kiosk-app" "$root/opt/presence/lib/kiosk-app"
install -D -m 0755 "$src/presence-kiosk" "$root/usr/sbin/presence-kiosk"
install -D -m 0644 "$src/presence-kiosk.service" "$root/lib/systemd/system/presence-kiosk.service"
install -D -m 0644 "$src/default" "$root/etc/default/presence"
install -D -m 0644 "$src/pam-presence-kiosk" "$root/etc/pam.d/presence-kiosk"
install -D -m 0644 "$src/chromium-policy.json" "$root/etc/chromium/policies/managed/presence.json"
install -D -m 0644 "$src/polkit-presence-kiosk.rules" "$root/usr/share/polkit-1/rules.d/50-presence-kiosk.rules"

mkdir -p "$root/DEBIAN"
for script in postinst prerm postrm; do
  install -m 0755 "$src/$script" "$root/DEBIAN/$script"
done
(cd "$root" && find etc -type f | sed 's|^|/|' | sort) > "$root/DEBIAN/conffiles"
size=$(du -sk --exclude=DEBIAN "$root" | cut -f1)
sed -e "s/@VERSION@/$version/" -e "s/@ARCH@/$arch/" -e "s/@SIZE@/$size/" \
  "$src/control" > "$root/DEBIAN/control"
chmod 0644 "$root/DEBIAN/control" "$root/DEBIAN/conffiles"

mkdir -p "$(dirname "$out")"
dpkg-deb --root-owner-group -Zxz --build "$root" "$out" >/dev/null
echo "==> deb: $out ($arch, version $version)"
