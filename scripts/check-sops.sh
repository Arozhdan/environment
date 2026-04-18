#!/usr/bin/env bash
# Fail if plaintext secrets are committed under secrets/ and block raw Secret
# manifests elsewhere in the repo (except explicit *.example.yaml files).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bad=0
while IFS= read -r -d '' f; do
  if [[ "$f" == *.enc.yaml ]] || [[ "$f" == *.enc.yml ]]; then
    if ! grep -q '^sops:' "$f" 2>/dev/null; then
      echo "ERROR: $f looks like an encrypted filename but has no 'sops:' stanza."
      bad=1
    fi
  fi
done < <(find secrets -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null || true)

if [[ -d secrets ]]; then
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if [[ "$base" == "kustomization.yaml" ]] || [[ "$base" == "kustomization.yml" ]]; then
      continue
    fi
    if [[ "$f" != *.enc.yaml ]] && [[ "$f" != *.enc.yml ]]; then
      echo "ERROR: Plaintext YAML under secrets/: $f (rename to *.enc.yaml and encrypt with sops)"
      bad=1
    fi
  done < <(find secrets -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name '*.enc.yaml' ! -name '*.enc.yml' -print0 2>/dev/null || true)
fi

while IFS= read -r -d '' f; do
  if grep -Eq '^kind:[[:space:]]*Secret$' "$f" 2>/dev/null; then
    echo "ERROR: Raw Kubernetes Secret manifest outside secrets/: $f"
    echo "       Use a SOPS-encrypted SopsSecret under secrets/<app>/ instead."
    bad=1
  fi
done < <(find . \
  -path './.git' -prune -o \
  -path './secrets' -prune -o \
  -type f \( -name '*.yaml' -o -name '*.yml' \) \
  ! -name '*.example.yaml' ! -name '*.example.yml' \
  -print0 2>/dev/null)

exit "$bad"
