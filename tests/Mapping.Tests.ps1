BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  . "$PSScriptRoot/MappingParity.ps1"
}

Describe 'caller-owned mapping configuration' {
  BeforeAll {
    $script:defaultText = Get-Content "$PSScriptRoot/../PilotCarrierIntegration/order-mapping.psd1" -Raw
    $script:case = @(Get-MappingParityCases "$PSScriptRoot/fixtures")[0]
  }
  It 'resolves the override relative to settings and passes it through the real factory' {
    $dir = Join-Path $TestDrive 'factory'
    New-Item -ItemType Directory $dir | Out-Null
    Set-Content "$dir/custom.psd1" -Value $defaultText
    @{ order_mapping = 'custom.psd1' } | ConvertTo-Json | Set-Content "$dir/settings.json"
    $config = New-PilotCarrierOrderConfig "$dir/settings.json"
    $config.src.args.Settings.order_mapping | Should -Be 'custom.psd1'
    $config.src.args.Settings.directory | Should -Be $dir
  }
  It 'uses both literal and source overrides without changing the mapper code' {
    $dir = Join-Path $TestDrive 'values'
    New-Item -ItemType Directory $dir | Out-Null
    $text = $defaultText.Replace("destination = 'weight'; value = 0", "destination = 'weight'; value = 5").Replace("destination = 'bolNumber'; source = 'record.bolNumber'", "destination = 'bolNumber'; source = 'record.sourceSystemOrderId'")
    $text | Should -Not -Be $defaultText
    Set-Content "$dir/custom.psd1" -Value $text
    $cfg = $case.cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $cfg | Add-Member directory $dir
    $cfg | Add-Member order_mapping 'custom.psd1'
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case; cfg = $cfg } {
      $result = ConvertFrom-PilotOrder $c.record $cfg $c.references
      $result.bolNumber | Should -Be $c.record.sourceSystemOrderId
      $result.stops[0].freight[0].weight | Should -Be 5
    }
  }
  It 'applies changed regex checks before reference lookup and direct translation' {
    $dir = Join-Path $TestDrive 'checks'
    New-Item -ItemType Directory $dir | Out-Null
    $old = "field = 'Freight.productCode'; kind = 'regex'; pattern = '\S'"
    $text = $defaultText.Replace($old, "field = 'Freight.productCode'; kind = 'regex'; pattern = '^OTHER$'")
    $text | Should -Not -Be $defaultText
    Set-Content "$dir/custom.psd1" -Value $text
    $cfg = $case.cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $cfg | Add-Member directory $dir
    $cfg | Add-Member order_mapping 'custom.psd1'
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case; cfg = $cfg } {
      Mock Get-PilotOrder { @($c.record) }
      Mock Get-PilotReferenceData { throw 'invalid data reached reference lookup' }
      Mock Write-Log
      @(Receive-PilotOrders $cfg ([pscustomobject]@{})).Count | Should -Be 0
      Should -Invoke Get-PilotReferenceData -Times 0 -Exactly
      { ConvertFrom-PilotOrder $c.record $cfg $c.references } | Should -Throw '*no productCode*'
    }
  }
  It 'follows a remapped required source instead of checking the former property' {
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case } {
      $map = Read-PilotOrderMapping
      (Get-PilotMappingRow $map 'Freight.productCode').source = 'item.alternateProduct'
      $raw = $c.record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      Get-PilotOrderSkipReason $raw -Mapping $map | Should -Be 'no productCode on item 11888001'
      $raw.dispatchOrderItems[0] | Add-Member alternateProduct 'ALT'
      (ConvertFrom-PilotOrder $raw $c.cfg $c.references -Mapping $map).stops[0].freight[0].productCode | Should -Be 'ALT'
    }
  }
  It 'validates a literal quantity rather than the former gallons source' {
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case } {
      $map = Read-PilotOrderMapping
      $row = Get-PilotMappingRow $map 'Freight.quantity'
      $row.Remove('source')
      $row.value = 0
      Get-PilotOrderSkipReason $c.record -Mapping $map | Should -Be 'no gallons on item 11888001'
      $row.value = 100
      (ConvertFrom-PilotOrder $c.record $c.cfg $c.references -Mapping $map).stops[0].freight[0].quantity | Should -Be 100
    }
  }
  It 'shares record and create context between item validation and translation' {
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case } {
      $map = Read-PilotOrderMapping
      (Get-PilotMappingRow $map 'Freight.productCode').source = 'record.sourceSystemOrderId'
      (Get-PilotMappingRow $map 'Freight.quantity').source = 'cfg.create.testGallons'
      $cfg = $c.cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $cfg.create | Add-Member testGallons 100
      Get-PilotOrderSkipReason $c.record -Mapping $map -Cfg $cfg | Should -BeNullOrEmpty
      $order = ConvertFrom-PilotOrder $c.record $cfg $c.references -Mapping $map
      $order.stops[0].freight[0].productCode | Should -Be $c.record.sourceSystemOrderId
      $order.stops[0].freight[0].quantity | Should -Be 100
    }
  }
  It 'shares context with supplier lookups and contract-ID aggregation' {
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case } {
      $map = Read-PilotOrderMapping
      (Get-PilotMappingRow $map 'Freight.supplierContractId').source = 'record.sharedSupplier'
      $raw = $c.record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $raw | Add-Member sharedSupplier 10180
      $raw.dispatchOrderItems[0].looSystemId = $null
      $order = ConvertFrom-PilotOrder $raw $c.cfg $c.references -Mapping $map
      $order.contractSystemIds | Should -Be @(10180)
      $order.stops[0].freight[0].supplierContractId | Should -Be '10180'
      $order.stops[0].freight[0].supplierName | Should -Be 'CARGILL'
      $order.pilotOrderItemIds | Should -Be @('11888001')
      $order.references.contracts.'10180'.contractName | Should -Be 'CARGILL'
    }
  }
  It 'refreshes a fresh reference cache for a remapped <list> ID and then reuses it' -ForEach @(
    @{ list = 'contract'; field = 'Freight.supplierContractId'; key = 'contractSystemId'; read = 'Get-PilotContract' },
    @{ list = 'terminal'; field = 'Pickup.locationCode'; key = 'terminalId'; read = 'Get-PilotTerminal' },
    @{ list = 'location'; field = 'Delivery.locationCode'; key = 'locationSystemId'; read = 'Get-PilotLocation' }
  ) {
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $case; list = $list; field = $field; key = $key; read = $read } {
      $dir = Join-Path $TestDrive $list
      New-Item -ItemType Directory $dir | Out-Null
      $script:configuredCacheFixture = @{ location = @($c.references.locations.Values); terminal = @($c.references.terminals.Values); contract = @($c.references.contracts.Values) }
      foreach ($name in $script:configuredCacheFixture.Keys) {
        @{ read_at = [datetime]::UtcNow.ToString('o'); rows = $script:configuredCacheFixture[$name] } | ConvertTo-Json -Depth 20 | Set-Content "$dir/reference-$name.json"
      }
      $extra = $script:configuredCacheFixture[$list][0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $extra.$key = 20200
      $script:configuredCacheFixture[$list] += $extra
      $map = Read-PilotOrderMapping
      (Get-PilotMappingRow $map $field).source = 'record.referenceOverride'
      $raw = $c.record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $raw | Add-Member referenceOverride 20200
      Mock Get-PilotLocation { $script:configuredCacheFixture.location }
      Mock Get-PilotTerminal { $script:configuredCacheFixture.terminal }
      Mock Get-PilotContract { $script:configuredCacheFixture.contract }
      Mock Write-Log
      $refs = Get-PilotReferenceData ([pscustomobject]@{}) @($raw) $dir 7 $map $c.cfg
      $refs.($list + 's')['20200'].$key | Should -Be 20200
      $null = Get-PilotReferenceData ([pscustomobject]@{}) @($raw) $dir 7 $map $c.cfg
      Should -Invoke $read -Times 1 -Exactly
      foreach ($other in @('Get-PilotLocation', 'Get-PilotTerminal', 'Get-PilotContract') | Where-Object { $_ -ne $read }) { Should -Invoke $other -Times 0 -Exactly }
      $order = ConvertFrom-PilotOrder $raw $c.cfg $refs -Mapping $map
      $order.references.($list + 's')['20200'].$key | Should -Be 20200
    }
  }
  It 'refuses <name> before any Pilot read' -ForEach @(
    @{ name = 'bad regex'; old = "pattern = '\S'"; replacement = "pattern = '['" },
    @{ name = 'bad cast'; old = "cast = 'string'"; replacement = "cast = 'eval'" },
    @{ name = 'expression source'; old = "source = 'item.productCode'"; replacement = "source = 'item.productCode()'" },
    @{ name = 'credential source'; old = "source = 'item.productCode'"; replacement = "source = 'cfg.pilot.client_secret'" },
    @{ name = 'connection source'; old = "source = 'item.productCode'"; replacement = "source = 'cfg.tmw.connection_string'" },
    @{ name = 'late validation source'; old = "destination = 'productCode'; source = 'item.productCode'"; replacement = "destination = 'productCode'; source = 'terminal.name'" },
    @{ name = 'circular join source'; old = "source = 'item.looSystemId'"; replacement = "source = 'contract.contractSystemId'" },
    @{ name = 'item-dependent order identity'; old = "destination = 'pilotOrderId'; source = 'record.dispatchOrderId'"; replacement = "destination = 'pilotOrderId'; source = 'item.dispatchOrderItemId'" },
    @{ name = 'item-dependent order window'; old = "destination = 'deliveryWindowStart'; source = 'record.scheduledStartDateTime'"; replacement = "destination = 'deliveryWindowStart'; source = 'item.scheduledStartDateTime'" },
    @{ name = 'order identity override'; old = "destination = 'pilotOrderId'; source = 'record.dispatchOrderId'"; replacement = "destination = 'pilotOrderId'; source = 'record.sourceSystemOrderId'" },
    @{ name = 'item identity override'; old = "destination = 'pilotOrderItemId'; source = 'item.dispatchOrderItemId'"; replacement = "destination = 'pilotOrderItemId'; source = 'item.sourceSystemOrderItemId'" },
    @{ name = 'empty source'; old = "source = 'item.productCode'"; replacement = "source = ''" },
    @{ name = 'unknown destination'; old = "destination = 'productCode'"; replacement = "destination = 'productTypo'" },
    @{ name = 'unknown check'; old = "kind = 'positive_decimal'"; replacement = "kind = 'eval'" },
    @{ name = 'empty rejection'; old = "message = 'no dispatchOrderId'"; replacement = "message = ''" },
    @{ name = 'bad format'; old = "format = '{0} / {1}'"; replacement = "format = '{2}'" }
  ) {
    $dir = Join-Path $TestDrive $name
    New-Item -ItemType Directory $dir | Out-Null
    $text = $defaultText.Replace($old, $replacement)
    $text | Should -Not -Be $defaultText
    Set-Content "$dir/custom.psd1" -Value $text
    $cfg = $case.cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $cfg | Add-Member directory $dir
    $cfg | Add-Member order_mapping 'custom.psd1'
    InModuleScope PilotCarrierIntegration -Parameters @{ cfg = $cfg } {
      Mock Get-PilotOrder { throw 'must not read' }
      { Receive-PilotOrders $cfg ([pscustomobject]@{}) } | Should -Throw
      Should -Invoke Get-PilotOrder -Times 0 -Exactly
    }
  }
  It 'imports only data, not commands or script blocks' {
    $dir = Join-Path $TestDrive 'not-code'
    New-Item -ItemType Directory $dir | Out-Null
    foreach ($text in '@{ Order = (Get-Process) }', '@{ Order = { Get-Process } }') {
      Set-Content "$dir/custom.psd1" -Value $text
      InModuleScope PilotCarrierIntegration -Parameters @{ dir = $dir } {
        Mock Get-Process { throw 'must not execute' }
        { Read-PilotOrderMapping @{ directory = $dir; order_mapping = 'custom.psd1' } } | Should -Throw
        Should -Invoke Get-Process -Times 0 -Exactly
      }
    }
  }
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
