param(
    [string]$SourceDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SourceDir).Path
$wslPath = (& wsl.exe wslpath -a -u -- $source).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslPath)) {
    throw "无法将温控源码目录转换为 WSL 路径: $source"
}

$testRoot = "$wslPath/tmp/thermal-fast"
$thermalTest = "$wslPath/tests/thermal_profile_test.sh"
& wsl.exe rm -rf -- $testRoot
& wsl.exe mkdir -p -- $testRoot
& wsl.exe sh $thermalTest $wslPath $testRoot
$thermalRc = $LASTEXITCODE
& wsl.exe rm -rf -- $testRoot
if ($thermalRc -ne 0) {
    throw "thermal_profile_test.sh 失败，退出码: $thermalRc"
}

Push-Location $source
try {
    & npm run test:webui:contract
    if ($LASTEXITCODE -ne 0) {
        throw "WebUI contract 失败，退出码: $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Write-Output 'Thermal fast gate passed: thermal profile + WebUI contract.'
