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

# Assinatura: com identidade local fixa, a autorização do Keychain sobrevive aos
# rebuilds; com ad-hoc, o cdhash muda a cada build e o macOS volta a pedir a
# senha das chaves (ver scripts/create-signing-identity.sh).
SIGN_IDENTITY="${SIGN_IDENTITY:-AiUsageBar Local Signing}"
# Sem --team-identifier: o AMFI mata no exec uma assinatura que declara team id
# sem uma cadeia Apple por trás (exit 137). A partition list do Keychain fica
# então por cdhash — ver scripts/authorize-keychain.sh.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "==> codesign com \"$SIGN_IDENTITY\""
    codesign --force --deep --sign "$SIGN_IDENTITY" "$BUNDLE"
else
    echo "==> codesign ad-hoc (sem identidade local)"
    codesign --force --deep --sign - "$BUNDLE"
    echo "    dica: ./scripts/create-signing-identity.sh cria uma identidade fixa"
    echo "    e evita o macOS pedir a senha do Keychain a cada rebuild."
fi

echo "==> instalando em ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR}/${BUNDLE}"
cp -R "$BUNDLE" "${INSTALL_DIR}/"

echo
echo "OK. Abra com:  open \"${INSTALL_DIR}/${BUNDLE}\""
echo "Na 1ª execução o macOS pede acesso ao Keychain — clique \"Sempre Permitir\"."
