BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  . "$PSScriptRoot/MappingParity.ps1"
  $script:sqlText = Get-Content "$PSScriptRoot/../PilotCarrierIntegration/order-mapping.psd1" -Raw
  $script:sqlCase = @(Get-MappingParityCases "$PSScriptRoot/fixtures")[0]
  function New-SqlMappingConfig([string]$Text, [string]$Name) {
    $dir = Join-Path $TestDrive $Name
    $null = New-Item -ItemType Directory $dir
    Set-Content -LiteralPath "$dir/mapping.psd1" -Value $Text
    $cfg = $script:sqlCase.cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $cfg | Add-Member directory $dir
    $cfg | Add-Member order_mapping 'mapping.psd1'
    $cfg
  }
}

Describe 'physical SQL bindings with standard JSONPath selectors' {
  It 'binds a changed source to both first and additional freight procedure parameters' {
    $text = $sqlText.Replace("src = '$.item.gallons'", "src = '$.item[''test.gallons'']'")
    $text | Should -Not -Be $sqlText
    $cfg = New-SqlMappingConfig $text 'quantity'
    $c = @(Get-MappingParityCases "$PSScriptRoot/fixtures" | Where-Object name -eq 'two-products')[0]
    foreach ($item in $c.record.dispatchOrderItems) { $item | Add-Member 'test.gallons' 123.25 }
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $c; cfg = $cfg } {
      $order = ConvertFrom-PilotOrder $c.record $cfg $c.references
      $command = New-TmwOrderCommand $order $cfg -Now ([datetime]'2026-11-01T12:00:00')
      @($command.parameters | Where-Object name -like '@qty*').Count | Should -Be 4
      @($command.parameters | Where-Object { $_.name -like '@qty*' -and $_.value -ne 123.25 }).Count | Should -Be 0
    }
  }
  It 'binds a literal to the real bill-to arguments and archive' {
    $text = $sqlText.Replace("src = '$.create.billto'", "src = @{ value = 'TESTBILL' }")
    $cfg = New-SqlMappingConfig $text 'literal'
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $sqlCase; cfg = $cfg } {
      $command = New-TmwOrderCommand (ConvertFrom-PilotOrder $c.record $cfg $c.references) $cfg -Now ([datetime]'2026-11-01T12:00:00')
      @($command.parameters | Where-Object name -eq '@billto')[0].value | Should -Be 'TESTBILL'
      $command.archive.billto | Should -Be 'TESTBILL'
    }
  }
  It 'uses the configured <list> join for fresh-cache misses, enrichment and aggregation' -ForEach @(
    @{ list = 'contract'; old = "src = '$.item.looSystemId'"; key = 'contractSystemId'; read = 'Get-PilotContract' },
    @{ list = 'terminal'; old = "src = '$.item.lineOfOperationsSystemId'"; key = 'terminalId'; read = 'Get-PilotTerminal' },
    @{ list = 'location'; old = "src = '$.item.locationSystemId'"; key = 'locationSystemId'; read = 'Get-PilotLocation' }
  ) {
    $text = $sqlText.Replace($old, "src = '$.order.referenceOverride'")
    $cfg = New-SqlMappingConfig $text "join-$list"
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $sqlCase; cfg = $cfg; list = $list; key = $key; read = $read } {
      $dir = Join-Path $cfg.directory 'reference-cache'
      $null = New-Item -ItemType Directory $dir
      $script:sqlCacheRows = @{ location = @($c.references.locations.Values); terminal = @($c.references.terminals.Values); contract = @($c.references.contracts.Values) }
      foreach ($name in $script:sqlCacheRows.Keys) {
        @{ read_at = [datetime]::UtcNow.ToString('o'); rows = $script:sqlCacheRows[$name] } | ConvertTo-Json -Depth 20 | Set-Content "$dir/reference-$name.json"
      }
      $extra = $script:sqlCacheRows[$list][0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $extra.$key = 20200
      $script:sqlCacheRows[$list] += $extra
      $raw = $c.record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $raw | Add-Member referenceOverride 20200
      Mock Get-PilotLocation { $script:sqlCacheRows.location }
      Mock Get-PilotTerminal { $script:sqlCacheRows.terminal }
      Mock Get-PilotContract { $script:sqlCacheRows.contract }
      Mock Write-Log
      $map = Read-PilotOrderMapping $cfg
      $refs = Get-PilotReferenceData ([pscustomobject]@{}) @($raw) $dir 7 $map $cfg
      $null = Get-PilotReferenceData ([pscustomobject]@{}) @($raw) $dir 7 $map $cfg
      Should -Invoke $read -Times 1 -Exactly
      foreach ($other in @('Get-PilotLocation', 'Get-PilotTerminal', 'Get-PilotContract') | Where-Object { $_ -ne $read }) { Should -Invoke $other -Times 0 -Exactly }
      $order = ConvertFrom-PilotOrder $raw $cfg $refs -Mapping $map
      $order.references.($list + 's')['20200'].$key | Should -Be 20200
      if ($list -eq 'contract') { $order.contractSystemIds | Should -Be @(20200) }
    }
  }
  It 'uses a JSONPath array index and keeps ISO-looking text as text' {
    InModuleScope PilotCarrierIntegration {
      $ctx = @{ record = [pscustomobject]@{ values = @('first', '2026-01-02T03:04:05Z') } }
      $value = Get-PilotMappingSource $ctx '$.order.values[1]'
      $value | Should -BeOfType string
      $value | Should -Be '2026-01-02T03:04:05Z'
    }
  }
  It 'does not serialize the hashtable Item accessor when no item exists' {
    InModuleScope PilotCarrierIntegration {
      $WarningPreference = 'Stop'
      Get-PilotMappingSource @{ record = [pscustomobject]@{ id = 1 } } '$.order.id' | Should -Be 1
    }
  }
  It 'unwraps null, empty, false and zero before the existing fallback behavior' {
    InModuleScope PilotCarrierIntegration {
      $ctx = @{ item = [pscustomobject]@{ zero = 0; empty = ''; false = $false; nil = $null; fallback = 'next' } }
      foreach ($name in 'zero', 'empty', 'false', 'nil') {
        Get-PilotMappingValue @{ source = @("$.item.$name", '$.item.fallback') } $ctx | Should -Be 'next'
      }
      Get-PilotMappingSource $ctx '$.item.zero' | Should -Be 0
      Get-PilotMappingSource $ctx '$.item.false' | Should -BeFalse
      Get-PilotMappingSource $ctx '$.item.nil' | Should -BeNullOrEmpty
    }
  }
  It 'normalizes once for each immutable context, not once for every field' {
    InModuleScope PilotCarrierIntegration {
      $ctx = @{ item = [pscustomobject]@{ a = 1; b = 2 } }
      Get-PilotMappingSource $ctx '$.item.a' | Should -Be 1
      $tokens = $ctx['_json']
      Mock ConvertTo-PilotJsonToken { throw 'repeated normalization' }
      Get-PilotMappingSource $ctx '$.item.b' | Should -Be 2
      [object]::ReferenceEquals($tokens, $ctx['_json']) | Should -BeTrue
      Should -Invoke ConvertTo-PilotJsonToken -Times 0 -Exactly
    }
  }
  It 'preserves native UTC/local/unspecified dates, offsets, ticks and decimals' {
    InModuleScope PilotCarrierIntegration {
      foreach ($kind in [DateTimeKind]::Utc, [DateTimeKind]::Local, [DateTimeKind]::Unspecified) {
        $date = [datetime]::SpecifyKind([datetime]'2026-11-02T06:00:00.1234567', $kind)
        $value = Get-PilotMappingSource @{ record = @{ date = $date } } '$.order.date'
        $value | Should -BeOfType datetime
        $value.Ticks | Should -Be $date.Ticks
        $value.Kind | Should -Be $kind
      }
      $offset = [DateTimeOffset]'2026-11-02T06:00:00.1234567+05:30'
      $value = Get-PilotMappingSource @{ record = @{ date = $offset } } '$.order.date'
      $value | Should -BeOfType DateTimeOffset
      $value.ToString('o') | Should -Be $offset.ToString('o')
      $amount = [decimal]'1234567890.123456789'
      $value = Get-PilotMappingSource @{ item = @{ amount = $amount } } '$.item.amount'
      $value | Should -BeOfType decimal
      $value | Should -Be $amount
    }
  }
  It 'keeps native UTC scheduled windows identical to the legacy translation' {
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $sqlCase } {
      $raw = $c.record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      $raw.scheduledStartDateTime = [datetime]::SpecifyKind([datetime]'2026-11-02T06:00:00.1234567', [DateTimeKind]::Utc)
      $raw.scheduledEndDateTime = $raw.scheduledStartDateTime.AddHours(2)
      $before = ConvertFrom-PilotOrder $raw $c.cfg $c.references -Mapping (Read-LegacyPilotOrderMapping)
      $after = ConvertFrom-PilotOrder $raw $c.cfg $c.references
      $beforeCommand = New-TmwOrderCommand $before $c.cfg -Now ([datetime]'2026-11-01T12:00:00')
      $afterCommand = New-TmwOrderCommand $after $c.cfg -Now ([datetime]'2026-11-01T12:00:00')
      $after.deliveryWindowStart.ToString('o') | Should -Be $before.deliveryWindowStart.ToString('o')
      $afterCommand.sql | Should -Be $beforeCommand.sql
      foreach ($parameter in $afterCommand.parameters | Where-Object type -eq DateTime) {
        $expected = @($beforeCommand.parameters | Where-Object name -eq $parameter.name)[0].value
        $parameter.value.ToString('o') | Should -Be $expected.ToString('o')
      }
    }
  }
  It 'returns null for an absent scalar and refuses object and multiple selections' {
    InModuleScope PilotCarrierIntegration {
      $ctx = @{ item = [pscustomobject]@{ values = @(1, 2) } }
      Get-PilotMappingSource $ctx '$.item.absent' | Should -BeNullOrEmpty
      { Get-PilotMappingSource $ctx '$.item.values' } | Should -Throw '*one scalar*'
      { Get-PilotMappingSource $ctx '$.item.values[*]' } | Should -Throw
    }
  }
  It 'does not expose credentials or connection settings in the input envelope' {
    InModuleScope PilotCarrierIntegration {
      $ctx = @{ cfg = [pscustomobject]@{ create = @{ billto = 'TEST' }; pilot = @{ client_secret = 'not-a-real-secret' }; tmw = @{ connection_string = 'not-a-connection' } } }
      Get-PilotMappingSource $ctx '$.create.billto' | Should -Be 'TEST'
      Get-PilotMappingSource $ctx '$.order.client_secret' | Should -BeNullOrEmpty
    }
  }
  It 'checks a lookup ZIP before placeholders and before any SQL command is built' {
    $text = $sqlText.Replace('Validators = @{', "Validators = @{`n    zip = @{ kind = 'regex'; pattern = '^\d{5}(-\d{4})?`$'; message = 'invalid ZIP on item {0}' }")
    $text = $text.Replace("src = '$.location.postalCode'; dst = 'stops.stp_zipcode'; phase = 'lookup'", "src = '$.location.postalCode'; dst = 'stops.stp_zipcode'; phase = 'lookup'; checks = @('zip')")
    $cfg = New-SqlMappingConfig $text 'zip'
    InModuleScope PilotCarrierIntegration -Parameters @{ c = $sqlCase; cfg = $cfg } {
      $refs = $c.references | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
      $refs.locations.'55979'.postalCode = 'INVALID'
      { ConvertFrom-PilotOrder $c.record $cfg $refs } | Should -Throw 'invalid ZIP on item 11888001'
      Mock Get-PilotOrder { @($c.record) }
      Mock Get-PilotReferenceData { $refs }
      Mock New-TmwOrderCommand { throw 'must not build SQL' }
      Mock Write-Log
      @(Receive-PilotOrders $cfg ([pscustomobject]@{})).Count | Should -Be 0
      Should -Invoke New-TmwOrderCommand -Times 0 -Exactly
      Should -Invoke Get-PilotReferenceData -Times 1 -Exactly
      $refs.locations.'55979'.postalCode = '12345-6789'
      (ConvertFrom-PilotOrder $c.record $cfg $refs).stops[1].zip | Should -Be '12345-6789'
      $refs.locations.'55979'.postalCode = ''
      { ConvertFrom-PilotOrder $c.record $cfg $refs } | Should -Throw '*invalid ZIP*'
    }
  }
  It 'keeps default missing references and partial-address placeholders without a ZIP rule' {
    $cases = @(Get-MappingParityCases "$PSScriptRoot/fixtures")
    InModuleScope PilotCarrierIntegration -Parameters @{ cases = $cases } {
      $c = @($cases | Where-Object name -eq 'missing-references')[0]
      $order = ConvertFrom-PilotOrder $c.record $c.cfg $c.references
      $order.stops[1].name | Should -Be 'NO LOCATION'
      $c = @($cases | Where-Object name -eq 'partial-address')[0]
      $order = ConvertFrom-PilotOrder $c.record $c.cfg $c.references
      $order.stops[1].zip | Should -Be 'MISSING'
    }
  }
  It 'refuses <name> before a provider read' -ForEach @(
    @{ name = 'malformed JSONPath'; old = "src = '$.item.gallons'"; replacement = "src = '$.item['" },
    @{ name = 'secret root'; old = "src = '$.item.gallons'"; replacement = "src = '$.cfg.pilot.client_secret'" },
    @{ name = 'circular lookup'; old = "src = '$.item.looSystemId'"; replacement = "src = '$.contract.contractSystemId'" },
    @{ name = 'unknown physical column'; old = "dst = 'stops.stp_zipcode'"; replacement = "dst = 'stops.not_a_column'" },
    @{ name = 'at-prefixed parameter'; old = "'dx_add_neworder_stop.volume'"; replacement = "'dx_add_neworder_stop.@volume'" },
    @{ name = 'order identity array'; old = "src = '$.order.dispatchOrderId'"; replacement = "src = @('$.order.dispatchOrderId')" },
    @{ name = 'item identity array'; old = "src = '$.item.dispatchOrderItemId'"; replacement = "src = @('$.item.dispatchOrderItemId')" },
    @{ name = 'bad reusable regex'; old = "pattern = '\S'"; replacement = "pattern = '['" },
    @{ name = 'unknown attached validator'; old = "use = 'nonblank'"; replacement = "use = 'missing_validator'" },
    @{ name = 'validator context override'; old = "nonblank = @{ kind = 'regex'"; replacement = "nonblank = @{ phase = 'lookup'; kind = 'regex'" }
  ) {
    $text = $sqlText.Replace($old, $replacement)
    $text | Should -Not -Be $sqlText
    $cfg = New-SqlMappingConfig $text $name
    InModuleScope PilotCarrierIntegration -Parameters @{ cfg = $cfg } {
      Mock Get-PilotOrder { throw 'must not read' }
      { Receive-PilotOrders $cfg ([pscustomobject]@{}) } | Should -Throw
      Should -Invoke Get-PilotOrder -Times 0 -Exactly
    }
  }
}
