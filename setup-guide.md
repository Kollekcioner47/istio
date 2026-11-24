# Сборка стенда курса «Istio для эксплуатации»

От пустого VirtualBox до стенда, на котором проходит работа 1.1: девять ВМ, два кластера
Kubernetes, MetalLB, metrics-server и инструменты на `admin`. Адреса, версии и имена совпадают
с `architecture.md`. Сборка с нуля — 3–4 часа; если стенд уже собран, идите в разделы 15–17.
**Что должно быть к концу:** `k1` и `k2` отвечают, узлы `Ready`, MetalLB выдаёт адреса
192.168.56.240–250, `kubectl top` работает, `istioctl` 1.25.2 в PATH, `$INGRESS_HOST`
заполняется после установки Istio.

---

## 1. Схема стенда

| Машина | IP стенда | IP управления | vCPU | RAM | Диск | Роль |
|---|---|---|---|---|---|---|
| admin | 10.0.2.5 | 192.168.56.5 | 2 | 4 GB | 40 GB | терминал курса, kubectl, ansible |
| master1 | 10.0.2.10 | 192.168.56.10 | 2 | 4 GB | 40 GB | control plane cluster-1 |
| master2 | 10.0.2.11 | 192.168.56.11 | 2 | 4 GB | 40 GB | control plane cluster-1 |
| master3 | 10.0.2.12 | 192.168.56.12 | 2 | 4 GB | 40 GB | control plane cluster-1 |
| node1 | 10.0.2.13 | 192.168.56.13 | 4 | 8 GB | 80 GB | worker cluster-1 |
| node2 | 10.0.2.14 | 192.168.56.14 | 4 | 8 GB | 80 GB | worker cluster-1 |
| master4 | 10.0.2.15 | 192.168.56.15 | 1 | 2 GB | 20 GB | control plane cluster-2 |
| node3 | 10.0.2.16 | 192.168.56.16 | 2 | 4 GB | 40 GB | worker cluster-2 |
| vm-legacy | 10.0.2.20 | 192.168.56.20 | 1 | 2 GB | 20 GB | Mesh Expansion (6.2) |

Две сети у каждой машины: **`istio-lab`** (NAT Network 10.0.2.0/24, шлюз 10.0.2.1 — трафик
между машинами, адреса узлов, интернет) и **`istio-mgmt`** (Host-Only 192.168.56.0/24 — доступ
с хоста к `admin` и адреса MetalLB).

`istio-lab` — именно **NAT Network**, а не NAT у каждой ВМ: у обычного NAT каждая машина живёт
в своей изолированной 10.0.2.0/24 и не видит соседей, кластер на таком стенде не собирается
(раздел 18, проблема 2). Все девять ВМ одновременно — 44 GB памяти; `vm-legacy` включается
только на 6.2. Урезанный стенд (6 машин, ~22 GB) — `architecture.md` §1.5.

---

## 2. Требования к хосту

Минимум: 24 GB ОЗУ, 120 GB свободного диска, 6 ядер, VirtualBox 7.1, Windows 10/11,
macOS или Linux. Рекомендуется: 48 GB, 250 GB, 10 ядер.

---

## 3. Сеть на хосте

```bash
VBoxManage natnetwork add --netname istio-lab --network 10.0.2.0/24 --enable --dhcp off
VBoxManage list hostonlyifs
VBoxManage hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter" --ip 192.168.56.1 --netmask 255.255.255.0
VBoxManage dhcpserver modify --ifname "VirtualBox Host-Only Ethernet Adapter" --disable
```

DHCP выключен в обеих сетях: адреса задаются статически в ВМ, иначе узел после перезагрузки
сменит адрес и кластер потеряет ноду. Имя Host-Only адаптера сверяйте с `list hostonlyifs`
(на Linux это обычно `vboxnet0`).

Отдельно про `admin`: его `enp0s3` должен быть статическим `10.0.2.5/24` с `dhcp4: false`.
Если установщик оставил DHCP, `admin` может получить `10.0.2.15` — адрес `master4`; тогда
`k2` и `ssh 10.0.2.15` будут ходить не туда. Проверка: `ip -4 addr show enp0s3`.

---

## 4. Создание виртуальных машин

Скрипт ниже — сохраните его как `new-vms.ps1` и запустите в PowerShell от имени
администратора. Он создаёт 9 ВМ с двумя сетевыми картами и подключает установочный ISO.

```powershell
$VBOX  = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$ISO   = "C:\Users\$env:USERNAME\Downloads\ubuntu-26.04-live-server-amd64.iso"
$HOSTONLY = "VirtualBox Host-Only Ethernet Adapter"
$VMDIR = "$env:USERPROFILE\VirtualBox VMs"
$VMS = @(
  @{N="admin"; C=2; R=4096; D=40960},    @{N="master1"; C=2; R=4096; D=40960},
  @{N="master2"; C=2; R=4096; D=40960},  @{N="master3"; C=2; R=4096; D=40960},
  @{N="node1"; C=4; R=8192; D=81920},    @{N="node2"; C=4; R=8192; D=81920},
  @{N="master4"; C=1; R=2048; D=20480},  @{N="node3"; C=2; R=4096; D=40960},
  @{N="vm-legacy"; C=1; R=2048; D=20480}
)
foreach ($vm in $VMS) {
  & $VBOX createvm --name $vm.N --ostype Ubuntu_64 --register
  & $VBOX modifyvm $vm.N --memory $vm.R --cpus $vm.C --vram 16 --audio none --usb off
  & $VBOX modifyvm $vm.N --boot1 dvd --boot2 disk
  & $VBOX modifyvm $vm.N --nic1 natnetwork --nat-network1 istio-lab --nictype1 virtio
  & $VBOX modifyvm $vm.N --nic2 hostonly --hostonlyadapter2 "$HOSTONLY" --nictype2 virtio
  & $VBOX modifyvm $vm.N --nicpromisc2 allow-all
  & $VBOX createmedium disk --filename "$VMDIR\$($vm.N)\$($vm.N).vdi" --size $vm.D --format VDI
  & $VBOX storagectl $vm.N --name SATA --add sata --controller IntelAhci --portcount 2
  & $VBOX storageattach $vm.N --storagectl SATA --port 0 --device 0 --type hdd `
      --medium "$VMDIR\$($vm.N)\$($vm.N).vdi"
  & $VBOX storageattach $vm.N --storagectl SATA --port 1 --device 0 --type dvddrive --medium $ISO
}
```

`--nicpromisc2 allow-all` обязателен: MetalLB в L2 отвечает на ARP виртуального адреса, и без
promiscuous-режима ответы не доходят до хоста — `$INGRESS_HOST` не пингуется.

---

## 5. Ubuntu 26.04 LTS

Все машины — **Ubuntu Server 26.04 LTS** без графики, включая `admin`: работа идёт по SSH,
веб-интерфейсы открываются туннелем (раздел 13).

1. Установите `master1` вручную: English, клавиатура Russian, оба интерфейса без настройки
   (адреса задаст netplan), Storage — Use an entire disk, пользователь `engineer` / `Console47`,
   Install OpenSSH server, разрешить пароли.
2. Перезагрузка и извлечение ISO:
   `VBoxManage storageattach master1 --storagectl SATA --port 1 --device 0 --type dvddrive --medium none`.
3. Настройте сеть, hostname и пользователя (раздел 6), выключите ВМ:
   `VBoxManage controlvm master1 acpipowerbutton`.
4. Клонируйте восемь раз:
   `VBoxManage clonevm master1 --name node1 --basefolder "$VMDIR" --register --mode all`,
   затем смените hostname и адреса (6.1–6.3). Клоны вместо восьми установок — экономия двух часов.

---

## 6. Первичная настройка каждой ВМ

Команды выполняются на самой ВМ; подставьте её имя и адреса из таблицы 1. Разделы 6.4–6.5 —
с `admin`, когда SSH уже работает.

### 6.1 Hostname

```bash
sudo hostnamectl set-hostname master1
```

### 6.2 Сеть: два интерфейса, статические адреса

`/etc/netplan/00-course.yaml` (здесь для `master1`; адреса меняются по машинам):

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: false
      addresses: [10.0.2.10/24]
      routes: [{to: default, via: 10.0.2.1}]
      nameservers: {addresses: [8.8.8.8, 1.1.1.1]}
    enp0s8:
      dhcp4: false
      addresses: [192.168.56.10/24]
```

```bash
sudo chmod 600 /etc/netplan/00-course.yaml && sudo netplan apply
ip -4 addr show enp0s3 && ip -4 addr show enp0s8
```

`ВЫ УВИДИТЕ`: 10.0.2.x на `enp0s3`, 192.168.56.x на `enp0s8`. Другие имена интерфейсов
(`ens33`, `enp0s9`) сверьте по `ip link` и поправьте.

Не оставляйте `/etc/resolv.conf` ссылкой на `systemd-resolved`, если в кластере включён
`nodelocaldns`: получится петля `127.0.0.1 → 169.254.25.10`, CoreDNS уйдёт в `Loop detected`
и CrashLoopBackOff. Проверьте `ls -l /etc/resolv.conf`; nameservers в netplan
(8.8.8.8/1.1.1.1) уже задают нужный вариант.

### 6.3 Имена машин и SSH

Одинаковый `/etc/hosts` на всех девяти машинах:

```bash
sudo tee -a /etc/hosts > /dev/null <<'EOF'

# Стенд курса Istio
10.0.2.5   admin
10.0.2.10  master1
10.0.2.11  master2
10.0.2.12  master3
10.0.2.13  node1
10.0.2.14  node2
10.0.2.15  master4
10.0.2.16  node3
10.0.2.20  vm-legacy
EOF
```

С `admin` — ключ и копирование (пароль `Console47` спросит один раз на ВМ):

```bash
ssh-keygen -t ed25519 -C "engineer@admin" -N ""
for ip in 10.0.2.10 10.0.2.11 10.0.2.12 10.0.2.13 10.0.2.14 10.0.2.15 10.0.2.16 10.0.2.20; do
  ssh-copy-id engineer@$ip
done
ssh master1 hostname
```

Для удобства добавьте в `~/.ssh/config` записи вида
`Host master1` / `HostName 10.0.2.10` / `User engineer` — по одной на каждую машину.

### 6.4 Подготовка узлов к Kubernetes (с `admin`)

```bash
for h in master1 master2 master3 node1 node2 master4 node3; do
  ssh $h "sudo swapoff -a && sudo sed -i '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab"
  ssh $h "printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf"
  ssh $h "sudo modprobe overlay && sudo modprobe br_netfilter"
  ssh $h "printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1\n' | sudo tee /etc/sysctl.d/k8s.conf"
  ssh $h "sudo sysctl --system > /dev/null && sudo apt update && sudo apt -y upgrade"
done
```

### 6.5 `vm-legacy`: приложение на python3

Приложение из 6.2 — простой HTTP-сервер на python3, отдельный стек не нужен:

```bash
ssh vm-legacy "python3 --version && mkdir -p ~/vm-legacy"
```

`ВЫ УВИДИТЕ` Python 3.x. Docker на этой машине не требуется: в 6.2 сервис поднимается
командой `python3 -m http.server 8080`. Если нужно «настоящее» приложение — поставьте Docker
отдельно, но для курса это не нужно.

## 7. Репозиторий и инструменты на `admin`

Если `admin` чистый (есть только kubeconfig), все инструменты ставит
`scripts/bootstrap-admin.sh` — одна команда, нужны интернет и `sudo`. Команды ниже —
то же самое вручную.

```bash
# репозиторий — обязательно в ~/istio-course: на этот путь завязаны env.sh и reset-скрипты
scp -r Istio engineer@192.168.56.5:~/istio-course
sudo apt update && sudo apt install -y curl wget git unzip jq make \
    python3 python3-venv python3-pip bash-completion apt-transport-https ca-certificates
```

```bash
# kubectl 1.32+ (проверено 1.36.2)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubectl
# Helm 3.21
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  | DESIRED_VERSION=v3.21.3 bash
# istioctl 1.25.2 -> ~/istio-1.25.2
cd ~ && curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=1.25.2 sh -
# ArgoCD CLI 2.14
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/v2.14.0/argocd-linux-amd64
sudo install -m 555 /tmp/argocd /usr/local/bin/argocd && rm /tmp/argocd
```

```bash
kubectl version --client --output=yaml | grep gitVersion
helm version --short && ~/istio-1.25.2/bin/istioctl version --remote=false && argocd version --client
```

`ВЫ УВИДИТЕ`: kubectl 1.36.x (1.32+), Helm v3.21.x, istioctl 1.25.2, argocd 2.14.x. В PATH `istioctl`
попадёт через `env.sh` (раздел 9); отсюда же берутся аддоны — `~/istio-1.25.2/samples`.
CLI ArgoCD должен остаться 2.14.x: CLI 3.x с server 2.14 не умеет удалять Application
(это всплывает в работе 9.1).

---

## 8. Два кластера Kubernetes (kubespray)

```bash
python3 -m venv ~/kubespray-venv && source ~/kubespray-venv/bin/activate
git clone --branch release-2.27 https://github.com/kubernetes-sigs/kubespray.git ~/kubespray
cd ~/kubespray && pip install -U -r requirements.txt
echo 'source ~/kubespray-venv/bin/activate' >> ~/.bashrc
cp -r inventory/sample inventory/cluster1 && cp -r inventory/sample inventory/cluster2
```

`ПРОВЕРИТЬ НА СТЕНДЕ:` точный тег kubespray под Kubernetes 1.32 сверяется с `docs/kubernetes.md`; на проверенном стенде — Kubernetes 1.36.2
репозитория на момент сборки; в примере `release-2.27`, другой релиз на остальные шаги не влияет.

### 8.1 cluster-1

`inventory/cluster1/inventory.ini`:

```ini
[all]
master1 ansible_host=10.0.2.10 ip=10.0.2.10
master2 ansible_host=10.0.2.11 ip=10.0.2.11
master3 ansible_host=10.0.2.12 ip=10.0.2.12
node1   ansible_host=10.0.2.13 ip=10.0.2.13
node2   ansible_host=10.0.2.14 ip=10.0.2.14

[kube_control_plane]
master1
master2
master3

[etcd]
master1
master2
master3

[kube_node]
node1
node2

[k8s_cluster:children]
kube_control_plane
kube_node
```

`inventory/cluster1/group_vars/k8s_cluster/k8s-cluster.yml`:

```yaml
cluster_name: cluster1
kube_version: v1.32.0   # проверено на v1.36.2
kube_network_plugin: calico
kube_service_addresses: 10.96.0.0/12
kube_pods_subnet: 10.244.0.0/16
kube_proxy_strict_arp: true
metrics_server_enabled: true
supplementary_addresses_in_ssl_keys: [10.0.2.10]
```

`inventory/cluster1/group_vars/all/all.yml`:

```yaml
ansible_user: engineer
ansible_become: true
```

`kube_proxy_strict_arp: true` нужен MetalLB, `metrics_server_enabled: true` ставит
metrics-server сразу — он нужен работе 9.2 и `kubectl top`.

### 8.2 cluster-2

`inventory/cluster2/inventory.ini` — тот же формат, два узла в `[all]`, они же в
`[kube_control_plane]`/`[etcd]` (master4) и `[kube_node]` (node3):

```ini
[all]
master4 ansible_host=10.0.2.15 ip=10.0.2.15
node3   ansible_host=10.0.2.16 ip=10.0.2.16
```

Отличия `group_vars/k8s_cluster/k8s-cluster.yml` от cluster-1:

| Параметр | cluster-1 | cluster-2 |
|---|---|---|
| `cluster_name` | cluster1 | cluster2 |
| `kube_service_addresses` | 10.96.0.0/12 | 10.112.0.0/12 |
| `kube_pods_subnet` | 10.244.0.0/16 | 10.245.0.0/16 |
| `supplementary_addresses_in_ssl_keys` | [10.0.2.10] | [10.0.2.15] |

Остальное — как в 8.1, плюс тот же `group_vars/all/all.yml`. Подсети не пересекаются — это
требование multicluster в 6.1: Istio маршрутизирует трафик напрямую между подами кластеров.

### 8.2a Маршруты pod-сетей между кластерами (для 6.1)

Calico каждого кластера знает только свои pod-блоки, а Kubespray режет pod-подсеть на
/26-блоки по узлам. Поэтому маршруты ставятся на конкретные блоки удалённого кластера,
а не «на всю /16». Сначала соберите блоки и узлы:

```bash
k1 get blockaffinities.crd.projectcalico.org \
  -o custom-columns=CIDR:.spec.cidr,NODE:.spec.node
k2 get blockaffinities.crd.projectcalico.org \
  -o custom-columns=CIDR:.spec.cidr,NODE:.spec.node
```

Для каждого блока удалённого кластера добавьте на всех узлах локального маршрут через узел,
которому этот блок принадлежит (IP узла в сети `10.0.2.0/24`). Пример с проверенного стенда:
cluster-2 через node3 (`10.0.2.16`) и master4 (`10.0.2.15`):

```bash
# на каждом узле cluster-1
sudo ip route replace 10.233.71.0/26 via 10.0.2.16
sudo ip route replace 10.233.94.192/26 via 10.0.2.15
# на каждом узле cluster-2 — блоки cluster-1 через узел cluster-1
```

Проверка: пинг пода из другого кластера, затем доступ к сервису.
Маршруты не сохраняются после перезагрузки — добавьте в netplan/systemd-unit (раздел 18).
Для mesh-трафика через east-west gateway они не обязательны, но без них не работают прямые
проверки pod-to-pod и часть диагностики в 6.1.

### 8.2b Taint'ы мастер-узлов (учебный стенд)

Kubespray помечает мастер-узлы `node-role.kubernetes.io/control-plane:NoSchedule`.
На стенде с двумя рабочими узлами этого обычно хватает, но при нехватке CPU (например,
`node1` выключен) поды `test-revision` из работы 1.2 останутся `Pending`. На учебном стенде
taint можно снять:

```bash
for n in master1 master2 master3; do
  kubectl --kubeconfig ~/.kube/config-cluster1 taint node "$n" \
    node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
done
kubectl --kubeconfig ~/.kube/config-cluster1 get nodes \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Если оставляете taint'ы — следите, чтобы к работе 1.2 оба рабочих узла были живы.

### 8.3 Установка и проверка

```bash
source ~/kubespray-venv/bin/activate && cd ~/kubespray
ansible all -i inventory/cluster1/inventory.ini -m ping
ansible-playbook -i inventory/cluster1/inventory.ini cluster.yml -b
ansible all -i inventory/cluster2/inventory.ini -m ping
ansible-playbook -i inventory/cluster2/inventory.ini cluster.yml -b
ssh master1 "sudo kubectl get nodes" && ssh master4 "sudo kubectl get nodes"
```

Каждый кластер ставится 20–30 минут, в конце прогона `failed=0`. `ВЫ УВИДИТЕ`: пять узлов
cluster-1 и два узла cluster-2 в статусе `Ready`.

---

## 9. Доступ с `admin` и окружение курса

```bash
mkdir -p ~/.kube
ssh master1 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-cluster1
sed -i 's/127.0.0.1/10.0.2.10/' ~/.kube/config-cluster1
ssh master4 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-cluster2
sed -i 's/127.0.0.1/10.0.2.15/' ~/.kube/config-cluster2
chmod 600 ~/.kube/config-cluster1 ~/.kube/config-cluster2
grep -q 'scripts/env.sh' ~/.bashrc || echo 'source ~/istio-course/scripts/env.sh' >> ~/.bashrc
source ~/.bashrc && k1 get nodes && k2 get nodes && echo "$ISTIO_VERSION $INGRESS_HOST"
```

`ВЫ УВИДИТЕ`: `k1`/`k2` печатают узлы своих кластеров, `ISTIO_VERSION=1.25.2`, `INGRESS_HOST`
пуст — так и должно быть, Istio ещё не установлен.

Два отдельных kubeconfig, а не один слитый: имена контекстов и `cluster.local` у кластеров
совпадают, слияние даёт «случайный» кластер при переключении. `env.sh` даёт `ISTIO_VERSION`,
`ISTIO_HOME`, `KUBECONFIG_CLUSTER1/2`, функции `k1`/`k2`, `istioctl` в PATH и пересчитываемый
`INGRESS_HOST`; все 21 работа рассчитывают ровно на этот набор.

---

## 10. MetalLB на оба кластера

Без MetalLB `istio-ingressgateway` останется в `<pending>`, а `$INGRESS_HOST` — пустым.

```bash
helm repo add metallb https://metallb.github.io/metallb && helm repo update
helm --kubeconfig ~/.kube/config-cluster1 install metallb metallb/metallb \
  --version 0.14.9 -n metallb-system --create-namespace --wait
helm --kubeconfig ~/.kube/config-cluster2 install metallb metallb/metallb \
  --version 0.14.9 -n metallb-system --create-namespace --wait
```

Версия 0.14.9 проверена на стенде: в 0.15/0.16 чарт тянет дополнительные frr-k8s-образы
и чаще упирается в медленный pull. Если pull тормозит — предзагрузите образ `frr:9.1.0`.

`istio-pool.yaml` — пул и L2-анонс (адреса у кластеров разные):

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: istio-pool, namespace: metallb-system}
spec:
  addresses: ["192.168.56.240-192.168.56.245"]   # cluster-2: 192.168.56.246-192.168.56.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: istio-l2, namespace: metallb-system}
spec:
  ipAddressPools: [istio-pool]
  interfaces: [enp0s8]
```

```bash
k1 apply -f istio-pool.yaml
sed 's/\.240-192\.168\.56\.245/.246-192.168.56.250/' istio-pool.yaml | k2 apply -f -
k1 create deployment probe --image=nginx:1.30-alpine
k1 expose deployment probe --type=LoadBalancer --port=80
k1 get svc probe     # EXTERNAL-IP из 192.168.56.240-245
k1 delete deployment probe && k1 delete svc probe
```

Разные пулы обязательны: два MetalLB на одной L2-сети с общим диапазоном отвечают на один
адрес, и сервис недоступен через раз. `interfaces: [enp0s8]` держит анонс на сети управления.
Если `EXTERNAL-IP` в `<pending>` — раздел 18, проблемы 3 и 4.

### 10a. Если сеть 192.168.56.0/24 недоступна

На части стендов Host-Only адаптер `192.168.56.0/24` не поднимается: его нет в VirtualBox
или адрес не пингуется с `admin`. Тогда пул MetalLB переносится в сеть стенда `10.0.2.0/24`,
а анонс — на основной адаптер `enp0s3`. Пул и проверка для cluster-1:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: istio-pool, namespace: metallb-system}
spec:
  addresses: ["10.0.2.240-10.0.2.245"]   # cluster-2: 10.0.2.246-10.0.2.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: istio-l2, namespace: metallb-system}
spec:
  ipAddressPools: [istio-pool]
  interfaces: [enp0s3]
```

```bash
k1 apply -f istio-pool-10.yaml
sed 's/\.240-10\.0\.2\.245/.246-10.0.2.250/' istio-pool-10.yaml | k2 apply -f -
k1 get svc -A --field-selector spec.type=LoadBalancer
```

`$INGRESS_HOST` останется корректным: `env.sh` берёт адрес из сервиса, а не из константы.
Проверка: `curl -s -o /dev/null -w '%{http_code}\n' "http://$INGRESS_HOST/productpage"`
с admin возвращает `200`. Дальше по курсу разницы нет.

---

## 11. metrics-server

Нужен для `kubectl top`, HPA для istiod и работы 9.2. При сборке по 8.1 уже установлен:

```bash
k1 get deployment metrics-server -n kube-system && k1 top nodes
```

`ВЫ УВИДИТЕ` таблицу CPU/memory. Если `error: Metrics API not available` — поставьте вручную:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
helm --kubeconfig ~/.kube/config-cluster1 install metrics-server metrics-server/metrics-server \
  -n kube-system --set 'args[0]=--kubelet-insecure-tls' --wait
```

`--kubelet-insecure-tls` нужен из-за самоподписанного сертификата kubelet: для учебного стенда
нормально, для продакшена — нет.

---

## 11a. StorageClass для SPIRE (работа 4.2)

Чарт SPIRE по умолчанию создаёт PVC. Если в кластере нет StorageClass по умолчанию,
`spire-server-0` навсегда останется в Pending, а `helm install --wait` упадёт по таймауту.
Поставьте local-path-provisioner и сделайте его классом по умолчанию:

```bash
kubectl --kubeconfig ~/.kube/config-cluster1 apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl --kubeconfig ~/.kube/config-cluster1 patch sc local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
k1 get sc
```

`ВЫ УВИДИТЕ` `local-path (default)`. Альтернатива без StorageClass — в работе 4.2
`--set spire-server.persistence.type=emptyDir` (данные SPIRE теряются при рестарте пода).

---

## 12. git daemon для работы 9.1

ArgoCD забирает конфигурацию из git; чтобы не зависеть от GitHub, поднимаем свой git daemon.

```bash
sudo mkdir -p /srv/git && sudo chown engineer:engineer /srv/git
git init --bare /srv/git/istio-config.git && chmod -R 755 /srv/git
sudo tee /etc/systemd/system/git-daemon.service > /dev/null <<'EOF'
[Unit]
Description=Git daemon for Istio course
After=network.target
[Service]
User=engineer
ExecStart=/usr/bin/git daemon --reuseaddr --base-path=/srv/git --export-all --enable=receive-pack --verbose /srv/git
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now git-daemon
git ls-remote git://10.0.2.5/istio-config.git
```

`ВЫ УВИДИТЕ` пустой вывод без ошибок: репозиторий пуст и доступен. В работе 9.1 адрес
`git://10.0.2.5/istio-config.git` — это `repoURL` приложения ArgoCD; `file:///srv/git/...`
не подходит — ArgoCD читает репозиторий из своего пода, а не с диска `admin`.

---

## 13. Доступ к веб-интерфейсам

На `admin` нет графики: сначала `port-forward` на `admin`, затем SSH-туннель с хоста.

```bash
k1 -n istio-system port-forward svc/kiali 20001:20001   # и так же grafana 3000, prometheus 9090
ssh -L 20001:127.0.0.1:20001 -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 engineer@192.168.56.5
```

Браузер хоста: Kiali `localhost:20001`, Grafana `localhost:3000`, Prometheus `localhost:9090`,
Jaeger `localhost:16686`. `istioctl dashboard kiali` на `admin` не сработает — браузера нет.

---

## 14. Аддоны наблюдаемости — не здесь

Prometheus, Grafana, Kiali и Jaeger **не ставятся при сборке стенда**: они ставятся в работе
2.1 из `~/istio-1.25.2/samples/addons`, до неё их на стенде нет. Профиль `demo` в Istio 1.25.2
их не содержит — только istiod и egress gateway. Раньше в курсе считалось, что аддоны входят
в `demo`, и работа 2.1 начиналась с поиска того, чего нет; теперь установка аддонов — первый
шаг самой работы. Проверка перед 2.1: `ls ~/istio-1.25.2/samples/addons` (4 файла).

---

## 15. Сертификаты кластеров перед курсом

Сертификаты kubeadm живут 365 дней. `~/renew-certs.sh` на `admin`:

```bash
#!/bin/bash
# renew-certs.sh — сертификаты kubeadm на мастер-нодах и kubeconfig на admin
set -e
for h in master1 master2 master3 master4; do
  ssh $h "sudo kubeadm certs renew all && sudo systemctl restart kubelet"
done
ssh master1 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-cluster1
sed -i 's/127.0.0.1/10.0.2.10/' ~/.kube/config-cluster1
ssh master4 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config-cluster2
sed -i 's/127.0.0.1/10.0.2.15/' ~/.kube/config-cluster2
chmod 600 ~/.kube/config-cluster1 ~/.kube/config-cluster2 && k1 get nodes && k2 get nodes
```

```bash
chmod +x ~/renew-certs.sh && ~/renew-certs.sh
```

`ВЫ УВИДИТЕ` узлы обоих кластеров `Ready`. Если после обновления один кластер отвечает
`Unauthorized` — повторите копирование kubeconfig (раздел 9): скрипт мог не успеть при обрыве.

---

## 16. Снапшоты

Три опорные точки; снимаются с хоста, ВМ при этом лучше выключить.

| Имя | Когда | Что внутри |
|---|---|---|
| `baseline` | после раздела 7 | Ubuntu, сеть, инструменты; кластеров нет |
| `k8s-ready` | после разделов 8–12 | кластеры, MetalLB, metrics-server, git daemon |
| `mesh-ready` | после работы 1.1 | Istio baseline, bookinfo в mesh |

```powershell
pwsh -File scripts\snapshot.ps1 -Action take -Name k8s-ready
pwsh -File scripts\snapshot.ps1 -Action list
pwsh -File scripts\snapshot.ps1 -Action restore -Name k8s-ready    # ВМ выключены
```

Скрипт снимает снапшот со всех девяти машин, включая `vm-legacy`. Перед `mesh-ready`
убедитесь, что `k1 get pods -n bookinfo` показывает все поды `2/2 Running`.

---

## 17. Чек-лист готовности стенда

| № | Проверка | Ожидаемо |
|---|---|---|
| 1 | `source ~/istio-course/scripts/env.sh; echo $ISTIO_VERSION` | `1.25.2` |
| 2 | `k1 get nodes` / `k2 get nodes` | 5 и 2 узла `Ready` |
| 3 | `k1 version -o short` | 1.36.x (1.32+) |
| 4 | `k1 get ipaddresspool -n metallb-system` | 192.168.56.240-192.168.56.245 |
| 5 | `k2 get ipaddresspool -n metallb-system` | 192.168.56.246-192.168.56.250 |
| 6 | `k1 get svc -A \| grep LoadBalancer` | `EXTERNAL-IP` не `<pending>` |
| 7 | `k1 top nodes` | таблица CPU/memory |
| 8 | `istioctl version --remote=false` | `1.25.2` |
| 9 | `helm version --short` / `argocd version --client --short` | `v3.21.x` / `2.14.x` |
| 10 | `ls ~/istio-1.25.2/samples/addons` | 4 файла аддонов |
| 11 | `git ls-remote git://10.0.2.5/istio-config.git` | пусто, без ошибок |
| 12 | `ssh vm-legacy "python3 --version"` | Python 3.x |
| 13 | `for h in master1 node1 master4 node3 vm-legacy; do ssh $h hostname; done` | 5 имён |
| 14 | `echo $INGRESS_HOST` (после 1.1) | `192.168.56.240` |
| 15 | `scripts\snapshot.ps1 -Action list` | `baseline`, `k8s-ready`, `mesh-ready` |

Пункт 14 до работы 1.1 не выполняется: `INGRESS_HOST` пуст, пока нет `istio-ingressgateway`.

---

## 18. ЕСЛИ ЧТО-ТО ПОШЛО НЕ ТАК

ПРОБЛЕМА: `k1 get nodes` — `The connection to the server 10.0.2.10:6443 was refused`
ПРИЧИНА: control plane не поднялся или в kubeconfig неверный адрес API-сервера.
ЧТО ДЕЛАТЬ: 1) `ssh master1 "sudo crictl ps -a | grep apiserver"`; 2) `ssh master1 "sudo journalctl -u kubelet -n 50 --no-pager"`; 3) `grep server ~/.kube/config-cluster1` — должно быть `10.0.2.10:6443`; 4) `ssh master1 "sudo kubectl get nodes"` — если изнутри работает, проблема в сети до `admin`.

ПРОБЛЕМА: в 6.1 поды кластеров не видят друг друга, `istioctl remote-clusters` пуст
ПРИЧИНА: машины собраны на обычном «NAT», а не на «NAT Network»: каждая в своей 10.0.2.0/24.
ЧТО ДЕЛАТЬ: 1) `ssh node1 ping -c 2 master4` — не пингуется; 2) `VBoxManage list natnetworks` — сеть `istio-lab` есть и `enabled`; 3) `VBoxManage showvminfo node1 | Select-String "NIC 1"` — тип `natnetwork`; 4) пересоздайте сеть и перезапустите ВМ.

ПРОБЛЕМА: `EXTERNAL-IP` сервиса висит в `<pending>`
ПРИЧИНА: MetalLB не установлен, пул не создан или не заявлен L2-анонс.
ЧТО ДЕЛАТЬ: 1) `k1 get pods -n metallb-system` — controller и speaker `Running`; 2) `k1 get ipaddresspool,l2advertisement -n metallb-system` — оба объекта; 3) `k1 logs -n metallb-system deploy/metallb-controller | tail -20`.

ПРОБЛЕМА: адрес MetalLB выдан, но с `admin` не пингуется
ПРИЧИНА: нет promiscuous на Host-Only адаптере или анонс ушёл не в тот интерфейс.
ЧТО ДЕЛАТЬ: 1) `VBoxManage showvminfo node1 | Select-String "NIC 2"` — `allow-all`; 2) `ip -4 addr show enp0s8` на узле — адрес в 192.168.56.0/24; 3) `k1 logs -n metallb-system ds/metallb-speaker | grep -i "arp\|announce"`.

ПРОБЛЕМА: `kubectl top nodes` — `error: Metrics API not available`
ПРИЧИНА: metrics-server не установлен или не проходит TLS до kubelet.
ЧТО ДЕЛАТЬ: 1) `k1 get pods -n kube-system | grep metrics`; 2) `k1 logs -n kube-system deploy/metrics-server | tail -20` — ошибки `x509`; 3) поставьте с `--kubelet-insecure-tls` (раздел 11); 4) подождите 60 секунд.

ПРОБЛЕМА: `istioctl: command not found` после `source env.sh`
ПРИЧИНА: дистрибутив распакован не в `~/istio-1.25.2` или `env.sh` не подключён.
ЧТО ДЕЛАТЬ: 1) `ls ~/istio-1.25.2/bin/istioctl`; 2) `echo $ISTIO_HOME`; 3) `grep env.sh ~/.bashrc` — если строки нет, добавьте и откройте новый терминал.

ПРОБЛЕМА: после перезагрузки узлов поды кластеров перестали видеть друг друга
ПРИЧИНА: статические маршруты pod-сетей (раздел 8.2a) не сохранены и пропали после ребута.
ЧТО ДЕЛАТЬ: 1) проверить маршруты: `ip route | grep 10.245` на узле cluster-1 и `ip route | grep 10.244` на узле cluster-2; 2) добавить заново командами из 8.2a; 3) закрепить их в netplan или systemd-unit; 4) проверить `ping` до пода другого кластера.

ПРОБЛЕМА: узел node1 (10.0.2.13) в статусе NotReady, в кластере 4 узла
ПРИЧИНА: ВМ потеряла сеть или зависла; это инфраструктурный сбой, не ошибка курса.
ЧТО ДЕЛАТЬ: 1) `ping -c 2 10.0.2.13` с admin; 2) перезапустить ВМ из консоли VirtualBox; 3) дождаться Ready: `k1 get nodes`; 4) если не поднимается — откатить снапшот `k8s-ready` или пересобрать узел; 5) после возврата проверить `k1 get pods -n bookinfo` (поды перепланируются) и `curl` к productpage.

---

ПРОБЛЕМА: поды 10–20 минут в `ContainerCreating`/`ImagePullBackOff`, `ctr pull` стоит на 0 B/s
ПРИЧИНА: containerd завис на параллельных pull (часто при первом старте и медленном канале).
ЧТО ДЕЛАТЬ:
  1. `sudo systemctl restart containerd` на узле.
  2. Тянуть образы последовательно (по одному `kubectl apply`, дождаться Running).
  3. Для docker.io добавить mirror `mirror.gcr.io` в `/etc/containerd/certs.d/docker.io/hosts.toml`.

---

ПРОБЛЕМА: поды bookinfo 0/2, в `istio-init` — `unable to initialize table 'nat'`
ПРИЧИНА: после перезагрузки ВМ не загружен модуль `iptable_nat` (часто в NAT-сетях VirtualBox).
ЧТО ДЕЛАТЬ:
  1. На всех узлах: `sudo modprobe iptable_nat iptable_filter iptable_mangle`.
  2. Закрепить: `printf 'iptable_nat\niptable_filter\niptable_mangle\n' | sudo tee /etc/modules-load.d/istio.conf`.
  3. Пересоздать поды: `k1 rollout restart deployment -n bookinfo`.
  4. Проверить: `k1 get pods -n bookinfo` → 2/2.

---

## 19. После сборки

Стенд готов, когда чек-лист раздела 17 сходится. Дальше — `README.md`: как проходить курс
и с чего начать. Если стенд испортился — раздел 18 и снапшоты раздела 16; состояния стенда
описаны в `architecture.md` §6.

---

## 20. Готовый стенд для занятий

«Чистый» `admin` — это Ubuntu с kubeconfig, но без `kubectl`, `helm`, `istioctl`, `argocd`
и без репозитория курса. Готовый стенд — это состояние после разделов 7–12, с инструментами
и кластерами, зафиксированное снапшотом.

**Инструменты.** На чистом `admin` выполните `bash ~/istio-course/scripts/bootstrap-admin.sh`
(или команды раздела 7 вручную). Скрипт ставит kubectl 1.32+, Helm 3.21.3, istioctl 1.25.2,
ArgoCD CLI 2.14.0 и проверяет версии; нужны интернет и `sudo`.

**Что должно быть на готовом стенде:**

| Что | Проверка |
|---|---|
| Репозиторий курса | `ls ~/istio-course/labs` — 21 файл; `source ~/istio-course/scripts/env.sh` |
| Инструменты | `kubectl version --client`, `helm version --short`, `istioctl version --remote=false`, `argocd version --client` |
| Кластеры | `k1 get nodes` — 5 Ready, `k2 get nodes` — 2 Ready |
| MetalLB, metrics-server | `k1 get ipaddresspool -n metallb-system`, `k1 top nodes` |
| StorageClass, git daemon | `k1 get sc`, `systemctl status git-daemon` |
| Снапшоты | `scripts\snapshot.ps1 -Action list` — есть `k8s-ready` |

**Фиксация.** Стенд для слушателей должен быть в состоянии `k8s-ready` (до работы 1.1:
Istio ещё не установлен). Выключите все ВМ и снимите снапшот:

```powershell
pwsh -File scripts\snapshot.ps1 -Action take -Name k8s-ready
pwsh -File scripts\snapshot.ps1 -Action list
```

Перед каждой группой восстанавливайте его: `-Action restore -Name k8s-ready` (ВМ выключены).
`mesh-ready` — состояние после 1.1; для старта курса он не подходит, потому что 1.1
устанавливает Istio сама.

**Если в аудитории нет интернета**, образы контейнеров нужно прогреть на стенде с сетью
до снятия снапшота. Без этого первый `kubectl apply` в 1.1 уйдёт в `ImagePullBackOff`.
Дистрибутив Istio и `samples/` уже лежат в `~/istio-1.25.2` после раздела 7.

**Если раздаёте стенд как образ (OVA/клоны):** экспортируйте выключенные ВМ, при импорте
сохраните имя NAT Network `istio-lab`, Host-Only адаптер и статические IP. Две копии стенда
в одной сети конфликтуют по MAC/IP — используйте отдельные хосты или сети.

DSH-агенту для проверки курса всё равно нужен доступ к API модели: полностью офлайн он
не работает, даже если стенд прогреться.

**Раздача слушателям (OVA).**

1. На `admin` (можно через DSH): `bash ~/istio-course/scripts/check-stand.sh` — дождитесь
   `ИТОГ: PASS`. Скрипт проверяет инструменты, узлы, MetalLB, metrics-server, StorageClass,
   git-daemon и что Istio ещё не установлен (стенд в состоянии `k8s-ready`).
2. На хосте выключите ВМ и соберите OVA:

   ```powershell
   pwsh -File scripts\export-stand.ps1 -Output D:\istio-stand.ova -Force
   ```

   `-Force` выключает работающие ВМ по ACPI. В OVA попадают все девять машин одним
   appliance; NAT Network и Host-Only в OVA не входят.
3. Передайте слушателю OVA и `scripts\import-stand.ps1`. Ему нужно только:

   ```powershell
   pwsh -File scripts\import-stand.ps1 -Ova D:\istio-stand.ova
   ```

   Скрипт создаёт NAT Network `istio-lab` (10.0.2.0/24, DHCP off), Host-Only адаптер
   `192.168.56.1/24`, импортирует ВМ, привязывает к ним обе сети и перегенерирует MAC.
4. Слушатель запускает ВМ, заходит `ssh engineer@10.0.2.5`, выполняет
   `source ~/istio-course/scripts/env.sh` и открывает `labs/lab-1.1_install.txt`.

Ограничения: OVA большая (диски девяти ВМ); на одном хосте — одна копия стенда, иначе
конфликт IP; Host-Only `192.168.56.0/24` не должен пересекаться с домашней сетью
слушателя; если стенд уже прогонялся, сначала восстановите `k8s-ready` или пересоберите.
