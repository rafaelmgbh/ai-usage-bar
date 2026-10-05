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

# Assinatura: usa a identidade local fixa se existir (scripts/create-signing-identity.sh),
# senão ad-hoc. O Keychain não depende mais disso: o app lê os itens pelo
# /usr/bin/security, então o cdhash novo de cada build não reabre o pedido de senha.
SIGN_IDENTITY="${SIGN_IDENTITY:-AiUsageBar Local Signing}"
# Sem --team-identifier: o AMFI mata no exec uma assinatura que declara team id
# sem uma cadeia Apple por trás (exit 137).
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "==> codesign com \"$SIGN_IDENTITY\""
    codesign --force --deep --sign "$SIGN_IDENTITY" "$BUNDLE"
else
    echo "==> codesign ad-hoc (sem identidade local)"
    codesign --force --deep --sign - "$BUNDLE"
fi

echo "==> instalando em ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR}/${BUNDLE}"
cp -R "$BUNDLE" "${INSTALL_DIR}/"

echo
echo "OK. Abra com:  open \"${INSTALL_DIR}/${BUNDLE}\""
