.PHONY: validate check-sops helm-lint-argocd
validate:
	bash scripts/validate.sh

check-sops:
	bash scripts/check-sops.sh

helm-lint-argocd:
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm repo update
	helm pull argo/argo-cd --version 7.7.22 --untar
	helm lint argo-cd -f bootstrap/argocd/values.yaml
