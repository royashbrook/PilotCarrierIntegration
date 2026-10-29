function ConvertTo-ParityJson($Value) {
  function Sort-ParityValue($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [Collections.IDictionary] -or $v -is [pscustomobject]) {
      $result = [ordered]@{}
      $names = if ($v -is [Collections.IDictionary]) { $v.Keys } else { $v.PSObject.Properties.Name }
      foreach ($name in @($names | Sort-Object)) { $result[$name] = Sort-ParityValue $v.$name }
      return $result
    }
    if ($v -is [Collections.IEnumerable] -and $v -isnot [string]) { return ,@(foreach ($item in $v) { Sort-ParityValue $item }) }
    $v
  }
  ConvertTo-Json -InputObject (Sort-ParityValue $Value) -Depth 60 -Compress
}

function Get-ParityHash($Value) {
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-ParityJson $Value))
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-MappingParityCases([string]$Fixtures) {
  foreach ($name in 'single', 'two-products', 'two-terminals', 'optional-blank', 'missing-references', 'partial-address', 'decimal-string') {
    $record = (Get-Content "$Fixtures/pilot-order.json" -Raw | ConvertFrom-Json)[0]
    $cfg = Get-Content "$Fixtures/order-settings.json" -Raw | ConvertFrom-Json
    $refs = [pscustomobject]@{
      locations = @{ '55979' = (Get-Content "$Fixtures/pilot-location.json" -Raw | ConvertFrom-Json)[0] }
      terminals = @{ '14673' = (Get-Content "$Fixtures/pilot-terminal.json" -Raw | ConvertFrom-Json)[0] }
      contracts = @{ '10180' = (Get-Content "$Fixtures/pilot-contract.json" -Raw | ConvertFrom-Json)[0] }
    }
    $record.scheduledStartDateTime = [datetime]'2026-11-02T06:00:00'
    $record.scheduledEndDateTime = [datetime]'2026-11-02T08:00:00'
    switch ($name) {
      { $_ -in 'two-products', 'two-terminals' } {
        $second = $record.dispatchOrderItems[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $second.dispatchOrderItemId = 11888002
        $second.productCode = '87'
        $second.wraProductDescription = 'REG'
        if ($name -eq 'two-terminals') { $second.lineOfOperationsSystemId = 14674 }
        $record.dispatchOrderItems = @($record.dispatchOrderItems[0], $second)
      }
      'optional-blank' { $record.dispatchOrderItems[0].lineOfOperationsSystemId = ' '; $record.dispatchOrderItems[0].looSystemId = $null }
      'missing-references' { $refs.locations.Clear(); $refs.terminals.Clear(); $refs.contracts.Clear() }
      'partial-address' { $refs.terminals.'14673'.address = ''; $refs.locations.'55979'.stateCode = ''; $refs.locations.'55979'.postalCode = '' }
      'decimal-string' { $record.dispatchOrderItems[0].gallons = '4700.25' }
    }
    [pscustomobject]@{ name = $name; record = $record; cfg = $cfg; references = $refs }
  }
}

function Measure-MappingParity([string]$Fixtures) {
  $module = Get-Module PilotCarrierIntegration
  foreach ($case in Get-MappingParityCases $Fixtures) {
    $result = & $module {
      param($c)
      $order = ConvertFrom-PilotOrder $c.record $c.cfg $c.references
      $command = New-TmwOrderCommand $order $c.cfg -Now ([datetime]'2026-11-01T12:00:00')
      [pscustomobject]@{ order = $order; archive = $command.archive; sql = $command.sql; parameters = @($command.parameters | Sort-Object name) }
    } $case
    [pscustomobject]@{ name = $case.name; order = Get-ParityHash $result.order; archive = Get-ParityHash $result.archive; sql = Get-ParityHash $result.sql; parameters = Get-ParityHash $result.parameters }
  }
}

function Measure-MappingRejections([string]$Fixtures) {
  $module = Get-Module PilotCarrierIntegration
  foreach ($name in 'identity-first', 'status-before-window', 'missing-window', 'invalid-window', 'reversed-window', 'empty-items', 'bad-quantities', 'quantity-before-required', 'item-identity-first', 'location-before-product', 'product-before-wra', 'missing-wra') {
    $c = @(Get-MappingParityCases $Fixtures)[0]
    $r = $c.record
    switch ($name) {
      'identity-first' { $r.dispatchOrderId = ''; $r.dispatchOrderStatusTypeId = 4 }
      'status-before-window' { $r.dispatchOrderStatusTypeId = 4; $r.scheduledStartDateTime = 'bad' }
      'missing-window' { $r.scheduledStartDateTime = ''; $r.scheduledEndDateTime = 'bad' }
      'invalid-window' { $r.scheduledStartDateTime = 'bad' }
      'reversed-window' { $r.scheduledEndDateTime = $r.scheduledStartDateTime.AddMinutes(-1) }
      'empty-items' { $r.dispatchOrderItems = @() }
      { $_ -in 'bad-quantities', 'quantity-before-required' } {
        $other = $r.dispatchOrderItems[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $other.dispatchOrderItemId = 11888002
        $other.gallons = 'bad'
        if ($name -eq 'bad-quantities') { $r.dispatchOrderItems[0].gallons = 0 } else { $r.dispatchOrderItems[0].productCode = '' }
        $r.dispatchOrderItems = @($r.dispatchOrderItems[0], $other)
      }
      'item-identity-first' { $r.dispatchOrderItems[0].dispatchOrderItemId = ''; $r.dispatchOrderItems[0].locationSystemId = '' }
      'location-before-product' { $r.dispatchOrderItems[0].locationSystemId = ''; $r.dispatchOrderItems[0].productCode = '' }
      'product-before-wra' { $r.dispatchOrderItems[0].productCode = ''; $r.dispatchOrderItems[0].wraProductDescription = '' }
      'missing-wra' { $r.dispatchOrderItems[0].wraProductDescription = ' ' }
    }
    [pscustomobject]@{ name = $name; reason = (& $module { param($r) Get-PilotOrderSkipReason $r } $r) }
  }
}
