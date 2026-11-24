#!/usr/bin/env bash
# Поломки для работы 8.2 «Слепые мини-инциденты».
# Лабораторная работа: labs/lab-8.2_incident_blind.txt
# Разбор каждого сценария — incidents/ключ преподавателя, раздел «8.2».
#
# Использование:
#   bash simulate-8.2.sh --list
#   bash simulate-8.2.sh --apply  --scenario A|B|C
#   bash simulate-8.2.sh --revert --scenario A|B|C
#   bash simulate-8.2.sh --revert-all
#
# Скрипт не печатает причину: назначение сценария — самостоятельный поиск.
# Идемпотентен: повторный --apply и повторный --revert безопасны.

set -euo pipefail
source "$(dirname "$0")/incident-lib.sh"

SCRIPT="$0"

usage() {
  cat <<'EOF'
simulate-8.2.sh — три слепых мини-инцидента для работы 8.2.

  --list                    список сценариев (без причин)
  --apply  --scenario A|B|C включить сценарий
  --revert --scenario A|B|C снять сценарий и вернуть baseline
  --revert-all              снять все три сценария
  --help                    эта справка

Симптомы сценариев:
  A  страница открывается, но блока отзывов нет: вызов к reviews не проходит
  B  часть запросов к reviews возвращает 503, часть проходит
  C  часть запросов пользователя получает 429

Требование: стенд в baseline (productpage отвечает 200). После работы: --revert-all.
EOF
}

list_scenarios() {
  cat <<'EOF'
A  страница открывается, но блока отзывов нет: вызов к reviews не проходит
B  часть запросов к reviews возвращает 503, часть проходит
C  часть запросов пользователя получает 429
EOF
}

# --- Сценарий A: маршрут в несуществующий subset ---------------------------
apply_A() {
  require_baseline
  log "сценарий A: применяем изменения для сервиса reviews"
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-subset-dr
  namespace: bookinfo
spec:
  host: reviews
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
    - name: v3
      labels:
        version: v3
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-broken
  namespace: bookinfo
spec:
  hosts:
    - reviews
  http:
    - route:
        - destination:
            host: reviews
            subset: v99
EOF
  sleep 4
  # Проверку делаем из прикладного контейнера mesh-клиента, а не из istio-proxy:
  # трафик самого istio-proxy исключён из iptables и обходит Envoy.
  log "сценарий A включён"
  log "scenario A applied"
  log "дальше: labs/lab-8.2_incident_blind.txt, ШАГ 2"
}

revert_A() {
  log "сценарий A: удаляем объекты, созданные сценарием"
  k1 delete virtualservice -n "$NS" reviews-broken --ignore-not-found >/dev/null 2>&1 || true
  k1 delete destinationrule -n "$NS" reviews-subset-dr --ignore-not-found >/dev/null 2>&1 || true
  log "scenario A reverted"
}

# --- Сценарий B: mTLS STRICT и один под без sidecar ------------------------
apply_B() {
  require_baseline
  log "сценарий B: применяем изменения для сервиса reviews"
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: reviews-dead
  namespace: bookinfo
spec:
  address: 10.0.2.99
  labels:
    app: reviews
    version: v3
  network: network1
  ports:
    http: 9080
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-no-retry
  namespace: bookinfo
spec:
  hosts:
    - reviews
  http:
    - route:
        - destination:
            host: reviews
      # без этого Envoy повторит connect-failure на живой под и 503 не будет виден
      retries:
        attempts: 0
EOF
  sleep 5
  log "сценарий B включён"
  log "scenario B applied"
  log "дальше: labs/lab-8.2_incident_blind.txt, ШАГ 4"
}

revert_B() {
  log "сценарий B: удаляем объекты сценария"
  k1 delete virtualservice -n "$NS" reviews-no-retry --ignore-not-found >/dev/null 2>&1 || true
  k1 delete workloadentry -n "$NS" reviews-dead --ignore-not-found >/dev/null 2>&1 || true
  log "scenario B reverted"
}

# --- Сценарий C: локальный rate limit в Envoy ------------------------------
apply_C() {
  require_baseline
  log "сценарий C: применяем изменения для productpage"
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: local-ratelimit-productpage
  namespace: bookinfo
spec:
  workloadSelector:
    labels:
      app: productpage
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.local_ratelimit
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
            stat_prefix: http_local_rate_limiter
            token_bucket:
              max_tokens: 2
              tokens_per_fill: 2
              fill_interval: 60s
            filter_enabled:
              runtime_key: local_rate_limit_enabled
              default_value:
                numerator: 100
                denominator: HUNDRED
            filter_enforced:
              runtime_key: local_rate_limit_enforced
              default_value:
                numerator: 100
                denominator: HUNDRED
EOF
  sleep 5
  local code limited=0
  local i
  for i in $(seq 1 8); do
    code=$(http_code)
    [[ "$code" == "429" ]] && limited=$((limited + 1))
  done
  if ((limited > 0)); then
    log "сценарий C включён"
  else
    warn "429 не появился: фильтр мог не примениться, см. ключ преподавателя, раздел 8.2-C"
  fi
  log "scenario C applied"
  log "дальше: labs/lab-8.2_incident_blind.txt, ШАГ 6"
}

revert_C() {
  log "сценарий C: удаляем объекты сценария"
  k1 delete envoyfilter -n "$NS" local-ratelimit-productpage --ignore-not-found \
    >/dev/null 2>&1 || true
  log "scenario C reverted"
}

# --- Разбор аргументов -----------------------------------------------------
MODE=""
SCENARIO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_scenarios; exit 0 ;;
    --apply) MODE="apply"; shift ;;
    --revert) MODE="revert"; shift ;;
    --revert-all) MODE="revert-all"; shift ;;
    --scenario) SCENARIO="${2:-}"; shift 2 || die "для --scenario нужно A, B или C" ;;
    --help|-h) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. $SCRIPT --help)" ;;
  esac
done

[[ -n "$MODE" ]] || { usage_hint "$SCRIPT"; exit 2; }

if [[ "$MODE" == "revert-all" ]]; then
  log "снимаем все три сценария"
  for s in A B C; do
    "revert_$s"
  done
  log "all scenarios reverted"
  exit 0
fi

SCENARIO="${SCENARIO^^}"
[[ "$SCENARIO" =~ ^[ABC]$ ]] || die "для $MODE укажите --scenario A, B или C"
if declare -F "${MODE}_${SCENARIO}" >/dev/null; then
  "${MODE}_${SCENARIO}"
else
  die "нет обработчика ${MODE}_${SCENARIO}"
fi
