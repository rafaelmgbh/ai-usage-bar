#!/usr/bin/env bash
# Cria uma identidade de code signing LOCAL e estável pro AiUsageBar.
#
# Por quê: assinatura ad-hoc (`codesign -s -`) muda o cdhash a cada build, e a
# autorização do Keychain ("Permitir Sempre") é gravada contra a identidade do
# app. Resultado: todo rebuild invalidava o acesso, o macOS voltava a pedir a
# senha das chaves e — enquanto não autorizado — `SecItemCopyMatching` devolvia
# `errSecItemNotFound`, fazendo o app anunciar "conta não logada" numa conta que
# estava logada.
#
# Com um certificado fixo, o requisito designado do app passa a ser
# `identifier … and certificate leaf = H"…"` em vez do cdhash do build, e a
# autorização sobrevive aos rebuilds.
#
# Roda UMA vez. É interativo: o macOS pede confirmação pra confiar no
# certificado e a senha do login keychain pra liberar a chave privada ao
# codesign.
set -euo pipefail

CN="${SIGN_IDENTITY_CN:-AiUsageBar Local Signing}"
TEAM="${SIGN_IDENTITY_TEAM:-AIUSGBAR01}"   # vai no campo OU do certificado
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
# LibreSSL do sistema: sempre presente e gera um PKCS#12 que o `security import`
# aceita. O OpenSSL 3 do Homebrew exige `-legacy` e falha com senha vazia.
OPENSSL=/usr/bin/openssl

if security find-identity -v -p codesigning | grep -qF "$CN"; then
    echo "Identidade \"$CN\" já existe. Nada a fazer."
    security find-identity -v -p codesigning | grep -F "$CN"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P12_PASS="$("$OPENSSL" rand -hex 16)"   # descartável: só protege o arquivo temporário

echo "==> gerando certificado self-signed (10 anos, Code Signing)"
cat > "$TMP/ext.cnf" <<EOF
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=${CN}/OU=${TEAM}/O=${CN}" \
    -extensions v3_req \
    -config <(cat /etc/ssl/openssl.cnf; echo "[v3_req]"; cat "$TMP/ext.cnf") \
    >/dev/null 2>&1

"$OPENSSL" pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:${P12_PASS}" >/dev/null

echo "==> importando no login keychain (uso liberado pro codesign)"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign >/dev/null

echo "==> confiando no certificado pra assinatura de código (o macOS vai perguntar)"
# Domínio do usuário (sem -d): não precisa de sudo. Sem esse passo o codesign
# não enxerga a identidade — `find-identity` só lista identidades válidas.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Senha do login keychain (pra o codesign usar a chave sem perguntar a cada build):"
read -rs KC_PASS
echo
security set-key-partition-list -S apple-tool:,apple: -s -l "$CN" \
    -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "aviso: partition list não ajustada — o codesign vai pedir autorização a cada build"
unset KC_PASS

echo
echo "==> identidade criada:"
security find-identity -v -p codesigning | grep -F "$CN"
echo
echo "Agora rode ./build.sh — ele assina com essa identidade automaticamente."
echo "Na 1ª execução do app assinado o macOS pede acesso ao Keychain uma vez por"
echo "conta Claude: clique \"Permitir Sempre\". Os rebuilds seguintes não pedem mais."
