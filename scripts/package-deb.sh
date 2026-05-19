#!/usr/bin/env bash
# Packages a Flutter Linux build into a .deb (and a .tar.gz alongside).
#
# Usage:
#   scripts/package-deb.sh <version>
#
# Expects `flutter build linux --release` to have already run. Writes
# horizon_<version>_amd64.deb and horizon-<version>-linux-x64.tar.gz to the
# repo root. Designed to run from CI (Ubuntu runner) or any glibc Linux dev
# box with ImageMagick + dpkg-deb available.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

VERSION="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/build/linux/x64/release/bundle"

if [[ ! -d "$BUNDLE" ]]; then
  echo "error: $BUNDLE not found — run 'flutter build linux --release' first" >&2
  exit 65
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

PKG="$STAGE/horizon_${VERSION}_amd64"
mkdir -p \
  "$PKG/DEBIAN" \
  "$PKG/usr/lib/horizon" \
  "$PKG/usr/bin" \
  "$PKG/usr/share/applications" \
  "$PKG/usr/share/metainfo"

# 1. Application bundle goes under /usr/lib/horizon. Keep the binary +
#    its data/lib siblings together; standard Flutter Linux layout.
cp -r "$BUNDLE/." "$PKG/usr/lib/horizon/"
chmod 755 "$PKG/usr/lib/horizon/horizon"

# 2. /usr/bin shim so users can run `horizon` from a terminal.
cat > "$PKG/usr/bin/horizon" <<'SH'
#!/bin/sh
exec /usr/lib/horizon/horizon "$@"
SH
chmod 755 "$PKG/usr/bin/horizon"

# 3. Desktop entry. We point Icon to a single name; the icons themselves
#    get installed into hicolor below.
cat > "$PKG/usr/share/applications/horizon.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Horizon
GenericName=AI Chat Client
Comment=Multi-provider AI chat — Ollama, Claude, OpenAI, Gemini
Categories=Utility;Network;Chat;Development;
Keywords=ai;chat;llm;ollama;claude;openai;gemini;anthropic;
Icon=horizon
Exec=/usr/bin/horizon %U
Terminal=false
StartupNotify=true
StartupWMClass=horizon
DESKTOP

# 4. Icons at standard hicolor sizes, derived from the 1024x1024 master.
MASTER="$ROOT/assets/images/horizon.png"
if [[ -f "$MASTER" ]] && command -v convert >/dev/null 2>&1; then
  for sz in 32 48 64 128 256 512; do
    DEST="$PKG/usr/share/icons/hicolor/${sz}x${sz}/apps"
    mkdir -p "$DEST"
    convert "$MASTER" -resize ${sz}x${sz} "$DEST/horizon.png"
  done
else
  echo "warning: ImageMagick or master icon missing — .deb will have no icons" >&2
fi

# 5. AppStream metadata so GNOME Software / KDE Discover can index us.
cat > "$PKG/usr/share/metainfo/com.miles.horizon.metainfo.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>com.miles.horizon</id>
  <name>Horizon</name>
  <summary>Multi-provider AI chat — Ollama, Claude, OpenAI, Gemini</summary>
  <description>
    <p>
      Horizon is a Flutter chat client that talks to Ollama, Claude, OpenAI, and Gemini from a single app.
      Pick provider and model per conversation, switch mid-thread, and keep your API keys in the OS keystore.
    </p>
    <p>Features:</p>
    <ul>
      <li>Four providers in one client: Ollama (local), Claude, OpenAI, Gemini</li>
      <li>Per-chat provider, model, system prompt, and inference options</li>
      <li>Primary + backup Ollama URL with automatic failover</li>
      <li>API keys stored in the OS keystore via libsecret</li>
      <li>Smooth streaming output, OLED-true-black dark theme</li>
      <li>Image input on vision-capable models</li>
    </ul>
  </description>
  <icon type="stock">horizon</icon>
  <launchable type="desktop-id">horizon.desktop</launchable>
  <developer id="dev.60milesperhour">
    <name>Miles Oldenburger</name>
  </developer>
  <categories>
    <category>Utility</category>
    <category>Network</category>
    <category>Chat</category>
  </categories>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>GPL-3.0-only</project_license>
  <content_rating type="oars-1.1" />
  <url type="homepage">https://github.com/60MilesPerHour/Horizon</url>
  <url type="vcs-browser">https://github.com/60MilesPerHour/Horizon</url>
  <url type="bugtracker">https://github.com/60MilesPerHour/Horizon/issues</url>
</component>
XML

# 6. Debian control file. Depends list = the runtime libraries Flutter
#    Linux apps actually need, plus libsecret (flutter_secure_storage) and
#    libsqlite3 (sqflite_common_ffi).
INSTALLED_SIZE_KB=$(du -sk "$PKG/usr" | awk '{print $1}')
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: horizon
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Installed-Size: ${INSTALLED_SIZE_KB}
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6, libc6, libsqlite3-0, libsecret-1-0
Recommends: gnome-keyring | kwalletmanager
Maintainer: Miles Oldenburger <noreply@60milesperhour.dev>
Homepage: https://github.com/60MilesPerHour/Horizon
Description: Multi-provider AI chat client
 Horizon is a Flutter chat client that talks to Ollama, Claude, OpenAI,
 and Gemini from a single app. Pick provider and model per conversation,
 switch mid-thread, and keep API keys in the OS keystore. Supports
 image input on vision-capable models, per-chat system prompts and
 inference options, and a primary + backup Ollama URL setup for
 private LAN servers behind a VPN.
CONTROL

# 7. Build the .deb.
DEB_OUT="$ROOT/horizon_${VERSION}_amd64.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB_OUT" >/dev/null
echo "wrote: $DEB_OUT"

# 8. Also ship a tarball for non-Debian distros.
TAR_DIR="$STAGE/horizon-${VERSION}-linux-x64"
mkdir -p "$TAR_DIR"
cp -r "$BUNDLE/." "$TAR_DIR/"
cp "$PKG/usr/share/applications/horizon.desktop" "$TAR_DIR/"
cp "$PKG/usr/share/metainfo/com.miles.horizon.metainfo.xml" "$TAR_DIR/" 2>/dev/null || true
[[ -f "$MASTER" ]] && cp "$MASTER" "$TAR_DIR/horizon.png"

TAR_OUT="$ROOT/horizon-${VERSION}-linux-x64.tar.gz"
tar -C "$STAGE" -czf "$TAR_OUT" "horizon-${VERSION}-linux-x64"
echo "wrote: $TAR_OUT"
