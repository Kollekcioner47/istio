# Архитектура курса «Istio для эксплуатации»

Документ описывает стенд, программное обеспечение, карту занятий и правила, на которых
держится курс. Всё, что делает лабораторная работа, опирается на этот файл: адреса, имена
кластеров, версии и состояния стенда здесь считаются окончательными.

Переработка версии 2: 21 занятие вместо 13, два кластера, внешняя ВМ для Mesh Expansion,
аддоны наблюдаемости ставятся отдельной работой.

---

## 1. Стенд

### 1.1 Девять виртуальных машин

| Роль | Hostname | IP (сеть стенда) | IP (сеть управления) | ОС | vCPU | RAM | Диск |
|---|---|---|---|---|---|---|---|
| Управление | `admin` | 10.0.2.5 | 192.168.56.5 | Ubuntu 26.04 LTS | 2 | 4 GB | 40 GB |
| Control plane cluster-1 | `master1` | 10.0.2.10 | 192.168.56.10 | Ubuntu 26.04 LTS | 2 | 4 GB | 40 GB |
| Control plane cluster-1 | `master2` | 10.0.2.11 | 192.168.56.11 | Ubuntu 26.04 LTS | 2 | 4 GB | 40 GB |
| Control plane cluster-1 | `master3` | 10.0.2.12 | 192.168.56.12 | Ubuntu 26.04 LTS | 2 | 4 GB | 40 GB |
| Worker cluster-1 | `node1` | 10.0.2.13 | 192.168.56.13 | Ubuntu 26.04 LTS | 4 | 8 GB | 80 GB |
| Worker cluster-1 | `node2` | 10.0.2.14 | 192.168.56.14 | Ubuntu 26.04 LTS | 4 | 8 GB | 80 GB |
| Control plane cluster-2 | `master4` | 10.0.2.15 | 192.168.56.15 | Ubuntu 26.04 LTS | 1 | 2 GB | 20 GB |
| Worker cluster-2 | `node3` | 10.0.2.16 | 192.168.56.16 | Ubuntu 26.04 LTS | 2 | 4 GB | 40 GB |
| **Внешняя ВМ (Mesh Expansion)** | `vm-legacy` | **10.0.2.20** | 192.168.56.20 | Ubuntu 26.04 LTS | 1 | 2 GB | 20 GB |

- Пользователь на всех ВМ: `engineer`, пароль `Console47` (учебный, стенд изолирован).
- `vm-legacy` нужна только работам 6.2 и итоговому кейсу: на ней живёт приложение вне
  Kubernetes, которое входит в mesh через istio-agent. В остальное время машина выключена —
  это нормально и на расписание не влияет.
- Суммарно стенд требует около 44 GB оперативной памяти хоста. Если меньше — см. раздел 1.5
  «Урезанный стенд».

### 1.2 Что на какой машине

| Машина | Что на ней работает |
|---|---|
| `admin` | терминал курса: `kubectl`, `istioctl`, `helm`, `argocd`, `git`; здесь лежит репозиторий `~/istio-course`; отсюда запускаются ansible/kubespray, `scripts/env.sh` и все ЛР |
| `master1`–`master3` | control plane cluster-1: etcd, kube-apiserver, kube-scheduler, kube-controller-manager |
| `node1`, `node2` | рабочие узлы cluster-1: bookinfo, httpbin, istiod, ingress/egress gateway, аддоны |
| `master4` | control plane cluster-2 (один узел etcd и apiserver) |
| `node3` | рабочий узел cluster-2: remote-профиль Istio, east-west gateway, тестовое приложение |
| `vm-legacy` | python3 и HTTP-сервис; istio-agent и Envoy ставятся в работе 6.2 |

Приложений на `admin` нет: это машина управления. Все проверки идут либо через команды
`kubectl`/`istioctl`, либо HTTP-запросом на `$INGRESS_HOST`.

### 1.3 Сеть

| Сеть | Подсеть | Назначение |
|---|---|---|
| Сеть стенда (NAT Network `istio-lab`) | 10.0.2.0/24, шлюз 10.0.2.1 | межмашинный трафик, адреса узлов для kubespray, выход в интернет |
| Сеть управления (Host-Only) | 192.168.56.0/24 | доступ с хоста к `admin`, адреса MetalLB |
| MetalLB, cluster-1 | **192.168.56.240–245** | внешние адреса сервисов cluster-1 (`$INGRESS_HOST` = 192.168.56.240) |
| MetalLB, cluster-2 | **192.168.56.246–250** | внешние адреса сервисов cluster-2 |
| Pod CIDR cluster-1 | 10.244.0.0/16 | поды cluster-1 |
| Service CIDR cluster-1 | 10.96.0.0/12 | сервисы cluster-1 |
| Pod CIDR cluster-2 | 10.245.0.0/16 | поды cluster-2 — **не пересекается** с cluster-1 |
| Service CIDR cluster-2 | 10.112.0.0/12 | сервисы cluster-2 — **не пересекается** с cluster-1 |

Правила, которые нельзя нарушать:

- Подсети подов и сервисов двух кластеров не пересекаются. Без этого multicluster в работе 6.1
  не заработает: Istio маршрутизирует напрямую между подами.
- Пул MetalLB разделён между кластерами. Один общий пул на одной L2-сети даёт два спикера,
  отвечающих на один адрес, — сервис «мигает». Диапазоны `.240–.245` и `.246–.250` не пересекаются.
- MetalLB работает в L2-режиме по интерфейсу сети управления, поэтому на всех узлах и на
  `admin` есть второй интерфейс в 192.168.56.0/24, а на хосте этот адаптер существует. Имя
  NAT-сети (`istio-lab`) задаётся при создании; Host-Only адаптер — стандартный для VirtualBox
  (`VirtualBox Host-Only Ethernet Adapter`, см. `setup-guide.md` §3).
- С `admin` к приложениям обращаются по адресу из пула (`$INGRESS_HOST`), а не по DNS-имени
  кластера. `istio-ingressgateway.istio-system` — имя внутри кластера, с `admin` оно
  не резолвится и проверка молча ломается.
- Pod- и service-сети с `admin` напрямую недоступны: только через `$INGRESS_HOST`,
  `kubectl port-forward` или `kubectl exec`.

### 1.4 Два кластера

| | cluster-1 | cluster-2 |
|---|---|---|
| Алиас в курсе | `k1` | `k2` |
| Узлы | master1, master2, master3, node1, node2 (5) | master4, node3 (2) |
| Kubernetes | 1.32+ (проверено 1.36.2) | 1.32+ (проверено 1.36.2) |
| CNI | Calico | Calico |
| MetalLB | пул 192.168.56.240–245 | пул 192.168.56.246–250 |
| metrics-server | да | да |
| Istio | основная установка (все работы) | нужен только в 6.1 (remote-профиль) |
| Роль в курсе | весь курс | multicluster (6.1) и итоговый кейс |

cluster-2 поднимается на первом занятии вместе с cluster-1 и дальше просто существует.
Если Host-Only сеть `192.168.56.0/24` недоступна, пулы переносятся в `10.0.2.240-250`
(setup-guide, раздел 10a); `$INGRESS_HOST` при этом остаётся корректным.
Удалять его до работы 6.1 не нужно: это часть стенда, а не одноразовая песочница.

### 1.5 Урезанный стенд

Если хост не тянет 44 GB памяти, допустимы варианты (описаны в `setup-guide.md`):

1. Убрать `master2` и `master3` — control plane cluster-1 станет одним узлом. Работы
   1.1–5.3 проходят, 6.1 и 7.1 тоже; ревизии control plane (1.2) идут в одном экземпляре.
2. Уменьшить `node2` до 2 vCPU / 4 GB — аддоны наблюдаемости (2.1) будут тяжелее стартовать.
3. Выключить `vm-legacy` до работы 6.2 — экономия 2 GB.

Минимальный работающий стенд: `admin`, `master1`, `node1`, `master4`, `node3`, `vm-legacy`
(6 машин, ~22 GB). В этом случае в 6.1 east-west gateway на cluster-2 ставится на `master4`.

---

## 2. Программное обеспечение

| Компонент | Версия | Где | Назначение |
|---|---|---|---|
| VirtualBox | 7.1+ | хост | гипервизор стенда |
| Ubuntu | 26.04 LTS | все 9 ВМ | ОС |
| Kubernetes | 1.32+ (проверено на 1.36.2) | оба кластера | оркестрация; версия фиксируется в kubespray |
| Kubespray | релиз под 1.32+ (проверено на 1.36.2) | admin | установка кластеров |
| Calico | из kubespray | оба кластера | CNI и сетевые политики |
| containerd | 2.x | узлы кластеров | CRI |
| **Istio** | **1.25.2** | оба кластера | предмет курса; дистрибутив `~/istio-1.25.2` |
| Helm | 3.21+ (проверено 3.21.3; для чарта gateway 1.25.2 нужен `--skip-schema-validation`) | admin | установка Istio (ревизии, 1.2), аддонов, MetalLB, metrics-server |
| istioctl | 1.25.2 | admin | установка профилей, диагностика, ambient/waypoint |
| kubectl | 1.32+ (проверено 1.36.2) | admin | работа с кластерами |
| **MetalLB** | 0.14+ | оба кластера | внешние адреса сервисов на bare-metal |
| **metrics-server** | 0.7+ | оба кластера | `kubectl top`, HPA для istiod (9.2) |
| local-path-provisioner | 0.0.30 | cluster-1 | StorageClass по умолчанию для SPIRE (4.2); без него PVC в Pending |
| ArgoCD | server 2.14, CLI 2.14.x (пин) | cluster-1 + CLI на admin | GitOps (9.1); CLI 3.x несовместим с server 2.14 при удалении приложений |
| SPIRE | 1.11+ | cluster-1 | внешний CA для istiod (4.2) |
| HashiCorp Vault | из работы 4.3 (dev-режим) | cluster-1 | PKI для istiod, секреты (4.3) |
| fortio | из работы 9.2 | cluster-1 | нагрузочный замер (9.2) |
| python3 | 3.x | `vm-legacy` | HTTP-сервис вне Kubernetes (6.2) |
| Ansible | 11+ | admin | kubespray |
| git | 2.x | admin | git daemon для ArgoCD (9.1) |
| Prometheus, Grafana, Kiali, Jaeger | из `~/istio-1.25.2/samples/addons` | cluster-1 | наблюдаемость (2.1, 2.2) |

Версия Istio одна на весь курс и задана в `scripts/env.sh`: `ISTIO_VERSION=1.25.2`.
Аддоны наблюдаемости **не входят** в профиль `demo` — они ставятся отдельной работой 2.1.
До 2.1 метрик, дашбордов и трейсов на стенде нет, и это ожидаемое состояние, а не поломка.

---

## 3. Карта курса

### 3.1 Десять модулей

| № | Модуль | Занятия | Теория, ак. ч | Практика, ак. ч | Новые оси |
|---|---|---|---|---|---|
| 1 | Инсталляция и архитектура | 1.1, 1.2 | 2 | 3 | istioctl, профили, sidecar, ревизии, Helm |
| 2 | Observability | 2.1, 2.2 | 3 | 3 | метрики, access-логи, дашборды, трейсы |
| 3 | Управление трафиком | 3.1, 3.2, 3.3 | 3 | 4,5 | VS/DR, канарейка, A/B, timeout/retry, CB |
| 4 | Безопасность | 4.1, 4.2, 4.3 | 3 | 5,5 | mTLS, AuthorizationPolicy, SPIRE, Vault, stateful |
| 5 | Istio как API Gateway | 5.1, 5.2, 5.3 | 3 | 5 | Gateway, CORS, JWT, rate limit, egress |
| 6 | Multicluster и Mesh Expansion | 6.1, 6.2 | 3 | 3,5 | east-west gateway, remote-профиль, WorkloadEntry |
| 7 | Sidecar и Ambient | 7.1 | 2 | 2 | ambient-профиль, ztunnel, waypoint, HTTPRoute |
| 8 | Troubleshooting | 8.1, 8.2 | 2 | 3,5 | управляемые инциденты, слепые инциденты, пост-мортем |
| 9 | GitOps и Performance | 9.1, 9.2 | 2 | 3,5 | ArgoCD, Kustomize, HPA, бенчмарк, lazy xDS |
| 10 | Итоговый кейс | final_case | — | 4 | самостоятельное решение 3–4 поломок |
| | **Итого** | **21** | **23** | **37,5** | |

### 3.2 Двадцать одно занятие

Сложность — целевая по шкале 1–10, «Δ» — к предыдущему занятию.
Ни один Δ не больше 1: это главное требование переработки.

| № | Файл | Тема | Сложность | Балл | Δ |
|---|---|---|---|---|---|
| 1 | `labs/lab-1.1_install.txt` | Установка Istio, профили, первое приложение | easy | 4 | — |
| 2 | `labs/lab-1.2_revisions.txt` | Ревизии, обновление и откат control plane | medium | 5 | +1 |
| 3 | `labs/lab-2.1_observability.txt` | Аддоны, метрики, access-логи, дашборды | easy | 5 | 0 |
| 4 | `labs/lab-2.2_tracing.txt` | Трейсы и разбор деградации | medium | 6 | +1 |
| 5 | `labs/lab-3.1_traffic.txt` | VS/DR, subsets, канарейка | medium | 6 | 0 |
| 6 | `labs/lab-3.2_resilience.txt` | A/B, timeout, retries, fault injection | medium | 6 | 0 |
| 7 | `labs/lab-3.3_circuit_breaking.txt` | CB, outlier detection, locality, mirroring | medium | 7 | +1 |
| 8 | `labs/lab-4.1_security.txt` | mTLS и AuthorizationPolicy | medium | 6 | −1 |
| 9 | `labs/lab-4.2_spire.txt` | SPIRE как внешний CA (SDS/CSI) | hard | 7 | +1 |
| 10 | `labs/lab-4.3_vault.txt` | Vault: CA для istiod, секреты, stateful | hard | 7 | 0 |
| 11 | `labs/lab-5.1_gateway.txt` | Ingress Gateway, CORS, JWT/OIDC | medium | 6 | −1 |
| 12 | `labs/lab-5.2_ratelimit.txt` | Rate limiting (local/global) и Lua | hard | 7 | +1 |
| 13 | `labs/lab-5.3_egress.txt` | Egress Gateway и контроль исходящего трафика | medium | 7 | 0 |
| 14 | `labs/lab-6.1_multicluster.txt` | Multicluster primary-remote | hard | 8 | +1 |
| 15 | `labs/lab-6.2_mesh_expansion.txt` | Mesh Expansion: ВМ в mesh | hard | 7 | −1 |
| 16 | `labs/lab-7.1_ambient.txt` | Ambient: ztunnel, waypoint, миграция | medium | 7 | 0 |
| 17 | `labs/lab-8.1_incident.txt` | Управляемые инциденты и пост-мортем | medium | 6 | −1 |
| 18 | `labs/lab-8.2_incident_blind.txt` | Слепые мини-инциденты | medium | 7 | +1 |
| 19 | `labs/lab-9.1_gitops.txt` | GitOps: ArgoCD + Kustomize + ApplicationSet | medium | 7 | 0 |
| 20 | `labs/lab-9.2_performance.txt` | Performance: HPA, sizing, бенчмарк, pprof | hard | 8 | +1 |
| 21 | `labs/final_case.txt` | Итоговый кейс: 3–4 поломки | hard | 9 | +1 |

Длительность типового занятия — 90 минут (задаётся в шапке ЛР). Итоговый кейс — 4 часа
работы плюс 2 часа разбора. Вопросы для самопроверки и одно дополнительное задание есть
в каждой ЛР — для аудитории эксплуатации это полезнее, чем плотная выдача.

### 3.3 Расписание: 10 учебных дней, около 60 академических часов

| День | Модуль | Теория | Практика | Занятия |
|---|---|---|---|---|
| 1 | 1. Инсталляция и архитектура | 2 | 3 | 1.1, 1.2 |
| 2 | 2. Observability | 3 | 3 | 2.1, 2.2 |
| 3 | 3. Управление трафиком | 3 | 4,5 | 3.1, 3.2, 3.3 |
| 4 | 4. Безопасность | 3 | 5,5 | 4.1, 4.2, 4.3 |
| 5 | 5. API Gateway | 3 | 5 | 5.1, 5.2, 5.3 |
| 6 | 6. Multicluster и Mesh Expansion | 3 | 3,5 | 6.1, 6.2 |
| 7 | 7. Sidecar и Ambient | 2 | 2 | 7.1 |
| 8 | 8. Troubleshooting | 2 | 3,5 | 8.1, 8.2 |
| 9 | 9. GitOps и Performance | 2 | 3,5 | 9.1, 9.2 |
| 10 | Итоговый кейс | — | 4 | final_case |
| | **Итого** | **23** | **37,5** | **21 занятие** |

Часы практики — это суммарные длительности ЛР из их шапок. Дни 3–5 плотнее остальных
(до 8,5 ч): если группа занимается 6 часов в день, эти модули разносятся на два дня, и курс
занимает 10–11 учебных дней. Разбор итогового кейса (2 ч) идёт сверх указанных часов.

---

## 4. Принципы

1. **Одна новая ось на занятие.** «Часть 2» углубляет ту же ось (устройство, продакшн,
   диагностика), а не добавляет вторую тему. Поэтому 7.1 — про ambient, а не «ambient + GitOps».
2. **Δ ≤ 1 между соседними занятиями.** Тяжёлый шаг (6.1, 9.2, кейс) закрывается «толстой» ЛР
   с двумя частями, а не короткой ЛР и не двумя темами сразу.
3. **Теория ≥ ЛР.** К каждой ЛР в колоде есть команда или манифест ровно в том виде, в каком
   он нужен, и одна схема. Нет команды в колоде — нет её и в ЛР.
4. **Формат ЛР:** метаданные, цели, предусловия, «ПРОВЕРКА
   СТЕНДА», «ТЕОРИЯ ЗА 5 МИНУТ», шаги с «ЗАЧЕМ» и «ВЫ УВИДИТЕ», «ПРОВЕРКА РЕЗУЛЬТАТА»,
   «ЕСЛИ ЧТО-ТО ПОШЛО НЕ ТАК», дополнительное задание, вопросы, «УБОРКА», «ЧТО ДАЛЬШЕ».
5. **Стенд переживает порядок прохождения.** Каждая ЛР оставляет кластер в объявленном
   состоянии. Всё, что меняет control plane (4.2, 4.3, 7.1), заканчивается
   `scripts/reset-istio.sh`.
6. **Всё проверено командами.** Студент не верит тексту на слово: у каждого шага есть
   ожидаемый вывод, у каждой работы — блок «ПРОВЕРКА РЕЗУЛЬТАТА».

---

## 5. Артефакты курса

```
Istio/
├── README.md                  обзор курса, аудитория, стенд, как начать
├── LICENSE                    лицензия CC BY-NC-SA 4.0
├── architecture.md            этот файл: стенд, ПО, карта занятий, конвенции
├── setup-guide.md             сборка стенда с нуля: ВМ, кластеры, MetalLB, инструменты
├── course_programm.md         программа курса (требования ТЗ)
├── coverage.md                матрица «блок ТЗ → теория → практика → чем подтверждается»
│
├── labs/                      21 файл ЛР (имена — в таблице 3.2)
│
├── moduleN_theory.pptx        9 колод: модули 1–9, 12–16 слайдов, схемы, заметки
│
├── scripts/
│   ├── env.sh                 окружение: k1/k2, PATH, ISTIO_VERSION, INGRESS_HOST
│   ├── bootstrap-admin.sh     установка инструментов на чистый admin
│   ├── check-stand.sh         проверка готовности стенда к раздаче
│   ├── reset-istio.sh         возврат Istio к baseline (Helm, ревизия 1-25)
│   ├── reset-apps.sh          чистка прикладных namespace bookinfo/httpbin
│   ├── snapshot.ps1           снапшоты ВМ с хоста (VBoxManage)
│   ├── export-stand.ps1       экспорт девяти ВМ в один OVA
│   └── import-stand.ps1       импорт OVA и настройка сетей
│
└── incidents/
    ├── incident-lib.sh        общие функции симуляторов (baseline, состояние)
    ├── simulate-8.1.sh        4 управляемых инцидента
    ├── simulate-8.2.sh        3 слепых мини-инцидента
    ├── simulate-final.sh      набор из 10 поломок для итогового кейса
    ├── postmortem-template.md шаблон пост-мортема
    └── analysis-template.md   шаблон разбора для слепых инцидентов
```

Репозиторий на `admin` лежит в `~/istio-course`: на этот путь завязаны `env.sh`
и reset-скрипты. Если каталог назван иначе — поправьте пути в скриптах, а не наоборот.

---

## 6. Состояния стенда и процедуры сброса

Стенд живёт в одном из трёх состояний. Всё, что между ними, — временное и должно быть убрано.

| Состояние | Что есть | Как вернуть |
|---|---|---|
| `baseline` | Ubuntu, сеть, оба кластера, MetalLB, metrics-server, инструменты на admin. Istio нет | снапшот `baseline` (`scripts/snapshot.ps1`), пересборка по `setup-guide.md` |
| `k8s-ready` = исходное для ЛР | то же плюс Istio: Helm, ревизия `1-25`, istiod + ingressgateway, bookinfo в mesh | `bash ~/istio-course/scripts/reset-istio.sh` |
| `incident` | стенд намеренно сломан (8.1, 8.2, кейс) | `bash ~/istio-course/incidents/simulate-*.sh --revert`, затем `reset-istio.sh` |

| Скрипт | Что делает | Когда нужен |
|---|---|---|
| `scripts/reset-istio.sh` | снимает текущую установку Istio, ставит baseline через Helm (ревизия `1-25`, access-логи в stdout), возвращает bookinfo в mesh | после 4.2, 4.3, 7.1; после экспериментов с профилями; при «mesh странно себя ведёт» |
| `scripts/reset-apps.sh` | удаляет namespace `bookinfo` и `httpbin`, Istio и аддоны не трогает | после 5.x, при конфликте приложений, перед повторным прохождением |
| `scripts/snapshot.ps1` | снапшоты всех 9 ВМ с хоста: `take`, `list`, `restore` | до курса (`baseline`), после сборки (`k8s-ready`), перед 1.1 (`mesh-ready`) |
| `~/renew-certs.sh` | обновляет сертификаты kubeadm и kubeconfig на admin | перед каждым запуском курса, если стенд стоит дольше 30 дней |

Порядок восстановления после неудачного занятия:

1. `bash ~/istio-course/incidents/simulate-*.sh --revert` — если работали с инцидентами.
2. `bash ~/istio-course/scripts/reset-istio.sh` — если меняли control plane.
3. `bash ~/istio-course/scripts/reset-apps.sh` — если испорчены прикладные namespace.
4. Если не помогло — снапшот `restore mesh-ready` и перечитать `setup-guide.md`, раздел 18.

---

## 7. Конвенции, обязательные для всех ЛР

- Кластеры — только через функции `k1`/`k2` из `scripts/env.sh`. `kubectl` без
  `--kubeconfig` смотрит в cluster-1 (`KUBECONFIG` выставлен в `env.sh`), но явные `k1`/`k2`
  в тексте ЛР обязательны: студент должен видеть, какой кластер он трогает.
- Внешний адрес приложения — `$INGRESS_HOST` (MetalLB). Никаких обращений
  к `istio-ingressgateway.istio-system` с `admin`.
- Namespace приложения — `bookinfo` во всех работах; для gateway-тем — `httpbin`,
  создаётся и удаляется в своей ЛР. Namespace `default` не используется.
- `kubectl exec` — только по имени пода:
  `POD=$(k1 get pod -n bookinfo -l app=ratings -o jsonpath='{.items[0].metadata.name}')`.
- После `kubectl apply` — `kubectl wait` или `rollout status`, затем проверка. «Применилось»
  и «работает» — разные вещи.
- Версии образов фиксированы; внешние URL — только с тегом `1.25.2`.
- Любая ЛР, меняющая CA или профиль (4.2, 4.3, 7.1), заканчивается `reset-istio.sh`
  и проверкой, что baseline вернулся.

---

## 8. Что в курс не входит

| Не разбирается | Почему |
|---|---|
| Топология primary-primary | стенд из двух кластеров это позволяет, но тема удваивает объём 6.1 без новой оси; даётся обзором в теории M6 |
| Управляемые mesh (Anthos, OpenShift SM) | другой продукт, другая эксплуатация |
| Terraform/Ansible для самого Istio | курс про mesh, а не про IaC; GitOps закрыт в 9.1 |
| Написание собственных Envoy-фильтров на C++/WASM | это разработка, а не эксплуатация; `EnvoyFilter` и Lua разбираются в 5.2, WASM — нет |
| Windows-контейнеры и Windows-узлы | стенд на Linux; mesh на Windows — отдельная тема |
| Сертификация Istio (ICA) | курс практический, вопросы сертификации не разбираются |

---

## 9. Как проверить, что стенд соответствует архитектуре

Короткая проверка (подробная — `setup-guide.md`, раздел 17):

```bash
source ~/istio-course/scripts/env.sh
k1 get nodes                 # 5 узлов Ready
k2 get nodes                 # 2 узла Ready
k1 get svc -n kube-system metrics-server   # есть
k1 get ipaddresspool -n metallb-system     # пул 192.168.56.240-245
istioctl version --remote=false            # 1.25.2
echo "$INGRESS_HOST"                       # 192.168.56.240, если Istio установлен
```

Если любая строка не сходится — стенд не соответствует архитектуре, и ЛР пройдёт
не так, как задумано. Это первое, что проверяет преподаватель перед занятием.
