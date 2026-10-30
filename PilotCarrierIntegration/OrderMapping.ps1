function Get-PilotMappingRow($Mapping, [string]$Field) {
  $group, $name = $Field.Split('.', 2)
  $rows = @($Mapping.$group | Where-Object destination -eq $name)
  if ($rows.Count -ne 1) { throw "Order mapping requires exactly one $Field row." }
  $rows[0]
}

function Read-LegacyPilotOrderMapping($Cfg) {
  $default = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'order-model.psd1')
  $map = if ($Cfg.order_mapping) { Import-PowerShellDataFile -LiteralPath (Join-Path $Cfg.directory $Cfg.order_mapping) } else { $default }
  foreach ($group in 'Order', 'Freight', 'Pickup', 'Delivery') {
    if (Compare-Object @($default.$group.destination | Sort-Object) @($map.$group.destination | Sort-Object)) { throw "Order mapping $group must retain the canonical destinations." }
    $names = @()
    foreach ($row in @($map.$group)) {
      if (@($row.Keys | Where-Object { $_ -notin 'destination', 'source', 'sources', 'value', 'cast', 'default', 'blank', 'format' }).Count) { throw 'Unsupported order mapping property.' }
      if ($row.destination -notmatch '^\w+$' -or $row.destination -in $names) { throw "Invalid or repeated $group mapping destination." }
      $names += $row.destination
      if (@('source', 'sources', 'value' | Where-Object { $row.ContainsKey($_) }).Count -ne 1) { throw "Mapping $group.$($row.destination) needs one source, sources, or value." }
      if ($row.cast -and $row.cast -notin 'string', 'nullable_string', 'datetime') { throw "Unsupported order mapping cast '$($row.cast)'." }
      $sources = if ($row.ContainsKey('source')) { @($row.source) } elseif ($row.ContainsKey('sources')) { @($row.sources) } else { @() }
      if (($row.ContainsKey('source') -or $row.ContainsKey('sources')) -and -not $sources.Count) { throw 'Empty mapping source.' }
      foreach ($source in $sources) {
        if ($source -isnot [string] -or $source -notmatch '^(?:(record|item|terminal|location|contract|context)(\.\w+)*|cfg\.create\.\w+)$') { throw "Invalid mapping source '$source'." }
      }
      if ($row.sources) {
        if ($row.format -isnot [string] -or -not $row.format) { throw 'Mapping sources require a format.' }
        $null = $row.format -f @($row.sources)
      }
    }
  }
  foreach ($field in 'Order.pilotOrderId', 'Freight.pilotOrderItemId') {
    $expected = Get-PilotMappingRow $default $field
    $actual = Get-PilotMappingRow $map $field
    if ($actual.Count -ne $expected.Count -or @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) -or $actual[$_] -cne $expected[$_] }).Count) { throw "Operational identity $field cannot be remapped." }
  }
  foreach ($rule in @($map.Validation.orderId, $map.Validation.quantity) + @($map.Validation.requiredItem)) {
    $row = Get-PilotMappingRow $map $rule.field
    if ($rule.ContainsKey('part') -and ($rule.part -isnot [int] -or $rule.part -lt 0 -or $rule.part -ge @($row.sources).Count)) { throw 'Invalid mapping validation part.' }
    if ($rule.kind -notin 'regex', 'positive_decimal') { throw "Unsupported mapping check '$($rule.kind)'." }
    if ([string]::IsNullOrWhiteSpace([string]$rule.message)) { throw 'Mapping checks require a nonblank rejection message.' }
    if ($rule.kind -eq 'regex') { $null = [regex]::new($rule.pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) }
  }
  $null = Get-PilotMappingRow $map $map.Validation.window.start
  $null = Get-PilotMappingRow $map $map.Validation.window.end
  foreach ($name in 'missing', 'invalid', 'reversed') {
    if ([string]::IsNullOrWhiteSpace([string]$map.Validation.window[$name])) { throw 'Mapping window checks require nonblank rejection messages.' }
  }
  $early = @($map.Validation.orderId, @{ field = $map.Validation.window.start }, @{ field = $map.Validation.window.end })
  $joins = @(@{ field = 'Freight.supplierContractId' }, @{ field = 'Pickup.locationCode' }, @{ field = 'Delivery.locationCode' })
  foreach ($rule in $early + $joins + @($map.Validation.quantity) + @($map.Validation.requiredItem)) {
    $row = Get-PilotMappingRow $map $rule.field
    $sources = if ($rule.ContainsKey('part')) { @($row.sources[$rule.part]) } else { @($row.source) + @($row.sources) }
    foreach ($source in $sources) {
      if (-not $source) { continue }
      if ($source -notmatch '^(record(\.\w+)*|item(\.\w+)*|cfg\.create\.\w+)$' -or ($rule -in $early -and $source -match '^item(\.|$)')) { throw 'Pre-lookup checks require order/item/create data, not enriched or derived sources.' }
    }
  }
  $map
}

function Get-PilotMappingSource($Context, [string]$Path, [string]$Phase = 'input', [string]$Group = 'Item') {
  $native = $Path.StartsWith('$')
  if ($native) {
    $value = @{ order = $Context['record']; create = $Context['cfg'].create }
    if ($Group -ne 'Order') {
      $value.item = $Context['item']
      if ($Phase -eq 'lookup') {
        $value.terminal = $Context['terminal']; $value.location = $Context['location']; $value.contract = $Context['contract']
      }
    }
    $Path = $Path.Substring(1)
  } else { $value = $Context }
  foreach ($part in $Path.Split('.')) {
    if ($value -is [Collections.IDictionary]) { $value = $value[$part] }
    else { $value = $value.$part }
  }
  if ($native -and $null -ne $value -and $value -isnot [string] -and $value -isnot [ValueType]) { throw "SQL mapping source must select one scalar: $Path" }
  return ,$value
}

function Get-PilotMappingValue($Row, $Context, [switch]$Raw) {
  if ($Row.ContainsKey('value')) { $value = $Row.value }
  elseif ($Row.sources) {
    $values = @(foreach ($source in $Row.sources) { ,(Get-PilotMappingSource $Context $source $Row.phase $Row.group) })
    $value = $Row.format -f $values
  } else {
    foreach ($source in @($Row.source)) {
      $value = Get-PilotMappingSource $Context $source $Row.phase $Row.group
      if ($value) { break }
    }
  }
  if ($Raw) { return ,$value }
  if ($Row.ContainsKey('default') -and $(if ($Row.blank) { [string]::IsNullOrWhiteSpace([string]$value) } else { -not $value })) { $value = $Row.default }
  switch ($Row.cast) {
    'string' { $value = [string]$value }
    'nullable_string' { $value = if ($value) { [string]$value } else { $null } }
    'datetime' { $value = [datetime]$value }
  }
  return ,$value
}

function Get-PilotCheckValue($Mapping, $Rule, $Context) {
  if ($Rule.source) { return ,(Get-PilotMappingSource $Context $Rule.source $Rule.phase $Rule.group) }
  $row = Get-PilotMappingRow $Mapping $Rule.field
  if ($Rule.ContainsKey('part')) { return ,(Get-PilotMappingSource $Context $row.sources[$Rule.part] $row.phase $row.group) }
  Get-PilotMappingValue $row $Context -Raw
}

function Test-PilotMappingValue($Value, $Rule) {
  switch ($Rule.kind) {
    'regex' { return [regex]::IsMatch([string]$Value, $Rule.pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) }
    'positive_decimal' {
      $number = 0d
      return [decimal]::TryParse([string]$Value, [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::AllowThousands, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -gt 0
    }
  }
}

function ConvertTo-PilotMappedObject($Rows, $Context) {
  $fields = [ordered]@{}
  foreach ($row in $Rows) { $fields[$row.destination] = Get-PilotMappingValue $row $Context }
  [pscustomobject]$fields
}
