#!/usr/bin/env bash
# Набор поломок для итогового кейса (labs/final_case.txt).
# Разбор всех десяти поломок — incidents/ключ преподавателя, раздел «Итоговый кейс».
#
# Использование (запускает преподаватель):
#   bash simulate-final.sh --list
#   bash simulate-final.sh --apply --count 3 --seed 42
#   bash simulate-final.sh --status          (список включённых поломок, только для преподавателя)
#   bash simulate-final.sh --revert
#
# --count  сколько поломок включить (1..10, по заданию 3 или 4)
# --seed   воспроизводимость выбора; по умолчанию берётся текущее время и печатается
# Скрипт идемпотентен: --revert безопасен, даже если поломки не включались.

set -euo pipefail
source "$(dirname "$0")/incident-lib.sh"

SCRIPT="$0"

# Порядок применения: от дешёвых и независимых к тем, что мешают перезапускам.
# istiod-down (индекс 7) всегда применяется последним и снимается первым.
PRIO=(10 20 30 40 50 60 100 70 80 90)
NAMES=(
  ca-rotation
  deny-all-policy
  bad-subset
  fault-delay
  reviews-down
  oom-istio-proxy
  istiod-down
  rate-limit-429
  bad-details-endpoint
  gateway-host-mismatch
)

usage() {
  cat <<'EOF'
simulate-final.sh — десять поломок для итогового кейса.

  --list                       список классов поломок (без причин)
  --apply --count N --seed S   включить N поломок; seed делает выбор воспроизводимым
  --status                     какие поломки включены сейчас (для преподавателя)
  --revert                     снять все включённые поломки
  --help                       эта справка

Поломки:
  1  ca-rotation              пересоздание корневого CA и рассинхрон mTLS
  2  deny-all-policy          AuthorizationPolicy без правил блокирует трафик
  3  bad-subset               маршрут в несуществующий subset
  4  fault-delay              задержка 10 секунд в маршруте к сервису
  5  reviews-down             реплики сервиса reviews выставлены в ноль
  6  oom-istio-proxy          лимит памяти sidecar 32Mi
  7  istiod-down              control plane остановлен
  8  rate-limit-429           локальный rate limit возвращает 429
  9  bad-details-endpoint    мёртвый endpoint в сервисе details
 10  gateway-host-mismatch    Gateway принимает только чужой Host

Стенд должен быть в baseline (productpage отвечает 200).
EOF
}

list_breakages() {
  local i
  for i in $(seq 1 10); do
    printf '%2d  %s\n' "$i" "${NAMES[$((i - 1))]}"
  done
}

# --- 1. Ротация корневого CA ------------------------------------------------
b1_apply() {
  local d
  d=$(istiod_deploy)
  [[ -n "$d" ]] || die "не найден deployment istiod"
  k1 apply -f - >/dev/null <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
  k1 delete secret -n "$SYS" istio-ca-secret --ignore-not-found >/dev/null 2>&1 || true
  k1 rollout restart deployment -n "$SYS" "$d" >/dev/null 2>&1 || true
  k1 rollout status deployment -n "$SYS" "$d" --timeout=240s >/dev/null 2>&1 || true
  rollout_restart productpage-v1
  log "поломка 1 (ca-rotation) включена"
}

b1_revert() {
  k1 rollout restart deployment -n "$NS" >/dev/null 2>&1 || true
  k1 rollout status deployment -n "$NS" --timeout=300s >/dev/null 2>&1 || true
  k1 delete peerauthentication -n "$SYS" default --ignore-not-found >/dev/null 2>&1 || true
  k1 rollout restart deployment -n "$SYS" istio-ingressgateway >/dev/null 2>&1 || true
  k1 rollout status deployment/istio-ingressgateway -n "$SYS" --timeout=240s >/dev/null 2>&1 || true
  log "поломка 1 (ca-rotation) снята"
}

# --- 2. Политика без правил ------------------------------------------------
b2_apply() {
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all-productpage
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: productpage
EOF
  log "поломка 2 (deny-all-policy) включена"
}

b2_revert() {
  k1 delete authorizationpolicy -n "$NS" deny-all-productpage --ignore-not-found \
    >/dev/null 2>&1 || true
  log "поломка 2 (deny-all-policy) снята"
}

# --- 3. Несуществующий subset ---------------------------------------------
b3_apply() {
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
  log "поломка 3 (bad-subset) включена"
}

b3_revert() {
  k1 delete virtualservice -n "$NS" reviews-broken --ignore-not-found >/dev/null 2>&1 || true
  k1 delete destinationrule -n "$NS" reviews-subset-dr --ignore-not-found >/dev/null 2>&1 || true
  log "поломка 3 (bad-subset) снята"
}

# --- 4. Задержка в маршруте -----------------------------------------------
b4_apply() {
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings-fault
  namespace: bookinfo
spec:
  hosts:
    - ratings
  http:
    - fault:
        delay:
          percentage:
            value: 100
          fixedDelay: 10s
      route:
        - destination:
            host: ratings
EOF
  log "поломка 4 (fault-delay) включена"
}

b4_revert() {
  k1 delete virtualservice -n "$NS" ratings-fault --ignore-not-found >/dev/null 2>&1 || true
  log "поломка 4 (fault-delay) снята"
}

# --- 5. Сервис без реплик --------------------------------------------------
b5_apply() {
  local d cur
  local saved=""
  for d in reviews-v1 reviews-v2 reviews-v3; do
    cur=$(k1 get deployment -n "$NS" "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
    saved="$saved $d=$cur"
    k1 scale deployment -n "$NS" "$d" --replicas=0 >/dev/null 2>&1 || true
  done
  save_state "final-b5" "REPLICAS=${saved# }"
  log "поломка 5 (reviews-down) включена"
}

b5_revert() {
  local pair d cur
  local state
  state=$(load_state "final-b5" "REPLICAS" "reviews-v1=1 reviews-v2=1 reviews-v3=1")
  for pair in $state; do
    d="${pair%%=*}"
    cur="${pair##*=}"
    k1 scale deployment -n "$NS" "$d" --replicas="$cur" >/dev/null 2>&1 || true
  done
  wait_bookinfo
  drop_state "final-b5"
  log "поломка 5 (reviews-down) снята"
}

# --- 6. Лимит памяти sidecar ----------------------------------------------
b6_apply() {
  k1 patch deployment -n "$NS" productpage-v1 --type=merge \
    -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/proxyMemoryLimit":"32Mi"}}}}}' \
    >/dev/null 2>&1 || true
  rollout_restart productpage-v1
  local end=$((SECONDS + 15))
  local i
  while ((SECONDS < end)); do
    for i in $(seq 1 8); do
      curl -s -o /dev/null -m 5 "http://${INGRESS_HOST}/productpage" 2>/dev/null &
    done
    wait || true
  done
  log "поломка 6 (oom-istio-proxy) включена"
}

b6_revert() {
  k1 patch deployment -n "$NS" productpage-v1 --type=json \
    -p '[{"op":"remove","path":"/spec/template/metadata/annotations/sidecar.istio.io~1proxyMemoryLimit"}]' \
    >/dev/null 2>&1 || true
  rollout_restart productpage-v1
  log "поломка 6 (oom-istio-proxy) снята"
}

# --- 7. Control plane остановлен -------------------------------------------
b7_apply() {
  local d cur
  d=$(istiod_deploy)
  [[ -n "$d" ]] || die "не найден deployment istiod"
  cur=$(k1 get deployment -n "$SYS" "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
  save_state "final-b7" "ISTIOD=$d" "REPLICAS=$cur"
  k1 scale deployment -n "$SYS" "$d" --replicas=0 >/dev/null
  k1 wait --for=delete pod -n "$SYS" -l app=istiod --timeout=120s >/dev/null 2>&1 || true
  log "поломка 7 (istiod-down) включена"
}

b7_revert() {
  local d cur
  d=$(load_state "final-b7" "ISTIOD" "$(istiod_deploy)")
  cur=$(load_state "final-b7" "REPLICAS" "1")
  [[ -n "$d" ]] || die "не удалось определить deployment istiod"
  k1 scale deployment -n "$SYS" "$d" --replicas="$cur" >/dev/null
  k1 wait --for=condition=Ready pods -n "$SYS" -l app=istiod --timeout=240s >/dev/null 2>&1 || true
  drop_state "final-b7"
  log "поломка 7 (istiod-down) снята"
}

# --- 8. Локальный rate limit ----------------------------------------------
b8_apply() {
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
  log "поломка 8 (rate-limit-429) включена"
}

b8_revert() {
  k1 delete envoyfilter -n "$NS" local-ratelimit-productpage --ignore-not-found \
    >/dev/null 2>&1 || true
  log "поломка 8 (rate-limit-429) снята"
}

# --- 9. Workload без sidecar под STRICT ------------------------------------
b9_apply() {
  log "поломка 9: добавляем в details endpoint, которого нет"
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: details-dead
  namespace: bookinfo
spec:
  address: 10.0.2.99
  labels:
    app: details
    version: v1
  network: network1
  ports:
    http: 9080
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: details-no-retry
  namespace: bookinfo
spec:
  hosts:
    - details
  http:
    - route:
        - destination:
            host: details
      retries:
        attempts: 0
EOF
  log "поломка 9 (bad-details-endpoint) включена"
}

b9_revert() {
  k1 delete virtualservice -n "$NS" details-no-retry --ignore-not-found >/dev/null 2>&1 || true
  k1 delete workloadentry -n "$NS" details-dead --ignore-not-found >/dev/null 2>&1 || true
  log "поломка 9 (bad-details-endpoint) снята"
}

# --- 10. Gateway принимает только чужой Host -------------------------------
b10_apply() {
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - bookinfo.example.com
EOF
  log "поломка 10 (gateway-host-mismatch) включена"
}

b10_revert() {
  k1 apply -f ~/istio-1.25.2/samples/bookinfo/networking/bookinfo-gateway.yaml -n "$NS" \
    >/dev/null 2>&1 || warn "не удалось вернуть bookinfo-gateway из samples"
  log "поломка 10 (gateway-host-mismatch) снята"
}

# --- Выбор поломок ---------------------------------------------------------
pick_breakages() {
  local count="$1"
  local seed="$2"
  RANDOM="$seed"
  local pool=(1 2 3 4 5 6 7 8 9 10)
  local i j tmp
  for ((i = 9; i > 0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp=${pool[$i]}
    pool[$i]=${pool[$j]}
    pool[$j]=$tmp
  done
  local chosen=("${pool[@]:0:count}")
  # сортируем выбранные по приоритету применения
  local out=()
  local p idx
  for p in 10 20 30 40 50 60 70 80 90 100; do
    for idx in "${chosen[@]}"; do
      if [[ "${PRIO[$((idx - 1))]}" == "$p" ]]; then
        out+=("$idx")
      fi
    done
  done
  printf '%s\n' "${out[@]}"
}

# --- Разбор аргументов -----------------------------------------------------
MODE=""
COUNT=""
SEED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_breakages; exit 0 ;;
    --apply) MODE="apply"; shift ;;
    --revert) MODE="revert"; shift ;;
    --status) MODE="status"; shift ;;
    --count) COUNT="${2:-}"; shift 2 || die "для --count нужно число" ;;
    --seed) SEED="${2:-}"; shift 2 || die "для --seed нужно число" ;;
    --help|-h) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. $SCRIPT --help)" ;;
  esac
done

[[ -n "$MODE" ]] || { usage_hint "$SCRIPT"; exit 2; }

if [[ "$MODE" == "status" ]]; then
  applied=$(load_state "final" "APPLIED" "")
  if [[ -z "$applied" ]]; then
    echo "поломки не включались"
    exit 0
  fi
  echo "включены поломки:"
  for n in $applied; do
    printf '%2d  %s\n' "$n" "${NAMES[$((n - 1))]}"
  done
  echo "seed: $(load_state "final" "SEED" "-")"
  exit 0
fi

if [[ "$MODE" == "revert" ]]; then
  applied=$(load_state "final" "APPLIED" "")
  if [[ -z "$applied" ]]; then
    warn "в состоянии нет включённых поломок: снимаем все известные"
    applied="1 2 3 4 5 6 7 8 9 10"
  fi
  log "снимаем поломки: $applied"
  for n in $(echo "$applied" | tr ' ' '\n' | tac); do
    if declare -F "b${n}_revert" >/dev/null; then
      "b${n}_revert"
    fi
  done
  drop_state "final"
  log "all breakages reverted"
  exit 0
fi

# apply
[[ "$COUNT" =~ ^[0-9]+$ ]] || die "укажите --count N (1..10)"
((COUNT >= 1 && COUNT <= 10)) || die "--count должен быть от 1 до 10"
if [[ -z "$SEED" ]]; then
  SEED=$(date +%s)
fi
[[ "$SEED" =~ ^[0-9]+$ ]] || die "--seed должен быть числом"

selected=$(pick_breakages "$COUNT" "$SEED" | tr '\n' ' ')
selected="${selected% }"
require_baseline
log "seed=$SEED, count=$COUNT"
log "применяем поломки: $selected"
for n in $selected; do
  if declare -F "b${n}_apply" >/dev/null; then
    "b${n}_apply"
  else
    die "нет обработчика b${n}_apply"
  fi
done
save_state "final" "SEED=$SEED" "COUNT=$COUNT" "APPLIED=$selected"
log "поломки включены: $COUNT. Список для преподавателя: $SCRIPT --status"
log "стенд для студента: смотрите labs/final_case.txt, ШАГ 2"
