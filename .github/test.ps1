param([version]$ExpectedVersion)
$ErrorActionPreference = 'Stop'
if ($ExpectedVersion -and $PSVersionTable.PSVersion -ne $ExpectedVersion) { throw "Expected PowerShell $ExpectedVersion, got $($PSVersionTable.PSVersion)" }
$PSVersionTable | Format-Table
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
# the manifest is the one list of pins: install exactly what it requires
$manifest = Join-Path $PSScriptRoot '../PilotCarrierIntegration/PilotCarrierIntegration.psd1'
foreach ($r in (Import-PowerShellDataFile $manifest).RequiredModules) { Install-Module $r.ModuleName -RequiredVersion $r.RequiredVersion -Scope CurrentUser -Force -AcceptLicense }
Install-Module Add-PrefixForLogging, SqlServer -Scope CurrentUser -Force -AcceptLicense
Install-Module Clear-Files -RequiredVersion 1.1.0.0 -Scope CurrentUser -Force -AcceptLicense
Test-ModuleManifest $manifest | Out-Null
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot '../tests'
$config.Run.Exit = $true
$config.TestResult.Enabled = $true
# feed tests change location; their temporary working folder is gone before reporting
$config.TestResult.OutputPath = Join-Path $PSScriptRoot '../TestResults.xml'
Invoke-Pester -Configuration $config
