BeforeAll {
  $script:Manifest = "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1"
  Import-Module $script:Manifest -Force
}

Describe 'BOL cache runtime contract' {
  It 'declares the PowerShell version needed to preserve JSON timestamps' {
    (Import-PowerShellDataFile $script:Manifest).PowerShellVersion | Should -Be '7.5'
  }

  It 'keeps the original timestamp string <Timestamp>' -ForEach @(
    @{ Timestamp = '2026-08-02T10:15:00.250' }
    @{ Timestamp = '2026-08-02T10:15:00.2500000Z' }
    @{ Timestamp = '2026-08-02T10:15:00.2500000+05:30' }
  ) {
    $folder = Join-Path $TestDrive 'cache'
    $null = New-Item -ItemType Directory -Force $folder
    @{ sent_at = $Timestamp; rows = @(@{ sourceUpdatedAt = $Timestamp }) } |
      ConvertTo-Json -Depth 4 | Set-Content (Join-Path $folder '7.json')
    $cached = & (Get-Module PilotCarrierIntegration) { param($path) Get-PilotBolCache $path 7 } $folder
    $cached.sent_at | Should -BeOfType [string]
    $cached.sent_at | Should -BeExactly $Timestamp
    $cached.rows[0].sourceUpdatedAt | Should -BeOfType [string]
    $cached.rows[0].sourceUpdatedAt | Should -BeExactly $Timestamp
  }
}
