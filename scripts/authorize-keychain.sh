#!/usr/bin/env bash
# Autoriza o build ATUAL do AiUsageBar nos itens de Keychain do Claude Code,
# sem diálogo do macOS.
#
# Por quê: o acesso a um item passa por duas portas. A lista de apps confiáveis
# casa pelo requisito designado — com a identidade local (ver
# create-signing-identity.sh) ela é estável entre builds. Já a *partition list*
# é gravada por cdhash, e o cdhash muda a cada `./build.sh`; é ela que faz o
# macOS pedir a senha das chaves de novo. (Um `--team-identifier` deixaria a
# entrada estável, mas o AMFI mata no exec uma assinatura que declara team id
# sem cadeia Apple por trás.)
#
# Este script só ANEXA o cdhash novo às listas existentes — nada é removido, pro
# acesso do próprio Claude Code nunca ser cortado. Pede a senha do login
# keychain uma vez.
set -euo pipefail

APP="${1:-$HOME/Applications/AiUsageBar.app}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
ACCOUNTS_JSON="${HOME}/.config/ai-usage-bar/accounts.json"
BASE_SERVICE="Claude Code-credentials"

[ -d "$APP" ] || { echo "app não encontrado: $APP"; exit 1; }

# Sem pipe pro awk: com `set -o pipefail`, um awk que sai cedo mata o produtor
# com SIGPIPE e o script inteiro morre com 141.
SIGN_INFO="$(codesign -dvvv "$APP" 2>&1 || true)"
CDHASH="$(awk -F= '/^CDHash=/ && !seen {print $2; seen=1}' <<<"$SIGN_INFO")"
[ -n "$CDHASH" ] || { echo "não consegui ler o CDHash de $APP"; exit 1; }
echo "app:    $APP"
echo "cdhash: $CDHASH"

# Services a autorizar: o perfil padrão + um por configDir do accounts.json.
# O sufixo é derivado como o Claude Code faz: sha256(path absoluto)[0:8].
services=("$BASE_SERVICE")
if [ -f "$ACCOUNTS_JSON" ]; then
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        abs="${dir/#\~/$HOME}"
        abs="${abs%/}"
        hash="$(printf '%s' "$abs" | shasum -a 256 | cut -c1-8)"
        services+=("${BASE_SERVICE}-${hash}")
    done < <(/usr/bin/python3 -c '
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for a in cfg.get("claudeAccounts", []):
    d = (a.get("configDir") or "").strip()
    if d:
        print(d)
' "$ACCOUNTS_JSON")
fi

# Lista de partições atual de um item (linha description: do ACL partition_id).
# O dump é caro, então roda uma vez só.
KC_DUMP="$(security dump-keychain -a "$KEYCHAIN" 2>/dev/null || true)"

current_partitions() {
    awk -v svc="$1" '
        $0 ~ "\"svce\"<blob>=\"" svc "\"$" { found = 1; next }
        found && /authorizations \([0-9]+\): partition_id/ { inpart = 1; next }
        found && inpart && /description: / && !done { sub(/^ *description: /, ""); print; done = 1 }
    ' <<<"$KC_DUMP"
}

declare -a to_set=()
for svc in "${services[@]}"; do
    parts="$(current_partitions "$svc")"
    if [ -z "$parts" ]; then
        echo "  – $svc: item não encontrado (conta não logada?), pulando"
        continue
    fi
    if [[ "$parts" == *"cdhash:$CDHASH"* ]]; then
        echo "  ✓ $svc: já autorizado"
        continue
    fi
    new="$(printf '%s, cdhash:%s' "$parts" "$CDHASH" | tr -d ' ')"
    echo "  + $svc"
    echo "      de:  $(printf '%s' "$parts" | tr -d ' ')"
    echo "      pra: $new"
    to_set+=("$svc"$'\t'"$new")
done

[ "${#to_set[@]}" -gt 0 ] || { echo; echo "Nada a fazer."; exit 0; }

echo
read -rp "Aplicar as mudanças acima no login keychain? [s/N] " ok
[[ "$ok" =~ ^[sSyY]$ ]] || { echo "abortado"; exit 1; }

echo "Senha do login keychain:"
read -rs KC_PASS
echo

for entry in "${to_set[@]}"; do
    svc="${entry%%$'\t'*}"
    list="${entry#*$'\t'}"
    security set-generic-password-partition-list \
        -S "$list" -s "$svc" -a "$USER" -k "$KC_PASS" "$KEYCHAIN" >/dev/null
    echo "  ok: $svc"
done
unset KC_PASS

echo
echo "Pronto. Reinicie o app:"
echo "  pkill -f Contents/MacOS/AiUsageBar; open \"$APP\""
