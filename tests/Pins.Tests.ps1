Describe 'dependency pins' {
  It 'pins every required module to the exact version its tests ran against' {
    $manifest = Import-PowerShellDataFile "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1"
    foreach ($required in @($manifest.RequiredModules)) {
      $required | Should -BeOfType [hashtable] -Because 'a bare name loads whatever version is installed'
      $required.RequiredVersion | Should -Not -BeNullOrEmpty -Because "$($required.ModuleName) needs an exact version, not a minimum"
    }
  }
  It 'pins every module the code imports by name' {
    $bare = @(Get-ChildItem "$PSScriptRoot/../PilotCarrierIntegration" -Recurse -Include *.ps1, *.psm1 | Select-String -Pattern 'Import-Module\s+[A-Za-z]' |
      Where-Object { $_.Line -notmatch '-RequiredVersion' })
    $bare | ForEach-Object { "$($_.Filename):$($_.LineNumber)" } | Should -BeNullOrEmpty
  }
}
