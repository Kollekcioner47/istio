#!/usr/bin/env bash
# Поломки для работы 8.1 «Управляемые инциденты и пост-мортем».
# Лабораторная работа: labs/lab-8.1_incident.txt
# Разбор каждого инцидента — incidents/ключ преподавателя, раздел «8.1».
#
# Использование:
#   bash simulate-8.1.sh --list
#   bash simulate-8.1.sh --apply  --incident N     (N = 1..4)
#   bash simulate-8.1.sh --revert --incident N
#   bash simulate-8.1.sh --revert-all
#
# Скрипт идемпотентен: повторный --apply не ломает стенд сильнее, повторный --revert безопасен.

set -euo pipefail
source "$(dirname "$0")/incident-lib.sh"

SCRIPT="$0"

usage() {
  cat <<'EOF'
simulate-8.1.sh — четыре управляемых инцидента для работы 8.1.

  --list                 список инцидентов с коротким описанием
  --apply  --incident N  включить инцидент N (1..4)
  --revert --incident N  снять инцидент N и вернуть стенд в baseline
  --revert-all           снять все четыре инцидента
  --help                 эта справка

Инциденты:
  1  ca-rotation        пересоздание корневого CA и рассинхрон mTLS
  2  strict-no-sidecar  mTLS STRICT на весь mesh и под без sidecar
  3  oom-istio-proxy    лимит памяти sidecar 32Mi и нагрузка
  4  istiod-down        control plane остановлен

Требование: стенд в baseline (productpage отвечает 200). После работы: --revert-all.
EOF
}

list_incidents() {
  cat <<'EOF'
1  ca-rotation        пересоздание корневого CA и рассинхрон mTLS
2  strict-no-sidecar  mTLS STRICT на весь mesh и под без sidecar
3  oom-istio-proxy    лимит памяти sidecar 32Mi и нагрузка
4  istiod-down        control plane остановлен
EOF
}

# --- Инцидент 1: ротация корневого CA -------------------------------------
apply_1() {
  require_baseline
  local d
  d=$(istiod_deploy)
  [[ -n "$d" ]] || die "не найден deployment istiod в namespace $SYS"
  log "инцидент 1: включаем STRICT, иначе PERMISSIVE маскирует рассинхрон CA"
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
  log "инцидент 1: удаляем секрет корневого CA $SYS/istio-ca-secret"
  k1 delete secret -n "$SYS" istio-ca-secret --ignore-not-found >/dev/null 2>&1 || true
  log "перезапускаем $d, чтобы control plane создал новый CA"
  k1 rollout restart deployment -n "$SYS" "$d" >/dev/null 2>&1 || true
  k1 rollout status deployment -n "$SYS" "$d" --timeout=240s >/dev/null 2>&1 \
    || warn "control plane не стал Ready за 240 с — смотрите события пода istiod"
  log "перезапускаем только productpage: он получит сертификат от нового CA"
  rollout_restart productpage-v1
  log "incident 1 applied: старые поды на сертификатах прежнего CA, productpage — на новом"
  log "дальше: labs/lab-8.1_incident.txt, ШАГ 2"
}

revert_1() {
  log "инцидент 1: перезапускаем все deployment bookinfo, чтобы все взяли текущий CA"
  k1 rollout restart deployment -n "$NS" >/dev/null 2>&1 || true
  k1 rollout status deployment -n "$NS" --timeout=300s >/dev/null 2>&1 \
    || warn "не все deployment bookinfo готовы — проверьте k1 get pods -n $NS"
  k1 delete peerauthentication -n "$SYS" default --ignore-not-found >/dev/null 2>&1 || true
  # ingress gateway тоже держит сертификат старого CA
  k1 rollout restart deployment -n "$SYS" istio-ingressgateway >/dev/null 2>&1 || true
  k1 rollout status deployment/istio-ingressgateway -n "$SYS" --timeout=240s >/dev/null 2>&1 || true
  if ! k1 get secret -n "$SYS" istio-ca-secret >/dev/null 2>&1; then
    warn "секрет istio-ca-secret отсутствует: control plane пересоздаст его при следующем старте"
  fi
  log "incident 1 reverted"
}

# --- Инцидент 2: STRICT и под без sidecar ---------------------------------
apply_2() {
  require_baseline
  log "инцидент 2: включаем mTLS STRICT на весь mesh"
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
  log "создаём legacy-client без sidecar: так выглядит сервис, не подключённый к mesh"
  k1 apply -n "$NS" -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-client
  namespace: bookinfo
  labels:
    app: legacy-client
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-client
  template:
    metadata:
      labels:
        app: legacy-client
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: client
          image: alpine:3.20
          command: ["sleep", "3600"]
EOF
  k1 rollout status deployment -n "$NS" legacy-client --timeout=180s >/dev/null 2>&1 \
    || warn "legacy-client не стал Ready: проверьте k1 get pods -n $NS -l app=legacy-client"
  log "incident 2 applied: STRICT + legacy-client без sidecar"
  log "дальше: labs/lab-8.1_incident.txt, ШАГ 4"
}

revert_2() {
  log "инцидент 2: снимаем STRICT и удаляем legacy-client"
  k1 delete peerauthentication -n "$SYS" default --ignore-not-found >/dev/null 2>&1 || true
  k1 delete deployment -n "$NS" legacy-client --ignore-not-found >/dev/null 2>&1 || true
  log "incident 2 reverted"
}

# --- Инцидент 3: OOM sidecar ---------------------------------------------
apply_3() {
  require_baseline
  log "инцидент 3: ставим productpage лимит памяти sidecar 32Mi"
  k1 patch deployment -n "$NS" productpage-v1 --type=merge \
    -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/proxyMemoryLimit":"32Mi"}}}}}' \
    >/dev/null 2>&1 || true
  rollout_restart productpage-v1
  log "даём нагрузку на productpage 20 секунд"
  local end=$((SECONDS + 20))
  local i
  while ((SECONDS < end)); do
    for i in $(seq 1 8); do
      curl -s -o /dev/null -m 5 "http://${INGRESS_HOST}/productpage" 2>/dev/null &
    done
    wait || true
  done
  if [[ "$(http_code)" != "200" ]]; then
    log "productpage не отвечает 200 — вероятен OOMKilled, это и есть инцидент"
  fi
  log "incident 3 applied"
  log "дальше: labs/lab-8.1_incident.txt, ШАГ 6"
}

revert_3() {
  log "инцидент 3: снимаем аннотацию с productpage и пересоздаём под"
  k1 patch deployment -n "$NS" productpage-v1 --type=json \
    -p '[{"op":"remove","path":"/spec/template/metadata/annotations/sidecar.istio.io~1proxyMemoryLimit"}]' \
    >/dev/null 2>&1 || true
  rollout_restart productpage-v1
  log "incident 3 reverted"
}

# --- Инцидент 4: control plane остановлен ---------------------------------
apply_4() {
  require_baseline
  local d cur
  d=$(istiod_deploy)
  [[ -n "$d" ]] || die "не найден deployment istiod в namespace $SYS"
  cur=$(k1 get deployment -n "$SYS" "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
  save_state "8.1-4" "ISTIOD=$d" "REPLICAS=$cur"
  log "инцидент 4: выключаем control plane ($d, было реплик: $cur)"
  k1 scale deployment -n "$SYS" "$d" --replicas=0 >/dev/null
  k1 wait --for=delete pod -n "$SYS" -l app=istiod --timeout=120s >/dev/null 2>&1 || true
  log "incident 4 applied: новые поды в $NS теперь не создаются"
  log "дальше: labs/lab-8.1_incident.txt, ШАГ 8"
}

revert_4() {
  local d cur
  d=$(load_state "8.1-4" "ISTIOD" "$(istiod_deploy)")
  cur=$(load_state "8.1-4" "REPLICAS" "1")
  [[ -n "$d" ]] || die "не удалось определить deployment istiod для восстановления"
  log "инцидент 4: возвращаем $d число реплик $cur"
  k1 scale deployment -n "$SYS" "$d" --replicas="$cur" >/dev/null
  k1 wait --for=condition=Ready pods -n "$SYS" -l app=istiod --timeout=240s >/dev/null 2>&1 \
    || warn "istiod ещё не Ready: подождите и проверьте k1 get pods -n $SYS"
  drop_state "8.1-4"
  log "incident 4 reverted"
}

# --- Разбор аргументов -----------------------------------------------------
MODE=""
INCIDENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_incidents; exit 0 ;;
    --apply) MODE="apply"; shift ;;
    --revert) MODE="revert"; shift ;;
    --revert-all) MODE="revert-all"; shift ;;
    --incident) INCIDENT="${2:-}"; shift 2 || die "для --incident нужно число 1..4" ;;
    --help|-h) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. $SCRIPT --help)" ;;
  esac
done

[[ -n "$MODE" ]] || { usage_hint "$SCRIPT"; exit 2; }

if [[ "$MODE" == "revert-all" ]]; then
  log "снимаем все четыре инцидента"
  for n in 4 3 2 1; do
    if declare -F "revert_$n" >/dev/null; then
      "revert_$n"
    fi
  done
  log "all incidents reverted"
  exit 0
fi

[[ "$INCIDENT" =~ ^[1-4]$ ]] || die "для $MODE укажите --incident 1..4"
if declare -F "${MODE}_${INCIDENT}" >/dev/null; then
  "${MODE}_${INCIDENT}"
else
  die "нет обработчика ${MODE}_${INCIDENT}"
fi
