#!/usr/bin/env bash
# Окружение курса «Istio для эксплуатации».
# Подключается из ~/.bashrc: source ~/istio-course/scripts/env.sh
# Безопасно запускать повторно: пересчитывает INGRESS_HOST.

export ISTIO_VERSION=1.25.2
export ISTIO_HOME="$HOME/istio-${ISTIO_VERSION}"
export KUBECONFIG_CLUSTER1="$HOME/.kube/config-cluster1"
export KUBECONFIG_CLUSTER2="$HOME/.kube/config-cluster2"
export KUBECONFIG="$KUBECONFIG_CLUSTER1"

# kubectl на нужный кластер: k1 get pods, k2 get nodes
k1() { kubectl --kubeconfig "$KUBECONFIG_CLUSTER1" "$@"; }
k2() { kubectl --kubeconfig "$KUBECONFIG_CLUSTER2" "$@"; }

# istioctl в PATH
case ":$PATH:" in
  *":$ISTIO_HOME/bin:"*) ;;
  *) export PATH="$ISTIO_HOME/bin:$PATH" ;;
esac

# Внешний адрес Ingress Gateway (MetalLB).
# Пока Istio не установлен, значение пустое — это нормально.
INGRESS_HOST=$(kubectl --kubeconfig "$KUBECONFIG_CLUSTER1" -n istio-system \
  get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
export INGRESS_HOST
export INGRESS_PORT=80

# Удобные проверки
alias k=k1
