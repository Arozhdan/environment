#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/secrets/hermes/hermes-env.enc.yaml"
TMP="$(mktemp)"

cleanup() {
  if [[ -f "$TMP" ]]; then
    shred -u "$TMP" 2>/dev/null || rm -f "$TMP"
  fi
}
trap cleanup EXIT

umask 077

mkdir -p "$ROOT/secrets/hermes"

printf "Telegram bot token: "
IFS= read -rs TELEGRAM_BOT_TOKEN
printf "\nTelegram allowed user ID: "
IFS= read -r TELEGRAM_ALLOWED_USERS
printf "Provider env var [OPENROUTER_API_KEY]: "
IFS= read -r PROVIDER_ENV
PROVIDER_ENV="${PROVIDER_ENV:-OPENROUTER_API_KEY}"
printf "%s value (leave blank to skip): " "$PROVIDER_ENV"
IFS= read -rs PROVIDER_VALUE
printf "\n"

cat > "$TMP" <<EOF
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: hermes-env
  namespace: hermes
spec:
  secretTemplates:
    - name: hermes-env
      stringData:
        TELEGRAM_BOT_TOKEN: "$TELEGRAM_BOT_TOKEN"
        TELEGRAM_ALLOWED_USERS: "$TELEGRAM_ALLOWED_USERS"
        TELEGRAM_REACTIONS: "true"
        GATEWAY_ALLOW_ALL_USERS: "false"
        HERMES_INFERENCE_PROVIDER: "auto"
EOF

if [[ -n "$PROVIDER_VALUE" ]]; then
  cat >> "$TMP" <<EOF
        $PROVIDER_ENV: "$PROVIDER_VALUE"
EOF
fi

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
  sops --encrypt \
    --filename-override "$OUT" \
    --output "$OUT" \
    "$TMP"

printf "Encrypted %s\n" "$OUT"

