#!/usr/bin/env bash
# Общие функции для скриптов инцидентов курса «Istio для эксплуатации».
# Подключается из simulate-8.1.sh, simulate-8.2.sh, simulate-final.sh:
#   source "$(dirname "$0")/incident-lib.sh"
# Скрипты работают на admin и меняют только учебный стенд.

set -euo pipefail

ENV_FILE="$HOME/istio-course/scripts/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ОШИБКА: не найден $ENV_FILE — стенд не подготовлен (см. setup-guide.md)." >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

NS="bookinfo"
SYS="istio-system"
STATE_DIR="$HOME/.cache/istio-incidents"
mkdir -p "$STATE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] ВНИМАНИЕ: $*" >&2; }
die() { echo "[$(date +%H:%M:%S)] ОШИБКА: $*" >&2; exit 1; }

# Имя deployment istiod: без ревизии это istiod, с ревизией — istiod-1-25 и т.п.
istiod_deploy() {
  k1 get deployment -n "$SYS" -l app=istiod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

require_cluster() {
  k1 get nodes >/dev/null 2>&1 || die "kubectl не видит cluster-1: проверьте kubeconfig и source env.sh"
}

http_code() {
  curl -s -o /dev/null -m 10 -w '%{http_code}' "http://${INGRESS_HOST}/productpage" 2>/dev/null || true
}

# Проверка, что стенд в baseline: приложение отвечает 200.
# Поломки накладываются только на здоровый стенд, иначе симптом нечитаем.
require_baseline() {
  require_cluster
  [[ -n "${INGRESS_HOST:-}" ]] || die "INGRESS_HOST пуст: Istio не установлен или MetalLB не выдал IP"
  k1 get namespace "$NS" >/dev/null 2>&1 || die "нет namespace $NS: верните стенд (scripts/reset-istio.sh)"
  local code
  code=$(http_code)
  if [[ "$code" != "200" ]]; then
    die "стенд нездоров: productpage отвечает $code. Сначала: scripts/reset-istio.sh, затем --revert-all"
  fi
  log "baseline в порядке: productpage отвечает 200"
}

# Ожидание готовности приложения после перезапуска подов.
wait_bookinfo() {
  k1 wait --for=condition=Ready pods --all -n "$NS" --timeout=300s >/dev/null 2>&1 || true
}

rollout_restart() {
  local deploy="$1"
  k1 rollout restart deployment -n "$NS" "$deploy" >/dev/null 2>&1 || true
  k1 rollout status deployment -n "$NS" "$deploy" --timeout=240s >/dev/null 2>&1 || true
}

# Состояние между --apply и --revert: простой файл key=value.
save_state() {
  local name="$1"
  shift
  {
    echo "# состояние скрипта инцидентов, $(date -Is)"
    printf '%s\n' "$@"
  } >"$STATE_DIR/$name.env"
}

load_state() {
  local name="$1" key="$2" default="${3:-}"
  local file="$STATE_DIR/$name.env"
  [[ -f "$file" ]] || { echo "$default"; return 0; }
  local value
  value=$(grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- || true)
  echo "${value:-$default}"
}

drop_state() {
  rm -f "$STATE_DIR/$1.env"
}

# Метка namespace bookinfo должна включать инъекцию: после 1.2 это istio.io/rev=1-25.
ensure_injection() {
  local rev
  rev=$(k1 get namespace "$NS" -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null || true)
  if [[ -n "$rev" ]]; then
    k1 label namespace "$NS" "istio.io/rev=$rev" --overwrite >/dev/null 2>&1 || true
  else
    k1 label namespace "$NS" istio-injection=enabled --overwrite >/dev/null 2>&1 || true
  fi
}

pod_of() {
  local app="$1"
  k1 get pod -n "$NS" -l "app=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

usage_hint() {
  echo "Справка: $1 --help" >&2
}
