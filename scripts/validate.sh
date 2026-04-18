#!/usr/bin/env bash
# Render all Kustomize overlays (with Helm) and validate with kubeconform.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.31.0}"
export KUBECONFORM="${KUBECONFORM:-kubeconform}"

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "kubeconform not found; install from https://github.com/yannh/kubeconform"
  exit 1
fi

KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-}"
if [[ -z "${KUSTOMIZE_BIN}" ]]; then
  if command -v kustomize >/dev/null 2>&1; then
    KUSTOMIZE_BIN="$(command -v kustomize)"
  elif command -v kubectl >/dev/null 2>&1; then
    KUSTOMIZE_BIN="kubectl kustomize"
  else
    echo "Need kustomize or kubectl"
    exit 1
  fi
fi

build_kustomize() {
  local dir="$1"
  if [[ "$KUSTOMIZE_BIN" == "kubectl kustomize" ]]; then
    kubectl kustomize --enable-helm "$dir"
  else
    kustomize build --enable-helm "$dir"
  fi
}

validate_dir() {
  local dir="$1"
  echo "==> $dir"
  build_kustomize "$dir" | kubeconform \
    -strict \
    -ignore-missing-schemas \
    -kubernetes-version "$KUBERNETES_VERSION" \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
}

shopt -s nullglob
for d in "$ROOT"/infra/*/; do
  [[ -f "${d}kustomization.yaml" ]] && validate_dir "$d"
done
for d in "$ROOT"/apps/*/; do
  [[ -f "${d}kustomization.yaml" ]] && validate_dir "$d"
done

echo "OK"
