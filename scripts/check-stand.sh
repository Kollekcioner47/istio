#!/usr/bin/env bash
# Проверяет, что стенд готов к раздаче слушателям (k8s-ready, без Istio и лабных артефактов).
# Запуск на admin: bash ~/istio-course/scripts/check-stand.sh
set -uo pipefail

source "$HOME/istio-course/scripts/env.sh" 2>/dev/null || true
fail=0
ok()  { echo "[ ok ]  $*"; }
bad() { echo "[fail]  $*"; fail=$((fail + 1)); }
warn(){ echo "[warn]  $*"; }

echo "== Инструменты =="
check_tool() {
  local name="$1"; shift
  if command -v "$name" >/dev/null 2>&1; then
    ok "$name: $("$@" 2>&1 | head -1)"
  else
    bad "нет $name"
  fi
}
check_tool kubectl kubectl version --client
check_tool helm helm version --short
check_tool istioctl istioctl version --remote=false
check_tool argocd argocd version --client --short
check_tool git git --version
check_tool jq jq --version
check_tool ssh ssh -V
[ -x "$HOME/istio-1.25.2/bin/istioctl" ] || bad "нет ~/istio-1.25.2/bin/istioctl"
[ -f "$HOME/.kube/config-cluster1" ] && ok "kubeconfig cluster-1" || bad "нет ~/.kube/config-cluster1"
[ -f "$HOME/.kube/config-cluster2" ] && ok "kubeconfig cluster-2" || bad "нет ~/.kube/config-cluster2"

echo "== Кластеры =="
n1=$(k1 get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
n2=$(k2 get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
[ "$n1" -eq 5 ] && ok "cluster-1: 5 Ready" || bad "cluster-1: Ready $n1 из 5"
[ "$n2" -eq 2 ] && ok "cluster-2: 2 Ready" || bad "cluster-2: Ready $n2 из 2"

echo "== Компоненты стенда =="
k1 get ipaddresspool -n metallb-system >/dev/null 2>&1 && ok "MetalLB pool" || bad "нет MetalLB pool"
k1 get deployment -n kube-system metrics-server >/dev/null 2>&1 && ok "metrics-server" || bad "нет metrics-server"
k1 get sc local-path >/dev/null 2>&1 && ok "StorageClass local-path" || bad "нет StorageClass local-path"
systemctl is-active --quiet git-daemon && ok "git-daemon active" || bad "git-daemon не active"
[ -z "$(git ls-remote git://10.0.2.5/istio-config.git 2>/dev/null)" ] && ok "git-репозиторий пуст" || warn "git-репозиторий не пуст (после 9.1 так и должно быть; для раздачи лучше пустой)"

echo "== Чистота (k8s-ready) =="
k1 get ns istio-system >/dev/null 2>&1 && bad "Istio установлен: для старта с 1.1 нужен k8s-ready" || ok "Istio не установлен"
for ns in bookinfo httpbin argocd spire-server vault; do
  k1 get ns "$ns" >/dev/null 2>&1 && bad "есть namespace $ns (не k8s-ready)" || true
done

echo "== Курс и артефакты =="
labs=$(ls "$HOME"/istio-course/labs/*.txt 2>/dev/null | wc -l)
[ "$labs" -eq 21 ] && ok "в labs 21 файл" || bad "в labs $labs файлов"
grep -q "istio-course/scripts/env.sh" "$HOME/.bashrc" 2>/dev/null && ok "env.sh в .bashrc" || warn "env.sh не подключён в .bashrc"
[ -e "$HOME/istio-course/incidents/teacher-key.md" ] && warn "в курсе есть teacher-key.md — уберите перед раздачей"
[ -e "$HOME/istio-course/_review" ] && warn "в курсе есть _review/ — уберите перед раздачей"
[ -e "$HOME/.dsh" ] && warn "есть ~/.dsh (настройки/ключи DSH) — удалите перед раздачей"
[ -f "$HOME/.bash_history" ] && warn "есть ~/.bash_history — очистите перед раздачей"

echo
if [ "$fail" -eq 0 ]; then
  echo "ИТОГ: PASS — стенд готов к упаковке (с учётом warn выше)."
  exit 0
fi
echo "ИТОГ: FAIL ($fail проверок) — исправьте и повторите."
exit 1
