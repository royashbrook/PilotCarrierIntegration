BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  . "$PSScriptRoot/MappingParity.ps1"
}

Describe 'mapping parity with released 0.7.10' {
  It 'keeps canonical orders, EDI archives, SQL and parameters for all seven baseline cases' {
    $expected = Get-Content "$PSScriptRoot/fixtures/order-mapping-parity.json" -Raw | ConvertFrom-Json
    $actual = @(Measure-MappingParity "$PSScriptRoot/fixtures")
    $expected.baseline | Should -Be 'd11bbc03a5ae9bebd274a60faf73a814452c8a18'
    $actual.Count | Should -Be $expected.cases.Count
    foreach ($case in $actual) {
      $before = @($expected.cases | Where-Object name -eq $case.name)[0]
      foreach ($field in 'order', 'archive', 'sql', 'parameters') { $case.$field | Should -Be $before.$field -Because "$($case.name) $field is unchanged" }
    }
  }
  It 'keeps the exact rejection reason and precedence for twelve invalid combinations' {
    $expected = Get-Content "$PSScriptRoot/fixtures/order-mapping-parity.json" -Raw | ConvertFrom-Json
    $actual = @(Measure-MappingRejections "$PSScriptRoot/fixtures")
    $actual.Count | Should -Be 12
    foreach ($case in $actual) { $case.reason | Should -Be @($expected.rejections | Where-Object name -eq $case.name)[0].reason -Because $case.name }
  }
}
