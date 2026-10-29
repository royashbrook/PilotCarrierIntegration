# Bind supported SQL inputs to the existing writer, not to arbitrary generated SQL.
function Get-PilotSqlBindings {
  @{
    Order = @{
      'dx_create_order_from_stops.ord_refnum' = 'pilotOrderId'
      'dx_Archive_detail.dx_field004|SO' = 'pilotSourceOrderId'
      'dx_add_neworder_stop.earlydate' = 'deliveryWindowStart'
      'dx_add_neworder_stop.latedate' = 'deliveryWindowEnd'
      'dx_create_order_from_stops.ord_billto_cmpid,dx_create_order_from_stops.orderby_cmpid' = 'billto'
    }
    Freight = @{
      'dx_add_neworder_stop.volume,dx_add_neworder_freight_to_stop.volume' = 'quantity'
      'dx_add_neworder_stop.cmd_description,dx_add_neworder_freight_to_stop.cmd_description' = 'commodityName'
      'dx_Archive_detail.dx_field004|L06' = 'productCode'
      'dx_add_neworder_stop.fgt_refnum,dx_add_neworder_freight_to_stop.fgt_refnum' = 'pilotOrderItemId'
      'dx_add_refnumber_to_freight.fgt_refnum|SID' = 'supplierContractId'
      'dx_add_refnumber_to_freight.fgt_refnum|SUN' = 'supplierName'
    }
    Pickup = @{
      'dx_add_neworder_stop.stp_refnum' = 'locationCode'; 'stops.cmp_name' = 'name'
      'stops.stp_address' = 'address1'; 'stops.stp_address2' = 'address2'
      'stops.stp_city' = 'city'; 'stops.stp_state' = 'state'; 'stops.stp_zipcode' = 'zip'
    }
    Delivery = @{
      'dx_add_neworder_stop.stp_refnum' = 'locationCode'; 'stops.cmp_name' = 'name'
      'stops.stp_address' = 'address1'; 'stops.stp_address2' = 'address2'
      'stops.stp_city' = 'city'; 'stops.stp_state' = 'state'; 'stops.stp_zipcode' = 'zip'
    }
  }
}

function Assert-PilotJsonPath([string]$Path, [string[]]$Roots) {
  if ($Path -cnotmatch '^\$\.(order|item|create|location|terminal|contract)(?:\.|\[|$)' -or $Matches[1] -cnotin $Roots) { throw "Unavailable SQL mapping source: $Path" }
  $null = @([Newtonsoft.Json.Linq.JObject]::new().SelectTokens($Path))
}

function Read-PilotOrderMapping($Cfg) {
  $path = if ($Cfg.order_mapping) { Join-Path $Cfg.directory $Cfg.order_mapping } else { Join-Path $PSScriptRoot 'order-mapping.psd1' }
  $spec = Import-PowerShellDataFile -LiteralPath $path
  if (-not $spec.ContainsKey('SchemaVersion')) { return Read-LegacyPilotOrderMapping $Cfg }
  if ($spec.SchemaVersion -isnot [int] -or $spec.SchemaVersion -ne 2) { throw 'Unsupported SQL mapping schema version.' }
  if (@($spec.Keys | Where-Object { $_ -cnotin 'SchemaVersion', 'Validators', 'Order', 'Freight', 'Pickup', 'Delivery' }).Count) { throw 'Unsupported SQL mapping section.' }
  $map = Read-LegacyPilotOrderMapping
  $bindings = Get-PilotSqlBindings
  $rules = [Collections.Generic.List[object]]::new()
  $map.PostChecks = @()
  $map.Validation = @{ requiredItem = @() }
  foreach ($group in 'Order', 'Freight', 'Pickup', 'Delivery') {
    $seen = @()
    foreach ($row in @($spec.$group)) {
      if (@($row.Keys | Where-Object { $_ -cnotin 'src', 'dst', 'ref', 'phase', 'checks', 'cast', 'default', 'blank', 'format' }).Count) { throw 'Unsupported SQL mapping row property.' }
      $key = @($row.dst) -join ','
      if ($row.ref) { $key += "|$($row.ref)" }
      if (-not $bindings.$group.ContainsKey($key) -or $key -in $seen) { throw "Unsupported or repeated SQL destination: $group $key" }
      $seen += $key
      $field = "$group.$($bindings.$group[$key])"
      $target = Get-PilotMappingRow $map $field
      $target.group = $group
      $phase = if ($row.phase) { $row.phase } else { 'input' }
      $target.phase = $phase
      if ($phase -cnotin 'input', 'lookup') { throw "Unsupported mapping phase: $phase" }
      if ($row.ContainsKey('cast') -and ($row.cast -isnot [string] -or $row.cast -cnotin 'string', 'nullable_string', 'datetime')) { throw 'Unsupported mapping cast.' }
      $roots = if ($phase -eq 'input') { @('order', 'item', 'create') } else { @('order', 'item', 'create', 'location', 'terminal', 'contract') }
      if ($group -eq 'Order') { $roots = @('order', 'create') }
      if ($field -in 'Freight.supplierContractId', 'Pickup.locationCode', 'Delivery.locationCode' -and $phase -ne 'input') { throw 'Reference join keys must be available before lookups.' }
      if ($row.src -is [Collections.IDictionary]) {
        if ($row.src.Count -ne 1 -or -not $row.src.ContainsKey('value')) { throw 'Literal src requires only value.' }
        if ($null -ne $row.src.value -and $row.src.value -isnot [string] -and $row.src.value -isnot [ValueType]) { throw 'Literal SQL sources must be scalar.' }
      } else {
        if (-not @($row.src).Count) { throw 'Empty SQL mapping source.' }
        foreach ($source in @($row.src)) { Assert-PilotJsonPath $source $roots }
        if ($row.format) { $null = $row.format -f @($row.src) }
      }
      if ($field -eq 'Order.pilotOrderId' -and ($row.src -isnot [string] -or $row.src -cne '$.order.dispatchOrderId' -or $row.cast -cne 'string' -or $row.format -or $row.ContainsKey('default'))) { throw 'Operational order identity cannot be remapped.' }
      if ($field -eq 'Freight.pilotOrderItemId' -and ($row.src -isnot [string] -or $row.src -cne '$.item.dispatchOrderItemId' -or $row.cast -cne 'string' -or $row.format -or $row.ContainsKey('default'))) { throw 'Operational item identity cannot be remapped.' }
      foreach ($property in 'source', 'sources', 'value', 'format', 'cast', 'default', 'blank') { $target.Remove($property) }
      if ($row.src -is [Collections.IDictionary]) { $target.value = $row.src.value }
      elseif ($row.format) { $target.sources = @($row.src); $target.format = $row.format }
      else { $target.source = $row.src }
      foreach ($property in 'cast', 'default', 'blank') { if ($row.ContainsKey($property)) { $target[$property] = $row[$property] } }
      foreach ($check in @($row.checks | Where-Object { $null -ne $_ })) {
        $use = if ($check -is [string]) { $check } else { $check.use }
        if (-not $spec.Validators.ContainsKey($use)) { throw "Unknown mapping validator: $use" }
        $definition = $spec.Validators[$use]
        $allowed = switch -CaseSensitive ($definition.kind) {
          'regex' { @('kind', 'pattern', 'message') }
          'positive_decimal' { @('kind', 'message') }
          'window' { @('kind', 'missing', 'invalid', 'reversed') }
          default { throw 'Unsupported mapping validator kind.' }
        }
        if (@($definition.Keys | Where-Object { $_ -cnotin $allowed }).Count) { throw 'Unsupported reusable validator property.' }
        $rule = @{ field = $field; kind = $definition.kind; phase = $phase; group = $group }
        foreach ($property in $definition.Keys) { $rule[$property] = $definition[$property] }
        if ($check -isnot [string]) {
          if (@($check.Keys | Where-Object { $_ -cnotin 'use', 'src', 'message' }).Count) { throw 'Unsupported attached validator property.' }
          if ($check.ContainsKey('message')) { $rule.message = $check.message }
          if ($check.src) { Assert-PilotJsonPath $check.src $roots; $rule.source = $check.src }
        }
        if ($rule.kind -eq 'window') {
          if ($check -isnot [string] -and $check.Count -ne 1) { throw 'Window checks use their mapped start/end and named rejection messages.' }
          if ($field -ne 'Order.deliveryWindowStart' -or $phase -ne 'input') { throw 'Window check belongs on the scheduled start binding.' }
          foreach ($property in 'missing', 'invalid', 'reversed') { if ([string]::IsNullOrWhiteSpace([string]$rule[$property])) { throw 'Window check requires rejection messages.' } }
          if ($map.Validation.window) { throw 'Repeated scheduled window check.' }
          $map.Validation.window = @{ start = $field; end = 'Order.deliveryWindowEnd'; missing = $rule.missing; invalid = $rule.invalid; reversed = $rule.reversed }
          continue
        }
        if ($rule.kind -cnotin 'regex', 'positive_decimal') { throw 'Unsupported mapping validator kind.' }
        if ([string]::IsNullOrWhiteSpace([string]$rule.message)) { throw 'Mapping validator requires a rejection message.' }
        if ($rule.kind -eq 'regex') { $null = [regex]::new($rule.pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) }
        $rules.Add($rule)
      }
    }
    if (Compare-Object @($bindings.$group.Keys | Sort-Object) @($seen | Sort-Object) -CaseSensitive) { throw "SQL mapping $group must retain its supported destinations." }
  }
  foreach ($entry in @(@{ name = 'orderId'; field = 'Order.pilotOrderId' }, @{ name = 'quantity'; field = 'Freight.quantity' })) {
    $found = @($rules | Where-Object { $_.field -eq $entry.field -and $_.phase -eq 'input' })
    if ($found.Count -ne 1) { throw "SQL mapping requires one $($entry.name) check." }
    $map.Validation[$entry.name] = $found[0]
  }
  if (-not $map.Validation.window) { throw 'SQL mapping requires a scheduled window check.' }
  $priority = @{ 'Freight.pilotOrderItemId' = 0; 'Delivery.locationCode' = 1; 'Freight.productCode' = 2; 'Freight.commodityName' = 3 }
  $map.Validation.requiredItem = @($rules | Where-Object { $_.phase -eq 'input' -and $_.field -notin 'Order.pilotOrderId', 'Freight.quantity' } | Sort-Object { if ($priority.ContainsKey($_.field)) { $priority[$_.field] } else { 4 } })
  $map.PostChecks = @($rules | Where-Object phase -eq 'lookup')
  $map
}
