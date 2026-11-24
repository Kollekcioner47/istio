#Requires -Version 5.1
<#
.SYNOPSIS
    Снапшоты виртуальных машин стенда курса «Istio для эксплуатации».

.DESCRIPTION
    Управляет снапшотами девяти ВМ стенда через VBoxManage с хоста.
    Курс использует три опорные точки (architecture.md, раздел 6):

        baseline    — Ubuntu, сеть, инструменты; кластеров ещё нет
        k8s-ready   — два кластера, MetalLB, metrics-server, git daemon
        mesh-ready  — Istio baseline и bookinfo в mesh (после работы 1.1)

    Снимать снапшоты рекомендуется на выключенных ВМ: снапшот выключенной машины
    восстанавливается в предсказуемое состояние. Живую ВМ тоже можно снять, но при
    восстановлении потеряется всё, что было в памяти.

.PARAMETER Action
    take    — снять снапшот с каждой ВМ;
    list    — показать снапшоты всех ВМ;
    restore — восстановить ВМ из снапшота (ВМ должны быть выключены);
    delete  — удалить снапшот с каждой ВМ.

.PARAMETER Name
    Имя снапшота. По умолчанию baseline.

.PARAMETER VMs
    Список ВМ. По умолчанию — все девять машин стенда.

.PARAMETER VBoxManage
    Путь к VBoxManage.exe. По умолчанию — стандартный путь установки VirtualBox.

.PARAMETER Force
    Для restore: выключить работающие ВМ через ACPI, не спрашивая.

.EXAMPLE
    pwsh -File scripts\snapshot.ps1 -Action take -Name k8s-ready

.EXAMPLE
    pwsh -File scripts\snapshot.ps1 -Action list

.EXAMPLE
    pwsh -File scripts\snapshot.ps1 -Action restore -Name mesh-ready -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('take', 'list', 'restore', 'delete')]
    [string]$Action = 'list',

    [string]$Name = 'baseline',

    [string[]]$VMs = @(
        'admin', 'master1', 'master2', 'master3',
        'node1', 'node2', 'master4', 'node3', 'vm-legacy'
    ),

    [string]$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message, [string]$Status = 'info')
    switch ($Status) {
        'ok'    { Write-Host "[ ok ]  $Message" -ForegroundColor Green }
        'skip'  { Write-Host "[skip]  $Message" -ForegroundColor Yellow }
        'fail'  { Write-Host "[fail]  $Message" -ForegroundColor Red }
        default { Write-Host "[info]  $Message" }
    }
}

function Resolve-VBoxManage {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return $Path
    }

    $cmd = Get-Command 'VBoxManage' -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw "VBoxManage не найден. Укажите путь параметром -VBoxManage, например: -VBoxManage 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'"
}

function Invoke-VBox {
    param([string[]]$Arguments)

    $output = & $script:VBox @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "VBoxManage $($Arguments -join ' ') завершился с кодом ${code}: $output"
    }
    return $output
}

function Test-VmExists {
    param([string]$VmName)

    $list = & $script:VBox list vms 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось получить список ВМ: $list"
    }
    return ($list -match "`"$([regex]::Escape($VmName))`"")
}

function Get-VmState {
    param([string]$VmName)

    $info = & $script:VBox showvminfo $VmName --machinereadable 2>&1
    if ($LASTEXITCODE -ne 0) {
        return 'unknown'
    }
    foreach ($line in $info) {
        if ($line -match '^VMState="(.+)"$') {
            return $Matches[1]
        }
    }
    return 'unknown'
}

function Get-SnapshotNames {
    param([string]$VmName)

    $output = & $script:VBox snapshot $VmName list 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $names = @()
    foreach ($line in $output) {
        if ($line -match '^\s+Name:\s+(.+?)\s+\(UUID:') {
            $names += $Matches[1]
        }
    }
    return $names
}

function Stop-VmGracefully {
    param([string]$VmName, [int]$TimeoutSeconds = 120)

    Write-Step "выключаю $VmName (ACPI)"
    & $script:VBox controlvm $VmName acpipowerbutton | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VmState -VmName $VmName) -eq 'poweroff') {
            Write-Step "$VmName выключена" 'ok'
            return
        }
        Start-Sleep -Seconds 3
    }
    throw "$VmName не выключилась за $TimeoutSeconds секунд. Выключите её вручную и повторите."
}

# --- Подготовка -------------------------------------------------------------

$script:VBox = Resolve-VBoxManage -Path $VBoxManage
Write-Step "VBoxManage: $script:VBox"
Write-Step "действие: $Action, снапшот: $Name, машин: $($VMs.Count)"

$existing = @()
foreach ($vm in $VMs) {
    if (Test-VmExists -VmName $vm) {
        $existing += $vm
    }
    else {
        Write-Step "ВМ '$vm' не найдена, пропускаю" 'skip'
    }
}

if ($existing.Count -eq 0) {
    throw 'Ни одной ВМ стенда не найдено. Проверьте, что стенд собран (setup-guide.md, раздел 4).'
}

$failed = @()

# --- list -------------------------------------------------------------------

if ($Action -eq 'list') {
    foreach ($vm in $existing) {
        $state = Get-VmState -VmName $vm
        $names = Get-SnapshotNames -VmName $vm
        if ($names.Count -eq 0) {
            Write-Step ("{0,-10} {1,-10} снапшотов нет" -f $vm, $state)
            continue
        }
        Write-Step ("{0,-10} {1,-10} {2}" -f $vm, $state, ($names -join ', '))
    }

    $withTarget = 0
    foreach ($vm in $existing) {
        if ((Get-SnapshotNames -VmName $vm) -contains $Name) {
            $withTarget++
        }
    }
    Write-Step "снапшот '$Name' есть на $withTarget из $($existing.Count) машин"
    exit 0
}

# --- take -------------------------------------------------------------------

if ($Action -eq 'take') {
    foreach ($vm in $existing) {
        try {
            $state = Get-VmState -VmName $vm
            if ($state -ne 'poweroff') {
                Write-Step "$vm в состоянии '$state' — снимаю живой снапшот (для restore лучше выключить)" 'skip'
            }

            if ((Get-SnapshotNames -VmName $vm) -contains $Name) {
                Write-Step "снапшот '$Name' на $vm уже есть — перезаписываю" 'skip'
                Invoke-VBox -Arguments @('snapshot', $vm, 'delete', $Name) | Out-Null
            }

            $description = 'стенд курса Istio; снят ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
            Invoke-VBox -Arguments @('snapshot', $vm, 'take', $Name, '--description', $description) | Out-Null
            Write-Step "снапшот '$Name' снят: $vm" 'ok'
        }
        catch {
            Write-Step "ошибка на $vm : $($_.Exception.Message)" 'fail'
            $failed += $vm
        }
    }
}

# --- restore ----------------------------------------------------------------

if ($Action -eq 'restore') {
    $missing = @()
    foreach ($vm in $existing) {
        if (-not ((Get-SnapshotNames -VmName $vm) -contains $Name)) {
            $missing += $vm
        }
    }
    if ($missing.Count -gt 0) {
        throw "Снапшот '$Name' отсутствует на машинах: $($missing -join ', '). Сначала снимите его: -Action take -Name $Name"
    }

    foreach ($vm in $existing) {
        try {
            $state = Get-VmState -VmName $vm
            if ($state -ne 'poweroff') {
                if (-not $Force) {
                    Write-Step "$vm в состоянии '$state' — восстановление требует выключенной ВМ (или запустите с -Force)" 'skip'
                    $failed += $vm
                    continue
                }
                Stop-VmGracefully -VmName $vm
            }

            Invoke-VBox -Arguments @('snapshot', $vm, 'restore', $Name) | Out-Null
            Write-Step "восстановлено: $vm ← $Name" 'ok'
        }
        catch {
            Write-Step "ошибка на $vm : $($_.Exception.Message)" 'fail'
            $failed += $vm
        }
    }
}

# --- delete -----------------------------------------------------------------

if ($Action -eq 'delete') {
    foreach ($vm in $existing) {
        try {
            if (-not ((Get-SnapshotNames -VmName $vm) -contains $Name)) {
                Write-Step "снапшота '$Name' на $vm нет" 'skip'
                continue
            }
            Invoke-VBox -Arguments @('snapshot', $vm, 'delete', $Name) | Out-Null
            Write-Step "снапшот '$Name' удалён: $vm" 'ok'
        }
        catch {
            Write-Step "ошибка на $vm : $($_.Exception.Message)" 'fail'
            $failed += $vm
        }
    }
}

# --- Итог -------------------------------------------------------------------

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Step "не выполнено на $($failed.Count) машинах: $($failed -join ', ')" 'fail'
    exit 1
}

Write-Step "готово: $Action '$Name' на $($existing.Count) машинах" 'ok'
exit 0
