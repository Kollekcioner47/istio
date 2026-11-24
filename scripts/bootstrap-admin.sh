#!/usr/bin/env bash
# Ставит инструменты курса на чистый admin, где есть только kubeconfig.
# Запуск: bash ~/istio-course/scripts/bootstrap-admin.sh
# Нужны интернет и sudo; повторный запуск безопасен.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Запускайте от engineer, не от root: istioctl ставится в \$HOME." >&2
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  echo "Нужен sudo." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y curl ca-certificates gnupg
fi

echo "== kubectl =="
if command -v kubectl >/dev/null 2>&1; then
  echo "уже установлен: $(kubectl version --client 2>/dev/null | head -1)"
else
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y kubectl
fi

echo "== Helm 3.21 =="
if command -v helm >/dev/null 2>&1; then
  echo "уже установлен: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | DESIRED_VERSION=v3.21.3 bash
fi

echo "== istioctl 1.25.2 =="
ISTIO_HOME="$HOME/istio-1.25.2"
if [ -x "$ISTIO_HOME/bin/istioctl" ]; then
  echo "уже установлен: $("$ISTIO_HOME/bin/istioctl" version --remote=false)"
else
  (cd "$HOME" && curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=1.25.2 sh -)
fi
export PATH="$ISTIO_HOME/bin:$PATH"

echo "== ArgoCD CLI 2.14 =="
if command -v argocd >/dev/null 2>&1; then
  echo "уже установлен: $(argocd version --client --short 2>/dev/null || true)"
else
  curl -sSL -o /tmp/argocd \
    https://github.com/argoproj/argo-cd/releases/download/v2.14.0/argocd-linux-amd64
  sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
  rm -f /tmp/argocd
fi

echo
echo "== Проверка =="
kubectl version --client 2>/dev/null | head -1
helm version --short
istioctl version --remote=false
argocd version --client --short 2>/dev/null || true
kubectl config current-context 2>/dev/null || echo "WARN: kubeconfig не настроен"

echo
echo "Дальше: source ~/istio-course/scripts/env.sh"
