BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
}

Describe 'artifact retention config' {
  It 'binds its runner and SQL source to the exact version despite the document dependency' {
    & (Get-Module PilotCarrierIntegration) {
      $script:DataAgent.Version.ToString() | Should -Be '0.7.4'
      (Get-Command Invoke-DataAgent).Module.Version.ToString() | Should -Be '0.7.4'
    }
    @(Get-Module DataAgent | ForEach-Object { $_.Version.ToString() }) | Should -Contain '0.5.0'
  }
  BeforeEach {
    $path = Join-Path $TestDrive 'settings.json'
    $settings = @{
      keepdays = 10; purgefiles = '*.log'
      tmw = @{ InputFile = 'example.sql'; Variable = @() }
    }
    Mock Get-PilotBolCursor -ModuleName PilotCarrierIntegration { }
  }

  It 'passes filename-day cleanup through all feed wrappers' {
    $settings.filename_date_format = 'yyyyMMdd'
    $settings | ConvertTo-Json -Depth 8 | Set-Content $path
    foreach ($command in 'New-PilotCarrierBolConfig', 'New-PilotCarrierOrderConfig', 'New-PilotCarrierDocumentConfig') {
      $config = & $command $path
      $config.filename_date_format | Should -BeExactly 'yyyyMMdd'
      $config.keepdays | Should -Be 10
      $config.purgefiles | Should -BeExactly '*.log'
    }
  }

  It 'omits the optional setting when absent' {
    $settings | ConvertTo-Json -Depth 8 | Set-Content $path
    foreach ($command in 'New-PilotCarrierBolConfig', 'New-PilotCarrierOrderConfig', 'New-PilotCarrierDocumentConfig') {
      (& $command $path).ContainsKey('filename_date_format') | Should -BeFalse
    }
  }
}
