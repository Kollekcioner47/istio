# Покрытие требований ТЗ

Матрица: каждый тематический блок `course_programm.md` → модуль теории → лабораторные работы
→ чем именно блок подтверждается на стенде. Документ нужен для сдачи курса заказчику и для
проверки, что при переработке ничего не потерялось.

Основание: `course_programm.md` (требования) и `architecture.md` (стенд и расписание).
Часы — академические, из расписания.

Статусы: **полностью** — есть теория и практика с проверками; **частично** — теория есть,
практика покрывает не весь пункт; **обзор** — только теория, практики нет осознанно.

---

## 1. Тематические блоки

| № | Блок ТЗ | Теория | Практика | Чем подтверждается | Статус |
|---|---|---|---|---|---|
| 1 | Инсталляция и архитектура: профили установки, ревизии, безопасное обновление и rollback без простоя | M1 | 1.1, 1.2 | 1.1: `istioctl install --set profile=demo`, istiod и ingressgateway в `istio-system`, bookinfo, `proxy-status` и `proxy-config`; 1.2: установка ревизии через Helm, метка `istio.io/rev` на namespace, канареечный перевод namespace на новую ревизию, откат, проверка отсутствия простоя | полностью |
| 2 | Observability: мониторинг control plane и data plane, метрики, логи, распределённые трейсы, дашборды и алерты, диагностика деградации | M2 | 2.1, 2.2 | 2.1: аддоны из `~/istio-1.25.2/samples/addons`, метрики istiod и Envoy (PromQL: `istio_requests_total`, метрики control plane), access-логи через `meshConfig.accessLogFile`, дашборды Grafana, граф Kiali; 2.2: `extensionProviders` + `Telemetry`, трейсы в Jaeger, инцидент 503 (subsets с нулём реплик), инцидент задержки через `VirtualService.fault.delay`, замер `curl -w` | частично: **алерты** — теория M2, отдельной практики нет |
| 3 | Управление трафиком: VS/DR, timeouts/retries, xDS и lazy xDS, locality LB, circuit breaking, canary/A-B, traffic mirroring | M3 | 3.1, 3.2, 3.3 (+ 9.2) | 3.1: `DestinationRule` с subsets, `VirtualService` 100 % v1, канарейка 90/10 → 50/50; 3.2: A/B-матчинг по заголовку, timeout и retries, `fault.delay`/`abort`; 3.3: `connectionPool` и `outlierDetection`, locality по меткам зон, mirroring (часть 2), снятие статистики с Envoy admin; xDS/lazy xDS — теория M3 и работа 9.2 (`ENABLE_ENHANCED_RESOURCE_SCOPE` + ресурс `Sidecar`) | полностью |
| 4 | Безопасность: mTLS, политики доступа, контроль исходящего трафика, SPIFFE/SPIRE, внешние секрет-хранилища, stateful-компоненты (TCP, headless) | M4 | 4.1, 4.2, 4.3 (+ 5.3) | 4.1: `PeerAuthentication` PERMISSIVE → STRICT, `AuthorizationPolicy` allow/deny, инцидент deny-all, проверка SPIFFE-id в `proxy-config`; 4.2: SPIRE как внешний CA (`spire-crds` + `spire` из helm-charts-hardened, ClusterSPIFFEID, CSI-драйвер, `IstioOperator` с CSI-шаблоном), проверка SVID; 4.3: Vault PKI и `cacerts` для istiod, Vault Agent Injector, StatefulSet + headless + `ServiceEntry` для TCP; контроль egress — 5.3 | полностью |
| 5 | Istio как API Gateway (Ingress/Egress): маршрутизация, CORS, JWT/OIDC, rate limiting с внешними backend, Lua-фильтры | M5 | 5.1, 5.2, 5.3 | 5.1: `httpbin`, `Gateway` + `VirtualService`, CORS с preflight-запросом, `RequestAuthentication` с jwks, `AuthorizationPolicy` по JWT-claims; 5.2: local rate limit через `EnvoyFilter`, global rate limit с Redis и `envoyproxy/ratelimit` (часть 2), Lua-фильтр; 5.3: egress gateway, `ServiceEntry` + `VirtualService` mesh → egress → внешний сервис, TLS origination, ресурс `Sidecar` | полностью |
| 6 | Multicluster и топологии (primary-remote, primary-primary, east-west gateway); Mesh Expansion; диагностика связности, сертификатов и политик | M6 | 6.1, 6.2 | 6.1: east-west gateway на cluster-1, `istioctl create-remote-secret`, remote-профиль на cluster-2, проверка endpoints и связности между кластерами; 6.2: `WorkloadEntry` + ServiceAccount + Service, `istioctl x workload entry configure`, запуск istio-agent на ВМ 10.0.2.20, `proxy-status` для внешней ВМ; диагностика — в обеих работах | частично: **primary-primary** — только теория M6 (обзорная часть) |
| 7 | Режимы sidecar и ambient: архитектура, сценарии применения, ограничения, сравнение по наблюдаемости и безопасности | M7 | 7.1 | 7.1: CRD Gateway API, установка профиля ambient, метка `istio.io/dataplane-mode`, waypoint и `--enroll-namespace`, `HTTPRoute` вместо `VirtualService`, миграция namespace из sidecar в ambient, ограничения режима, возврат стенда через `reset-istio.sh` | полностью |
| 8 | Системный troubleshooting: чек-листы диагностики, разбор инцидентов, подготовка пост-мортемов | M8 | 8.1, 8.2, final_case | 8.1: четыре управляемых инцидента (CA-ротация, STRICT при поде без sidecar, OOM Envoy при низком limit, недоступный istiod), полная диагностика и пост-мортем; 8.2: три слепых мини-инцидента (неверный subset, рассинхрон mTLS, rate limit 429) — причину студент ищет сам; ключ преподавателя хранится отдельно | полностью |
| 9 | GitOps для управления Istio: ArgoCD Application и ApplicationSet, Git как единый источник истины | M9 | 9.1 | 9.1: установка ArgoCD, локальный git-сервер (`git://10.0.2.5/istio-config.git`), Kustomize overlay, `Application` с включённым selfHeal, проверка drift (ручная правка в кластере и возврат к git), `ApplicationSet` с list-генератором и инструкцией добавить cluster-2 | полностью |
| 10 | Performance tuning: HPA для istiod, resource sizing Envoy, оптимизация производительности, сравнение latency sidecar vs ambient | M9 | 9.2 | 9.2: предусловие metrics-server, HPA для istiod через values Helm, sizing requests/limits Envoy, статистика Envoy admin по имени пода, бенчмарк fortio (mesh vs без mesh), pprof istiod, lazy xDS с ресурсом `Sidecar`, честная методика замера | частично: **latency ambient** — сравнение в теории M7; в 9.2 замер идёт mesh vs без mesh |

---

## 2. Требования к практической части

| Требование `course_programm.md` | Как выполнено | Подтверждение |
|---|---|---|
| «После каждого тематического блока — не менее одной лабораторной работы» | 10 блоков, 21 ЛР; на блок 1–3 ЛР | таблица раздела 1; `architecture.md` §3.1 |
| «Практика на симуляциях реальных инцидентов, поиск причины и восстановление» | 8.1 — причина видна (обучение), 8.2 — причина скрыта (одна), финал — 3–4 скрытых | `incidents/simulate-8.1.sh`, `simulate-8.2.sh`, `simulate-final.sh`; ЛР 8.1, 8.2, final_case |
| «Итог обучения — индивидуальное решение кейса» | итоговый кейс как отдельное занятие 21 (4 ч работы + 2 ч разбора) | `labs/final_case.txt`; `architecture.md` §3.3 |

---

## 3. Распределение часов по блокам

| Блок ТЗ | Модуль | Теория | Практика | ЛР |
|---|---|---|---|---|
| 1. Инсталляция и архитектура | M1 | 2 | 4 | 1.1, 1.2 |
| 2. Observability | M2 | 3 | 3 | 2.1, 2.2 |
| 3. Управление трафиком | M3 | 3 | 3 | 3.1, 3.2, 3.3 |
| 4. Безопасность | M4 | 3 | 3 | 4.1, 4.2, 4.3 |
| 5. API Gateway | M5 | 3 | 3 | 5.1, 5.2, 5.3 |
| 6. Multicluster и Mesh Expansion | M6 | 3 | 3 | 6.1, 6.2 |
| 7. Sidecar и Ambient | M7 | 2 | 2 | 7.1 |
| 8. Troubleshooting | M8 | 2 | 4 | 8.1, 8.2 |
| 9. GitOps | M9 | 2 | 2 | 9.1 |
| 10. Performance | M9 | — | 2 | 9.2 |
| Итоговый кейс | — | — | 6 | final_case |
| **Итого** | | **23** | **37,5** | **21** |

Часы M9 разделены между блоками 9 и 10: в расписании это один день (2 теории + 4 практики).

---

## 4. Что осталось за рамками и почему

| Пункт ТЗ | Что сделано | Почему так |
|---|---|---|
| Алерты (Prometheus/Alertmanager) | теория M2, дашборды и метрики — практика 2.1 | отдельная ось «правила алертов» не влезает в 2.1 без раздувания; диагностика в 2.2 идёт через метрики и трейсы. Если заказчику нужен практический алертинг — добавляется как дополнительное задание 2.1 |
| primary-primary | теория M6, обзор | удваивает объём 6.1 без новой оси; стенд из двух кластеров это позволяет, но практика не даёт нового навыка по сравнению с primary-remote |
| Сравнение latency sidecar vs ambient | теория M7, качественные ограничения — 7.1, количественный замер — 9.2 (mesh vs без mesh) | замер ambient требует отдельного прогона с переустановкой профиля; в 9.2 сравниваются sidecar и без mesh, ambient-цифры даются теорией. `ПРОВЕРИТЬ НА СТЕНДЕ:` при первой сдаче курса — уточнить, воспроизводится ли замер ambient на 2 узлах cluster-1 |

---

## 5. Как поддерживать матрицу

- Блок ТЗ меняется только вместе с `course_programm.md` — этот файл не редактируется.
- Новая ЛР: строка в разделе 1 и часы в разделе 3.
- Если практика по пункту не сделана осознанно — пункт уходит в раздел 4 с причиной.
  Молча «терять» пункты ТЗ нельзя: раздел 4 и есть список согласованных исключений.
- Проверка соответствия — по карте `architecture.md` §3.2 и этой матрице: в `labs/` ровно
  21 файл, у каждого заполнены обязательные разделы.
