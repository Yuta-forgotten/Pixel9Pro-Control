param(
    [string]$ModuleRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $ModuleRoot
$Python = 'D:\Environment\miniconda3\python.exe'
$BuildScript = Join-Path $ProjectRoot 'builds\scripts\build_module.py'
$ManifestPath = Join-Path $ModuleRoot 'config\baseband_devices.tsv'
$RuntimeContractPath = Join-Path $ModuleRoot 'config\runtime_contract.tsv'
$CustomizePath = Join-Path $ModuleRoot 'customize.sh'
$RuntimeHelperPath = Join-Path $ModuleRoot 'scripts\baseband_runtime.sh'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $ManifestPath) 'device manifest is missing'
Assert-True (Test-Path -LiteralPath $RuntimeContractPath) 'runtime contract is missing'
Assert-True (Test-Path -LiteralPath $RuntimeHelperPath) 'runtime readback helper is missing'
$manifestLines = Get-Content -LiteralPath $ManifestPath | Where-Object { $_ -and -not $_.StartsWith('#') }
$rows = @($manifestLines | ConvertFrom-Csv -Delimiter '|' -Header device,label,uecap_policy,source_rel,target_name,bytes,sha256)
Assert-True ($rows.Count -eq 2) "expected 2 device rows, got $($rows.Count)"
Assert-True ((@($rows.device | Sort-Object -Unique) -join ',') -eq 'caiman,komodo') 'device allowlist must be exactly caiman,komodo'

$caiman = $rows | Where-Object device -eq 'caiman'
$komodo = $rows | Where-Object device -eq 'komodo'
Assert-True ($caiman.uecap_policy -eq 'external') 'caiman UECap must remain external'
Assert-True ($komodo.uecap_policy -eq 'external') 'komodo UECap must use the external/stock policy'
Assert-True ([string]::IsNullOrWhiteSpace([string]$komodo.target_name)) 'komodo must not declare a standalone UECap target'
Assert-True (
    [string]::IsNullOrWhiteSpace([string]$komodo.source_rel) -and
    [string]::IsNullOrWhiteSpace([string]$komodo.bytes) -and
    [string]::IsNullOrWhiteSpace([string]$komodo.sha256)
) 'standalone manifest must not carry UECap payload metadata'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $ModuleRoot 'system\vendor\firmware\uecapconfig'))) 'source tree must not pre-stage a device-specific UECap overlay'
Assert-True (@(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File -Filter '*.binarypb').Count -eq 0) 'standalone source must not contain any UECap binarypb'

$carrierCount = @(Get-ChildItem -LiteralPath (Join-Path $ModuleRoot 'system\product\etc\CarrierSettings') -File).Count
$mcfgCount = @(Get-ChildItem -LiteralPath (Join-Path $ModuleRoot 'system\vendor\rfs\msm\mpss\readonly\vendor\mbn\mcfg_sw\generic\China') -Recurse -File -Filter 'mcfg_sw.mbn').Count
Assert-True ($carrierCount -eq 3210) "CarrierSettings count mismatch: $carrierCount"
Assert-True ($mcfgCount -eq 5) "China MCFG count mismatch: $mcfgCount"
Assert-True (Test-Path -LiteralPath (Join-Path $ModuleRoot 'system\product\etc\apns-conf.xml')) 'APN overlay is missing'

$moduleProp = Get-Content -LiteralPath (Join-Path $ModuleRoot 'module.prop') -Raw
Assert-True ($moduleProp -match '(?m)^version=v1\.1\.0-rc3$') 'module version is not v1.1.0-rc3'
Assert-True ($moduleProp -match '(?m)^versionCode=112$') 'module versionCode is not 112'
$customize = Get-Content -LiteralPath $CustomizePath -Raw
foreach ($needle in @('ro.product.device','ro.build.product','config/baseband_devices.tsv','UECap payload','metamodule=1','metainstall.sh','Unknown','不要卸载 APatch Manager')) {
    Assert-True ($customize.Contains($needle)) "customize.sh contract missing: $needle"
}
$legacyStaticCandidate = 'static' + '_candidate'
$legacyKomodoStage = 'stage' + '_komodo_uecap'
Assert-True (-not $customize.Contains($legacyStaticCandidate)) 'legacy static candidate policy remains'
Assert-True (-not $customize.Contains($legacyKomodoStage)) 'legacy komodo UECap staging remains'
Assert-True (-not $customize.Contains('[ "$device" != "caiman" ]')) 'legacy caiman-only gate remains'
Assert-True (-not $customize.Contains('exit 1')) 'customize.sh must use installer abort/return contract'
Assert-True (-not $customize.Contains('meta-overlayfs|meta_overlayfs|hybrid_mount')) 'MetaModule detection must not use a hardcoded name list'
Assert-True ($customize.Contains('[ -L "$_link" ]')) 'active MetaModule contract must require a symlink'
Assert-True ($customize.Contains('multiple enabled modules declare metamodule=1')) 'ambiguous marker-only MetaModules must fail closed'

$runtimeContract = Get-Content -LiteralPath $RuntimeContractPath | Where-Object { $_ -and -not $_.StartsWith('#') }
Assert-True ($runtimeContract.Count -eq 4) "runtime contract row count mismatch: $($runtimeContract.Count)"
Assert-True ((($runtimeContract -join "`n") -match '/product/etc/CarrierSettings')) 'runtime contract misses CarrierSettings'
Assert-True ((($runtimeContract -join "`n") -match '/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China')) 'runtime contract misses China MCFG'
$runtimeHelper = Get-Content -LiteralPath $RuntimeHelperPath -Raw
Assert-True ($runtimeHelper.Contains('baseband_contract_value')) 'runtime helper must consume runtime_contract.tsv'
Assert-True (-not $runtimeHelper.Contains('83b7ced089f42fec0cfbe8d445a99536ea47e07403b781f90c6d869cf4535342')) 'runtime hash must remain in the contract SoT'

$Wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
$wslRoot = (& $Wsl wslpath -a $ModuleRoot).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $wslRoot) 'cannot resolve module path in WSL'
& $Wsl -e bash -n "$wslRoot/customize.sh"
Assert-True ($LASTEXITCODE -eq 0) 'customize.sh bash parser failed'
& $Wsl -e bash "$wslRoot/tests/customize_device_gate_test.sh"
Assert-True ($LASTEXITCODE -eq 0) 'customize device gate test failed'
& $Wsl -e bash "$wslRoot/tests/metainstall_relocation_test.sh"
Assert-True ($LASTEXITCODE -eq 0) 'MetaModule relocation fixture failed'
& $Wsl -e bash -n "$wslRoot/scripts/baseband_runtime.sh"
Assert-True ($LASTEXITCODE -eq 0) 'runtime helper bash parser failed'

& $Python $BuildScript --validate-only $ModuleRoot
Assert-True ($LASTEXITCODE -eq 0) 'module source validation failed'
$fingerprint1 = (& $Python $BuildScript --fingerprint $ModuleRoot | Select-Object -Last 1).Trim()
$fingerprint2 = (& $Python $BuildScript --fingerprint $ModuleRoot | Select-Object -Last 1).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $fingerprint1 -eq $fingerprint2 -and $fingerprint1 -match '^[0-9a-f]{64}$') 'source fingerprint is not deterministic'

[pscustomobject]@{
    Status = 'PASS'
    Devices = @($rows.device)
    UecapPayloads = @(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File -Filter '*.binarypb').Count
    CarrierSettings = $carrierCount
    ChinaMCFG = $mcfgCount
    RuntimeContract = $RuntimeContractPath
    SourceFingerprint = $fingerprint1
} | ConvertTo-Json -Depth 4
