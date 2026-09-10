<#
Compiles ADPasswordChanger.ps1 into a standalone executable via ps2exe.
#>

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repoRoot = Split-Path $root -Parent
$source = Join-Path $repoRoot 'ADPasswordChanger.ps1'
$icon = Join-Path $root 'icon.ico'
$outDir = Join-Path $repoRoot 'dist'
$output = Join-Path $outDir 'ADPasswordChanger.exe'

$module = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
if (-not $module) {
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    $module = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
}

if (-not $module) {
    $installed = Get-InstalledModule -Name ps2exe -ErrorAction SilentlyContinue
    if ($installed) {
        Import-Module (Join-Path $installed.InstalledLocation 'ps2exe.psd1') -Force
    } else {
        throw "The ps2exe module could not be found, even after installation."
    }
} else {
    Import-Module $module -Force
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Invoke-ps2exe -InputFile $source -OutputFile $output -iconFile $icon -NoConsole -Title 'AD Password Changer' -STA

Write-Output "Executable generated: $output"
