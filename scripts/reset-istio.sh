#!/usr/bin/env bash
# Возвращает Istio к baseline курса:
#   Helm, revision 1-25, istiod + ingress gateway, bookinfo в mesh, аддоны и трейсинг.
# Используется после работ 4.2, 4.3, 7.1 и при разборе проблем со стендом.
set -euo pipefail

source "$HOME/istio-course/scripts/env.sh"

V=1.25.2
K="--kubeconfig $KUBECONFIG_CLUSTER1"

# Helm >= 3.18 проверяет values.schema.json, а в чарте gateway 1.25.2 он сломан.
SCHEMA_FLAG=""
if helm install --help 2>/dev/null | grep -q -- '--skip-schema-validation'; then
  SCHEMA_FLAG="--skip-schema-validation"
fi

echo "== Убираем следы ambient и Gateway API =="
k1 label namespace bookinfo istio.io/dataplane-mode- istio.io/use-waypoint- \
  --overwrite >/dev/null 2>&1 || true
k1 delete httproute --all -n bookinfo --ignore-not-found >/dev/null 2>&1 || true
k1 delete gateway.gateway.networking.k8s.io --all -n bookinfo \
  --ignore-not-found >/dev/null 2>&1 || true

echo "== Удаляем текущую установку Istio =="
for rel in istiod istio-ingress istio-egress istio-eastwestgateway istio-base; do
  helm $K uninstall "$rel" -n istio-system >/dev/null 2>&1 || true
done
istioctl uninstall --purge -y >/dev/null 2>&1 || true
kubectl $K delete namespace istio-system --ignore-not-found
# ждём фактического удаления namespace, иначе создание ниже упадёт на Terminating
kubectl $K wait --for=delete namespace/istio-system --timeout=180s >/dev/null 2>&1 || true

echo "== Ставим baseline через Helm =="
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl $K create namespace istio-system

helm $K install istio-base istio/base -n istio-system --version "$V" --wait

helm $K install istiod istio/istiod -n istio-system --version "$V" \
  --set revision=1-25 \
  --set meshConfig.accessLogFile=/dev/stdout \
  --set meshConfig.accessLogEncoding=JSON \
  --set meshConfig.enableTracing=true \
  --set meshConfig.extensionProviders[0].name=jaeger \
  --set meshConfig.extensionProviders[0].zipkin.service=zipkin.istio-system.svc.cluster.local \
  --set meshConfig.extensionProviders[0].zipkin.port=9411 --wait

helm $K install istio-ingress istio/gateway -n istio-system --version "$V" \
  $SCHEMA_FLAG --set name=istio-ingressgateway --set revision=1-25 --wait

# В чарте gateway targetPort по умолчанию 80, а bookinfo Gateway слушает 8080.
IDX=$(kubectl $K get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{range .spec.ports[*]}{.name}{"\n"}{end}' | grep -n '^http2$' | cut -d: -f1 || true)
if [ -n "${IDX:-}" ]; then
  kubectl $K patch svc istio-ingressgateway -n istio-system --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/$((IDX-1))/targetPort\",\"value\":8080}]"
fi

echo "== Возвращаем аддоны наблюдаемости =="
for a in prometheus grafana kiali jaeger; do
  k1 apply -f "$HOME/istio-$V/samples/addons/$a.yaml" >/dev/null
done

# аддоны могут долго тянуть образы: baseline не должен падать из-за этого
for i in $(seq 1 30); do
  if k1 wait --for=condition=Available -n istio-system --timeout=20s \
       deployment/prometheus deployment/grafana deployment/kiali deployment/jaeger \
       >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
k1 get pods -n istio-system

k1 apply -f - >/dev/null <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  tracing:
    - providers:
        - name: jaeger
      randomSamplingPercentage: 100.0
EOF

echo "== Возвращаем bookinfo в mesh =="
k1 label namespace bookinfo istio-injection- --overwrite >/dev/null 2>&1 || true
k1 label namespace bookinfo istio.io/rev=1-25 --overwrite
k1 rollout restart deployment -n bookinfo
k1 rollout status deployment -n bookinfo --timeout=300s

# istioctl uninstall --purge удаляет не только istio-system, но и Gateway/VirtualService
# из bookinfo. Без этого приложение после сброса отвечает 404.
k1 apply -f "$HOME/istio-$V/samples/bookinfo/networking/bookinfo-gateway.yaml" -n bookinfo

echo "== Baseline готов =="
k1 get pods -n istio-system
k1 get pods -n bookinfo
echo "INGRESS_HOST=$INGRESS_HOST"
