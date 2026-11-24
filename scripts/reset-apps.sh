#!/usr/bin/env bash
# Удаляет прикладные namespace'ы курса. Istio и аддоны не трогает.
# Используется в работах 5.1-5.3 и при разборе проблем.
set -euo pipefail

source "$HOME/istio-course/scripts/env.sh"

k1 delete namespace bookinfo httpbin --ignore-not-found
k1 get namespace
