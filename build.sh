#!/usr/bin/env bash
# Compila o executável SPM e empacota num .app de menubar (ad-hoc signed).
# Sem Xcode full — usa só o toolchain dos Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AiUsageBar"
BUNDLE="${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/${APP_NAME}"
[ -x "$BIN" ] || { echo "binário não encontrado em $BIN"; exit 1; }

echo "==> montando ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "$BIN" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"

echo "==> codesign ad-hoc"
codesign --force --deep --sign - "$BUNDLE"

echo "==> instalando em ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR}/${BUNDLE}"
cp -R "$BUNDLE" "${INSTALL_DIR}/"

echo
echo "OK. Abra com:  open \"${INSTALL_DIR}/${BUNDLE}\""
echo "Na 1ª execução o macOS pede acesso ao Keychain — clique \"Sempre Permitir\"."
