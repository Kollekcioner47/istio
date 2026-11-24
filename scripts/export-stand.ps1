#Requires -Version 5.1
<#
.SYNOPSIS
    Exports the nine Istio course VMs into one OVA appliance (run on the host).

.DESCRIPTION
    Shuts the VMs down (or requires -Force), then runs VBoxManage export
    with all VMs into a single OVA. The OVA contains the VM disks and
    current state; it does NOT contain the VirtualBox NAT Network or the
    Host-Only adapter - the student's import script creates them.

.EXAMPLE
    pwsh -File scripts\export-stand.ps1 -Output D:\istio-stand.ova -Force
#>
[CmdletBinding()]
param(
    [string]$Output = 'istio-stand.ova',
    [string[]]$VMs = @(
        'admin', 'master1', 'master2', 'master3',
        'node1', 'node2', 'master4', 'node3', 'vm-legacy'
    ),
    [string]$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-VBoxManage {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return $Path }
    $cmd = Get-Command 'VBoxManage' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "VBoxManage not found. Pass -VBoxManage 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'"
}

function Get-VmState {
    param([string]$VmName)
    $info = & $script:VBox showvminfo $VmName --machinereadable 2>&1
    if ($LASTEXITCODE -ne 0) { return 'missing' }
    foreach ($line in $info) {
        if ($line -match '^VMState="(.+)"$') { return $Matches[1] }
    }
    return 'unknown'
}

function Stop-Vm {
    param([string]$VmName)
    & $script:VBox controlvm $VmName acpipowerbutton | Out-Null
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VmState -VmName $VmName) -eq 'poweroff') { return }
        Start-Sleep -Seconds 3
    }
    throw "$VmName did not power off in 180s"
}

$script:VBox = Resolve-VBoxManage -Path $VBoxManage
Write-Host "[info] VBoxManage: $script:VBox"

$list = & $script:VBox list vms 2>&1
$existing = @()
foreach ($vm in $VMs) {
    if ($list -match ('"' + [regex]::Escape($vm) + '"')) {
        $existing += $vm
    } else {
        Write-Host "[warn] VM '$vm' not found, skipped"
    }
}
if ($existing.Count -eq 0) { throw 'No course VMs found.' }

foreach ($vm in $existing) {
    $state = Get-VmState -VmName $vm
    if ($state -ne 'poweroff') {
        if (-not $Force) {
            throw "VM '$vm' is '$state'. Shut it down or pass -Force."
        }
        Write-Host "[info] powering off $vm"
        Stop-Vm -VmName $vm
    }
}

if (Test-Path -LiteralPath $Output) {
    throw "Output already exists: $Output"
}

Write-Host "[info] exporting $($existing.Count) VMs to $Output ..."
& $script:VBox export @existing --output $Output
if ($LASTEXITCODE -ne 0) { throw "VBoxManage export failed with code $LASTEXITCODE" }

$sizeGb = [math]::Round((Get-Item -LiteralPath $Output).Length / 1GB, 2)
Write-Host "[ ok ] $Output ($sizeGb GB)"
Write-Host "Next: give the OVA and scripts\import-stand.ps1 to the student; networks are created by import."
