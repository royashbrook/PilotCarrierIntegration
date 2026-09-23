# Pilot orders: read Pilot carrier orders, translate them, and stage each in TMW DataExchange at EDI state 10.

function New-PilotReferenceIndex {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Records, [Parameter(Mandatory)][string]$Key)
  $index = @{}
  foreach ($record in @($Records)) {
    $value = $record.$Key
    if ($null -eq $value -or [string]$value -eq '') { continue }
    $id = [string]$value
    if ($index.ContainsKey($id)) { throw "Pilot reference endpoint returned duplicate $Key $id." }
    $index[$id] = $record
  }
  $index
}

function Get-PilotReferenceData {
  param($Session)
  $locations = @(Get-PilotLocation -Session $Session)
  $terminals = @(Get-PilotTerminal -Session $Session)
  $contracts = @(Get-PilotContract -Session $Session)

  [pscustomobject]@{
    locations = New-PilotReferenceIndex @($locations) 'locationSystemId'
    terminals = New-PilotReferenceIndex @($terminals) 'terminalId'
    contracts = New-PilotReferenceIndex @($contracts) 'contractSystemId'
  }
}

function Assert-PilotAddress {
  param([Parameter(Mandatory)]$Address, [string]$Description)
  foreach ($field in @('address1', 'city', 'state', 'zip')) {
    if ([string]::IsNullOrWhiteSpace([string]$Address.$field)) {
      throw "$Description has no $field in Pilot reference data."
    }
  }
}

function ConvertFrom-PilotOrder {
  param(
    [Parameter(Mandatory)]$Record,
    $Cfg,
    [Parameter(Mandatory)]$References
  )

  if (-not $Record.dispatchOrderId) {
    throw 'Pilot order record has no dispatchOrderId.'
  }

  $items = @($Record.dispatchOrderItems | Where-Object { -not $_.isDeleted })
  if (-not $items.Count) {
    throw "Pilot order $($Record.dispatchOrderId) has no active dispatchOrderItems."
  }
  if (-not $Record.deliveryWindowStartDateTime -or -not $Record.deliveryWindowEndDateTime) {
    throw "Pilot order $($Record.dispatchOrderId) has no complete delivery window."
  }
  $deliveryWindowStart = [datetime]$Record.deliveryWindowStartDateTime
  $deliveryWindowEnd = [datetime]$Record.deliveryWindowEndDateTime
  if ($deliveryWindowEnd -le $deliveryWindowStart) {
    throw "Pilot order $($Record.dispatchOrderId) delivery window must end after it starts."
  }

  $stopsByKey = [ordered]@{}
  foreach ($item in $items) {
    $terminalId = $item.lineOfOperationsSystemId
    $locationId = if ($null -ne $item.locationSystemId) {
      $item.locationSystemId
    } else {
      $item.customerLocationSystemId
    }
    if ($null -eq $locationId) {
      throw "Pilot order $($Record.dispatchOrderId) item $($item.dispatchOrderItemId) has no delivery-location identifier."
    }
    if ($null -eq $item.dispatchOrderItemId) {
      throw "Pilot order $($Record.dispatchOrderId) has an item with no dispatchOrderItemId."
    }
    if ($null -eq $item.gallons -or [decimal]$item.gallons -le 0) {
      throw "Pilot order $($Record.dispatchOrderId) item $($item.dispatchOrderItemId) has no positive gallon quantity."
    }
    if ($null -eq $item.productSystemId -and $null -eq $item.wraProductSystemId) {
      throw "Pilot order $($Record.dispatchOrderId) item $($item.dispatchOrderItemId) has no product identifier."
    }

    # Pilot's reference data only fills in names and addresses; TMW maps each stop by its id.
    # A missing id stages as UNKNOWN, an id their reference data lacks keeps the id, and either
    # way the stop comes over with no address for ops to finish in EDI.
    $terminal = if ($null -ne $terminalId) { $References.terminals[[string]$terminalId] }
    $location = $References.locations[[string]$locationId]
    $contract = if ($null -ne $item.looSystemId) { $References.contracts[[string]$item.looSystemId] }
    $supplierName = if ($contract.contractName) {
      [string]$contract.contractName
    } else {
      'NO SUPPLIER'
    }
    $supplierDescription = if ($contract.contractDescription) {
      [string]$contract.contractDescription
    } else {
      $supplierName
    }
    $terminalAddress = if ($terminal) {
      [pscustomobject]@{
        address1 = $terminal.address
        address2 = $terminal.address2
        city = $terminal.city
        state = if ($terminal.stateSystemCode) { $terminal.stateSystemCode } else { $terminal.state }
        zip = $terminal.postalCode
      }
    } else {
      [pscustomobject]@{ address1 = $null; address2 = $null; city = $null; state = $null; zip = $null }
    }
    $locationAddress = if ($location) {
      [pscustomobject]@{
        address1 = $location.address1
        address2 = $location.address2
        city = $location.city
        state = $location.stateCode
        zip = $location.postalCode
      }
    } else {
      [pscustomobject]@{ address1 = $null; address2 = $null; city = $null; state = $null; zip = $null }
    }
    if ($terminal) { Assert-PilotAddress $terminalAddress "Pilot terminal $terminalId" }
    if ($location) { Assert-PilotAddress $locationAddress "Pilot location $locationId" }

    $commodityName = if ($item.productName) {
      $item.productName
    } elseif ($item.wraProductDescription) {
      $item.wraProductDescription
    } elseif ($item.wraProductLongName) {
      $item.wraProductLongName
    } else {
      'NO PRODUCT'
    }
    $productCode = if ($item.productCode) {
      $item.productCode
    } elseif ($item.wraProductId) {
      [string]$item.wraProductId
    } else {
      [string]$item.wraProductSystemId
    }
    $freight = [pscustomobject]@{
      freightNumber = $null
      uom = 'GAL'
      quantity = $item.gallons
      weight = 0
      commodityName = $commodityName
      commodityCode = $productCode
      productCode = $productCode
      pilotOrderItemId = [string]$item.dispatchOrderItemId
      pilotSourceItemId = [string]$item.sourceSystemOrderItemId
      supplierContractId = if ($null -ne $item.looSystemId) { [string]$item.looSystemId } else { 'UNKNOWN' }
      supplierName = $supplierName
      supplierDescription = $supplierDescription
      productSystemId = if ($null -ne $item.productSystemId) {
        $item.productSystemId
      } else {
        $item.wraProductSystemId
      }
    }

    foreach ($stopSpec in @(
      [pscustomobject]@{
        type = 'PU'
        locationCode = if ($null -ne $terminalId) { [string]$terminalId } else { 'UNKNOWN' }
        name = if ($terminal.name) { $terminal.name } else { 'NO TERMINAL' }
        address = $terminalAddress
      }
      [pscustomobject]@{
        type = 'DR'
        locationCode = [string]$locationId
        name = if ($location.description) { $location.description } else { 'NO LOCATION' }
        address = $locationAddress
      }
    )) {
      $key = '{0}|{1}|{2}|{3}' -f $stopSpec.type, $stopSpec.locationCode,
        $deliveryWindowStart, $deliveryWindowEnd
      if (-not $stopsByKey.Contains($key)) {
        $stopsByKey[$key] = [pscustomobject]@{
          stopNumber = $null
          type = $stopSpec.type
          locationCode = $stopSpec.locationCode
          name = $stopSpec.name
          address1 = $stopSpec.address.address1
          address2 = $stopSpec.address.address2
          city = $stopSpec.address.city
          state = $stopSpec.address.state
          zip = $stopSpec.address.zip
          earliest = $deliveryWindowStart
          latest = $deliveryWindowEnd
          freight = [System.Collections.Generic.List[object]]::new()
        }
      }
      $stopsByKey[$key].freight.Add($freight)
    }
  }

  $contractIds = @(
    $items.looSystemId |
      Where-Object { $null -ne $_ } |
      Sort-Object -Unique
  )
  $orderedStops = @($stopsByKey.Values | Where-Object type -eq 'PU') +
    @($stopsByKey.Values | Where-Object type -eq 'DR')

  [pscustomobject]@{
    pilotOrderId = [string]$Record.dispatchOrderId
    pilotGuid = $Record.dispatchOrderGuid
    pilotSourceOrderId = [string]$Record.sourceSystemOrderId
    pilotOrderItemIds = @($items.dispatchOrderItemId | ForEach-Object { [string]$_ })
    contractSystemIds = $contractIds
    deliveryWindowStart = $deliveryWindowStart
    deliveryWindowEnd = $deliveryWindowEnd
    billto = if ($Cfg.create.billto) { [string]$Cfg.create.billto } else { $null }
    bolNumber = $Record.bolNumber
    kiosked = [bool]$Record.kiosked -or [int]$Record.dispatchOrderStatusTypeId -eq 4
    stops = $orderedStops
    raw = $Record
  }
}

function Select-PilotOrdersToProcess {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Records, $Cfg)

  $field = $Cfg.poll.status_field
  $skip = @($Cfg.poll.skip_values)
  @($Records) | Where-Object {
    if (-not $_.dispatchOrderId) { return $false }
    if ($null -ne $_.kiosked -and [bool]$_.kiosked) { return $false }
    if ($field -and $skip.Count) { return ($skip -notcontains $_.$field) }
    $true
  }
}

function Receive-PilotOrders {
  param($Cfg, $Session, [int]$WindowDays = 0)

  if (-not $WindowDays) {
    $WindowDays = if ($Cfg.poll.window_days) { [int]$Cfg.poll.window_days } else { 30 }
  }
  if ($WindowDays -lt 2) {
    throw "A $WindowDays-day Pilot window can drop loads that cross the boundary. Use 2 or more."
  }

  $start = [datetime]::Today
  $records = Get-PilotOrder -Session $Session -StartDate $start -EndDate $start.AddDays($WindowDays)
  $references = Get-PilotReferenceData $Session

  foreach ($record in @(Select-PilotOrdersToProcess $records -Cfg $Cfg)) {
    try {
      ConvertFrom-PilotOrder $record -Cfg $Cfg -References $references
    } catch {
      Write-Warning "Pilot order $($record.dispatchOrderId) deferred: $($_.Exception.Message)"
    }
  }
}

# Create one Pilot order in TMW and place it in the DataExchange accept queue.
#
# One order is one transaction: acquire its idempotency lock, build through TMW's dx_* procedures,
# insert the matching DX archive, and commit only after the order is EDI/PILOT/state 10. No flat file,
# no alternate delivery method, and no custom object in the vendor database.

$script:EdiVersion = '39'
$script:OrderNumberToken = '__TMW_ORDER_NUMBER__'
$script:SlotWidth = @{
  '02' = @{ 1 = 2; 2 = 2; 3 = 14; 4 = 1; 5 = 20; 6 = 12; 7 = 12; 8 = 12; 9 = 2 }
  '03' = @{ 1 = 2; 2 = 2; 3 = 2; 4 = 12; 5 = 12; 6 = 12 }
  '04' = @{ 1 = 2; 2 = 2; 3 = 6; 4 = 10; 13 = 50; 14 = 8 }
  '05' = @{ 1 = 2; 2 = 2; 3 = 3; 4 = 80 }
  '06' = @{ 1 = 2; 2 = 2; 3 = 2; 4 = 35; 5 = 35; 6 = 35; 7 = 20; 8 = 2; 9 = 9 }
}

function Get-TmwValue {
  param($Cfg, [string]$Section, [string]$Name, $Default)
  $group = if ($null -ne $Cfg) {
    $property = $Cfg.PSObject.Properties[$Section]
    if ($property) { $property.Value }
  }
  if ($null -ne $group) {
    $property = $group.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value -and [string]$property.Value -ne '') {
      return $property.Value
    }
  }
  $Default
}

function Format-DxText {
  param([string]$RecordType, [int]$Slot, $Value)
  $width = $script:SlotWidth[$RecordType][$Slot]
  if (-not $width) { throw "No DX width for record $RecordType slot $Slot." }
  if ([string]$Value -eq $script:OrderNumberToken) { return $script:OrderNumberToken }
  $text = if ($null -eq $Value) { '' } else { [string]$Value }
  if ($text -match '[^\x20-\x7E]') { throw "DX record $RecordType slot $Slot contains non-ASCII text." }
  if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
  $text.PadRight($width)
}

function Format-DxDate {
  param($Value)
  if (-not $Value) { return '' }
  ([datetime]$Value).ToString('yyyyMMddHHmm')
}

function Format-DxImpliedDecimal {
  param([decimal]$Value, [int]$Width = 10)
  if ($Value -lt 0) { throw 'DX quantity cannot be negative.' }
  $scaled = $Value * 100
  if ($scaled -ne [decimal]::Truncate($scaled)) { throw 'DX quantity supports at most two decimal places.' }
  $text = $scaled.ToString('0', [Globalization.CultureInfo]::InvariantCulture)
  if ($text.Length -gt $Width) { throw "DX quantity exceeds its $Width-digit field." }
  $text.PadLeft($Width, '0')
}

function Get-DxArchiveFingerprint {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows)

  $lines = foreach ($row in @($Rows | Sort-Object sequence)) {
    $recordType = ([string]$row.fields.dx_field001).Trim()
    $fields = foreach ($name in @($row.fields.Keys | Sort-Object)) {
      # Source time identifies the intake attempt, not the customer's business payload.
      if (-not ($recordType -eq '02' -and $name -eq 'dx_field006')) {
        '{0}={1}' -f $name, [string]$row.fields[$name]
      }
    }
    '{0}|{1}|{2}|{3}' -f $row.sequence, $row.stopIndex, $row.freightIndex, ($fields -join '|')
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-DxDetailRow {
  param(
    [string]$RecordType,
    [hashtable]$Slots = @{},
    [int]$StopIndex = 0,
    [int]$FreightIndex = 0
  )
  $fields = [ordered]@{
    dx_field001 = Format-DxText $RecordType 1 $RecordType
    dx_field002 = Format-DxText $RecordType 2 $script:EdiVersion
  }
  foreach ($slot in $Slots.Keys) {
    $fields[('dx_field{0:D3}' -f [int]$slot)] = Format-DxText $RecordType ([int]$slot) $Slots[$slot]
  }
  [pscustomobject]@{
    sequence = 0
    stopIndex = $StopIndex
    freightIndex = $FreightIndex
    fields = $fields
  }
}

function Assert-TmwOrder {
  param([Parameter(Mandatory)]$PilotOrder, $Cfg)
  $partner = [string](Get-TmwValue $Cfg 'create' 'partner' 'PILOT')
  $billto = if ($PilotOrder.billto) { [string]$PilotOrder.billto } else {
    [string](Get-TmwValue $Cfg 'create' 'billto' '')
  }
  $id = [string]$PilotOrder.pilotOrderId
  $stops = @($PilotOrder.stops)
  if (-not $id -or $id.Length -gt 30) { throw 'Pilot order ID is required and must fit TMW varchar(30).' }
  if (-not $billto -or $billto.Length -gt 8) { throw 'TMW bill-to is required and must fit varchar(8).' }
  if (-not $partner -or $partner.Length -gt 20) { throw 'TMW trading partner is required and must fit varchar(20).' }
  if ($stops.Count -lt 2) { throw "Pilot order $id requires at least two stops." }
  foreach ($stop in $stops) {
    if ($stop.type -notin @('PU', 'DR')) { throw "Pilot order $id has unsupported stop type '$($stop.type)'." }
    if (-not $stop.locationCode -or ([string]$stop.locationCode).Length -gt 8) {
      throw "Pilot order $id stop location '$($stop.locationCode)' must fit TMW varchar(8)."
    }
    if (-not $stop.earliest -or -not $stop.latest) { throw "Pilot order $id has an incomplete stop window." }
    # a stop with no address at all is for ops to finish in EDI; a partial one is bad data
    foreach ($field in @('address1', 'city', 'state', 'zip')) {
      if (($stop.address1 -or $stop.city -or $stop.state -or $stop.zip) -and [string]::IsNullOrWhiteSpace([string]$stop.$field)) {
        throw "Pilot order $id stop '$($stop.locationCode)' has no $field."
      }
    }
    foreach ($field in @(
      @{ name = 'name'; width = 100 }
      @{ name = 'address1'; width = 40 }
      @{ name = 'address2'; width = 40 }
      @{ name = 'city'; width = 18 }
      @{ name = 'state'; width = 6 }
      @{ name = 'zip'; width = 10 }
    )) {
      if ([string]$stop.($field.name) -and ([string]$stop.($field.name)).Length -gt $field.width) {
        throw "Pilot order $id stop $($field.name) must fit TMW varchar($($field.width))."
      }
    }
    if (@($stop.freight).Count -eq 0) { throw "Pilot order $id stop '$($stop.locationCode)' has no freight." }
    foreach ($freight in @($stop.freight)) {
      if ($null -eq $freight.quantity -or [decimal]$freight.quantity -le 0) {
        throw "Pilot order $id has a non-positive freight quantity."
      }
      if (-not $freight.commodityName) { throw "Pilot order $id has freight without a commodity name." }
      if ([string]$freight.commodityName -and ([string]$freight.commodityName).Length -gt 60) {
        throw "Pilot order $id commodity description must fit TMW varchar(60)."
      }
      if ([string]$freight.pilotOrderItemId -and ([string]$freight.pilotOrderItemId).Length -gt 30) {
        throw "Pilot order $id item ID must fit TMW varchar(30)."
      }
      if (-not $freight.supplierContractId) { throw "Pilot order $id has freight without a supplier contract ID." }
      if (-not $freight.supplierName) { throw "Pilot order $id has freight without a supplier name." }
    }
  }
}

function New-DxArchivePlan {
  param([Parameter(Mandatory)]$PilotOrder, $Cfg, [datetime]$Now = (Get-Date))
  Assert-TmwOrder $PilotOrder $Cfg
  $partner = [string](Get-TmwValue $Cfg 'create' 'partner' 'PILOT')
  $division = [string](Get-TmwValue $Cfg 'create' 'division' '')
  $scac = [string](Get-TmwValue $Cfg 'create' 'scac' '')
  $billto = if ($PilotOrder.billto) { [string]$PilotOrder.billto } else {
    [string](Get-TmwValue $Cfg 'create' 'billto' '')
  }
  $id = [string]$PilotOrder.pilotOrderId
  if (-not $division -or $division.Length -gt 6) { throw 'TMW division is required and must fit varchar(6).' }
  if (-not $scac -or $scac.Length -gt 8) { throw 'TMW SCAC is required and must fit varchar(8).' }
  $stops = @($PilotOrder.stops)
  $firstDate = ($stops | ForEach-Object { [datetime]$_.earliest } | Measure-Object -Minimum).Minimum
  $lastDate = ($stops | ForEach-Object { [datetime]$_.latest } | Measure-Object -Maximum).Maximum
  $rows = [System.Collections.Generic.List[object]]::new()

  $rows.Add((New-DxDetailRow '02' @{
    3 = $partner; 4 = 'N'; 5 = $script:OrderNumberToken
    6 = (Format-DxDate $Now); 7 = (Format-DxDate $firstDate); 8 = (Format-DxDate $lastDate); 9 = 'PP'
  }))
  foreach ($ref in @(
    @{ type = 'EDI'; value = 'YES' }
    @{ type = 'SCA'; value = $scac }
    @{ type = '_R1'; value = $division }
    @{ type = 'PO'; value = $id }
    @{ type = 'PO'; value = $script:OrderNumberToken }
    @{ type = 'SO'; value = $PilotOrder.pilotSourceOrderId }
  )) {
    if ($ref.value) { $rows.Add((New-DxDetailRow '05' @{ 3 = $ref.type; 4 = $ref.value })) }
  }
  $supplierNames = @(
    $stops |
      Where-Object type -eq 'PU' |
      ForEach-Object { $_.freight } |
      ForEach-Object { $_.supplierName } |
      Sort-Object -Unique
  )
  foreach ($supplierName in $supplierNames) {
    $rows.Add((New-DxDetailRow '05' @{ 3 = 'SUP'; 4 = $supplierName }))
    $rows.Add((New-DxDetailRow '06' @{ 3 = 'SU'; 4 = $supplierName }))
  }
  $rows.Add((New-DxDetailRow '06' @{ 3 = 'BT'; 4 = $billto }))

  for ($stopIndex = 1; $stopIndex -le $stops.Count; $stopIndex++) {
    $stop = $stops[$stopIndex - 1]
    $rows.Add((New-DxDetailRow '03' @{
      3 = $stop.type
      4 = (Format-DxDate $stop.earliest)
      5 = (Format-DxDate $stop.earliest)
      6 = (Format-DxDate $stop.latest)
    } $stopIndex))
    foreach ($ref in @(
      @{ type = 'ST#'; value = $stop.locationCode }
      @{ type = 'LOC'; value = $stop.locationCode }
      @{ type = 'PO'; value = $id }
    )) {
      $rows.Add((New-DxDetailRow '05' @{ 3 = $ref.type; 4 = $ref.value } $stopIndex))
    }
    $freight = @($stop.freight)
    for ($freightIndex = 1; $freightIndex -le $freight.Count; $freightIndex++) {
      $item = $freight[$freightIndex - 1]
      $rows.Add((New-DxDetailRow '04' @{
        3 = 'GAL'
        4 = (Format-DxImpliedDecimal ([decimal]$item.quantity))
        13 = $item.commodityName
        14 = ''
      } $stopIndex $freightIndex))
      if ($item.productCode) {
        $rows.Add((New-DxDetailRow '05' @{ 3 = 'L06'; 4 = $item.productCode } $stopIndex $freightIndex))
      }
      if ($item.pilotOrderItemId) {
        $rows.Add((New-DxDetailRow '05' @{ 3 = 'OID'; 4 = $item.pilotOrderItemId } $stopIndex $freightIndex))
        $rows.Add((New-DxDetailRow '05' @{ 3 = 'PO'; 4 = $item.pilotOrderItemId } $stopIndex $freightIndex))
      }
      if ($stop.type -eq 'PU') {
        $rows.Add((New-DxDetailRow '05' @{ 3 = 'SID'; 4 = $item.supplierContractId } $stopIndex $freightIndex))
        $rows.Add((New-DxDetailRow '05' @{ 3 = 'SUN'; 4 = $item.supplierName } $stopIndex $freightIndex))
      }
    }
    $rows.Add((New-DxDetailRow '06' @{
      3 = 'ST'; 4 = $stop.name; 5 = $stop.address1; 6 = $stop.address2
      7 = $stop.city; 8 = $stop.state; 9 = $stop.zip
    } $stopIndex))
  }

  $sequence = 0
  foreach ($row in $rows) { $sequence++; $row.sequence = $sequence }
  $sourcePrefix = "PILOTAPI.$id"
  $fingerprint = Get-DxArchiveFingerprint $rows.ToArray()
  [pscustomobject]@{
    sourceName = "$sourcePrefix.$fingerprint"
    sourcePrefix = $sourcePrefix
    fingerprint = $fingerprint
    sourceDate = $Now
    partner = $partner
    billto = $billto
    division = $division
    scac = $scac
    rows = $rows.ToArray()
  }
}

function New-TmwParameter {
  param([string]$Name, [string]$Type, [int]$Size, $Value)
  [pscustomobject]@{ name = $Name; type = $Type; size = $Size; value = $Value }
}

function New-TmwOrderCommand {
  param([Parameter(Mandatory)]$PilotOrder, $Cfg, [switch]$Commit, [datetime]$Now = (Get-Date))
  Assert-TmwOrder $PilotOrder $Cfg
  $plan = New-DxArchivePlan $PilotOrder $Cfg $Now
  $id = [string]$PilotOrder.pilotOrderId
  $deliveryStart = [datetime]$PilotOrder.deliveryWindowStart
  $deliveryEnd = [datetime]$PilotOrder.deliveryWindowEnd
  $remark = 'PO: {0} WINDOW: {1:HHmm}-{2:HHmm}' -f $id, $deliveryStart, $deliveryEnd
  if ($remark.Length -gt 254) { throw "Pilot order $id remark must fit TMW varchar(254)." }
  $expectedDatabase = [string](Get-TmwValue $Cfg 'tmw' 'expected_database' '')
  if (-not $expectedDatabase) { throw 'tmw.expected_database is required.' }

  $parameters = [System.Collections.Generic.List[object]]::new()
  foreach ($p in @(
    (New-TmwParameter '@expected_database' 'VarChar' 128 $expectedDatabase)
    (New-TmwParameter '@pilot_id' 'VarChar' 30 $id)
    (New-TmwParameter '@partner' 'VarChar' 20 $plan.partner)
    (New-TmwParameter '@billto' 'VarChar' 8 $plan.billto)
    (New-TmwParameter '@division' 'VarChar' 6 $plan.division)
    (New-TmwParameter '@scac' 'VarChar' 8 $plan.scac)
    (New-TmwParameter '@supplier' 'VarChar' 8 'UNKNOWN')
    (New-TmwParameter '@source_prefix' 'VarChar' 80 $plan.sourcePrefix)
    (New-TmwParameter '@source_name' 'VarChar' 255 $plan.sourceName)
    (New-TmwParameter '@fingerprint' 'VarChar' 64 $plan.fingerprint)
    (New-TmwParameter '@source_date' 'DateTime' 0 $plan.sourceDate)
    (New-TmwParameter '@commit' 'Bit' 0 ([bool]$Commit))
    (New-TmwParameter '@remark' 'VarChar' 254 $remark)
  )) { [void]$parameters.Add($p) }

  $sql = [System.Collections.Generic.List[string]]::new()
  $sql.AddRange([string[]]@(
    'set transaction isolation level read committed;'
    'set deadlock_priority -5;'
    'set nocount on;'
    'set xact_abort on;'
    "if db_name() <> @expected_database throw 50001, 'Pilot order target database mismatch', 1;"
    "if (select count(1) from dbo.edi_tender_partner where etp_partnerId = @partner) <> 1 throw 50002, 'PILOT tender partner is not exact', 1;"
    "if (select count(1) from dbo.edi_trading_partner where trp_id = @partner and cmp_id = @billto) <> 1 throw 50003, 'PILOT trading partner is not exact', 1;"
    "if (select count(1) from dbo.dx_xref where dx_importid = 'dx_204' and dx_trpid = @partner and dx_entitytype = 'TPSettings') <> 39 throw 50004, 'PILOT TPSettings are not exact', 1;"
    "if (select count(1) from dbo.company where cmp_id = 'UNKNOWN') <> 1 throw 50007, 'TMW UNKNOWN company is not exact', 1;"
    "if (select count(1) from dbo.commodity where cmd_code = 'UNKNOWN') <> 1 throw 50008, 'TMW UNKNOWN commodity is not exact', 1;"
    'begin try'
    '  begin transaction;'
    "  declare @lock_result int, @lock_resource nvarchar(255) = 'pilot-order:' + @pilot_id; exec @lock_result = sys.sp_getapplock @Resource = @lock_resource, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;"
    "  if @lock_result < 0 throw 50005, 'could not acquire Pilot order lock', 1;"
    '  declare @existing_hdr int = null, @existing_archive bigint = null, @existing_source_name varchar(255) = null;'
    "  declare @existing_order_count int = (select count(distinct o.ord_hdrnumber) from dbo.orderheader o where o.ord_editradingpartner = @partner and (exists (select 1 from dbo.referencenumber r where r.ref_tablekey = o.ord_hdrnumber and r.ref_table = 'orderheader' and r.ref_type = 'PO' and r.ref_number = @pilot_id) or (o.ord_reftype = 'PO' and o.ord_refnum = @pilot_id)));"
    "  if @existing_order_count > 1 throw 50016, 'duplicate TMW orders exist for Pilot order ID', 1;"
    "  select top (1) @existing_hdr = o.ord_hdrnumber from dbo.orderheader o where o.ord_editradingpartner = @partner and (exists (select 1 from dbo.referencenumber r where r.ref_tablekey = o.ord_hdrnumber and r.ref_table = 'orderheader' and r.ref_type = 'PO' and r.ref_number = @pilot_id) or (o.ord_reftype = 'PO' and o.ord_refnum = @pilot_id));"
    "  declare @existing_archive_count int = (select count(1) from dbo.dx_Archive_header where dx_importid = 'dx_204' and dx_trpid = @partner and (dx_sourcename = @source_prefix or left(dx_sourcename, len(@source_prefix) + 1) = @source_prefix + '.'));"
    "  select top (1) @existing_archive = dx_Archive_header_id, @existing_source_name = dx_sourcename from dbo.dx_Archive_header where dx_importid = 'dx_204' and dx_trpid = @partner and (dx_sourcename = @source_prefix or left(dx_sourcename, len(@source_prefix) + 1) = @source_prefix + '.') order by dx_Archive_header_id desc;"
    "  if (@existing_hdr is null and @existing_archive_count > 0) or (@existing_hdr is not null and @existing_archive_count = 0) throw 50006, 'partial Pilot order state exists; refusing automatic repair', 1;"
    '  if @existing_hdr is not null'
    '  begin'
    '    declare @existing_number varchar(12), @existing_state tinyint, @existing_status varchar(6); select @existing_number = rtrim(ord_number), @existing_state = ord_edistate, @existing_status = rtrim(ord_status) from dbo.orderheader where ord_hdrnumber = @existing_hdr;'
    "    declare @existing_fingerprint varchar(64) = case when len(@existing_source_name) = len(@source_prefix) + 65 and left(@existing_source_name, len(@source_prefix) + 1) = @source_prefix + '.' then right(@existing_source_name, 64) end;"
    '    declare @replay_action varchar(40), @requires_review bit = 0;'
    "    if @existing_archive_count > 1 select @replay_action = 'REVIEW_MULTIPLE_ARCHIVES', @requires_review = 1;"
    "    else if @existing_source_name = @source_name select @replay_action = 'SKIPPED_UNCHANGED';"
    "    else if @existing_fingerprint is null select @replay_action = 'REVIEW_CHANGED_UNFINGERPRINTED', @requires_review = 1;"
    "    else if @existing_state = 10 select @replay_action = 'REVIEW_CHANGED_PENDING', @requires_review = 1;"
    "    else if @existing_state in (40, 41, 42, 43, 45) select @replay_action = 'REVIEW_CHANGED_UPDATE_PENDING', @requires_review = 1;"
    "    else select @replay_action = 'REVIEW_CHANGED_LOCKED', @requires_review = 1;"
    '    commit transaction;'
    "    select cast(1 as bit) ok, @replay_action action, @requires_review requires_review, @pilot_id pilot_order_id, @existing_hdr order_hdrnumber, @existing_number order_number, @existing_archive archive_header_id, @existing_state edistate, @existing_status order_status, 0 detail_rows, @fingerprint incoming_fingerprint, @existing_fingerprint existing_fingerprint, db_name() database_name;"
    '    return;'
    '  end;'
    "  declare @mv int = 0, @ret int = 1, @ordnum varchar(12) = '', @stop_number int = 0, @freight_number int = 0;"
    "  declare @validate char(1) = 'N', @carrier varchar(8) = '', @dispatch_status varchar(6) = '', @leg_type varchar(6) = '';"
    '  declare @scope table (stop_index int not null, freight_index int not null, stop_number int not null, freight_number int not null, primary key (stop_index, freight_index));'
  ))

  $stops = @($PilotOrder.stops)
  for ($stopIndex = 1; $stopIndex -le $stops.Count; $stopIndex++) {
    $stop = $stops[$stopIndex - 1]
    $freight = @($stop.freight)
    $event = if ($stop.type -eq 'PU') { 'LLD' } else { 'LUL' }
    $timeWindow = if ($stop.type -eq 'DR') { 'Custom' } else { '' }
    foreach ($p in @(
      (New-TmwParameter "@cmp$stopIndex" 'VarChar' 8 ([string]$stop.locationCode))
      (New-TmwParameter "@name$stopIndex" 'VarChar' 100 ([string]$stop.name))
      (New-TmwParameter "@address1_$stopIndex" 'VarChar' 40 ([string]$stop.address1))
      (New-TmwParameter "@address2_$stopIndex" 'VarChar' 40 ([string]$stop.address2))
      (New-TmwParameter "@city_name$stopIndex" 'VarChar' 18 ([string]$stop.city))
      (New-TmwParameter "@state$stopIndex" 'VarChar' 6 ([string]$stop.state))
      (New-TmwParameter "@zip$stopIndex" 'VarChar' 10 ([string]$stop.zip))
      (New-TmwParameter "@arrival$stopIndex" 'DateTime' 0 ([datetime]$stop.earliest))
      (New-TmwParameter "@early$stopIndex" 'DateTime' 0 ([datetime]$stop.earliest))
      (New-TmwParameter "@late$stopIndex" 'DateTime' 0 ([datetime]$stop.latest))
      (New-TmwParameter "@window$stopIndex" 'VarChar' 15 $timeWindow)
      (New-TmwParameter "@cmd${stopIndex}_1" 'VarChar' 60 ([string]$freight[0].commodityName))
      (New-TmwParameter "@qty${stopIndex}_1" 'Float' 0 ([double]$freight[0].quantity))
      (New-TmwParameter "@oid${stopIndex}_1" 'VarChar' 30 ([string]$freight[0].pilotOrderItemId))
      (New-TmwParameter "@supid${stopIndex}_1" 'VarChar' 30 ([string]$freight[0].supplierContractId))
      (New-TmwParameter "@supname${stopIndex}_1" 'VarChar' 30 ([string]$freight[0].supplierName).Substring(0, [Math]::Min(30, ([string]$freight[0].supplierName).Length)))
    )) { [void]$parameters.Add($p) }
    # Raw Pilot IDs remain available for mapping while the pending stop carries readable address data.
    $sql.Add("  exec @ret = dbo.dx_add_neworder_stop 'N', @mv, $stopIndex, '$event', 'UNKNOWN', 0, 0, '', '', @arrival$stopIndex, @early$stopIndex, @late$stopIndex, 'UNKNOWN', @cmd${stopIndex}_1, 0, 'LBS', 0, 'PCS', @qty${stopIndex}_1, 'GAL', 'ST#', @cmp$stopIndex, 'OID', @oid${stopIndex}_1, '', 0, @mv output, @stop_number output, @freight_number output;")
    $sql.Add("  if @ret < 1 throw 50010, 'dx_add_neworder_stop failed', 1;")
    $sql.Add("  insert @scope values ($stopIndex, 1, @stop_number, @freight_number);")
    for ($freightIndex = 2; $freightIndex -le $freight.Count; $freightIndex++) {
      $item = $freight[$freightIndex - 1]
      foreach ($p in @(
        (New-TmwParameter "@cmd${stopIndex}_$freightIndex" 'VarChar' 60 ([string]$item.commodityName))
        (New-TmwParameter "@qty${stopIndex}_$freightIndex" 'Float' 0 ([double]$item.quantity))
        (New-TmwParameter "@oid${stopIndex}_$freightIndex" 'VarChar' 30 ([string]$item.pilotOrderItemId))
        (New-TmwParameter "@supid${stopIndex}_$freightIndex" 'VarChar' 30 ([string]$item.supplierContractId))
        (New-TmwParameter "@supname${stopIndex}_$freightIndex" 'VarChar' 30 ([string]$item.supplierName).Substring(0, [Math]::Min(30, ([string]$item.supplierName).Length)))
      )) { [void]$parameters.Add($p) }
      $sql.Add("  exec @ret = dbo.dx_add_neworder_freight_to_stop 'N', @stop_number, 'UNKNOWN', @cmd${stopIndex}_$freightIndex, 0, 'LBS', 0, 'PCS', @qty${stopIndex}_$freightIndex, 'GAL', 'OID', @oid${stopIndex}_$freightIndex, 0, '', 0, 0, '', 0, '', 0, '', 0, '', 0, '', @freight_number output;")
      $sql.Add("  if @ret < 1 throw 50011, 'dx_add_neworder_freight_to_stop failed', 1;")
      $sql.Add("  insert @scope values ($stopIndex, $freightIndex, @stop_number, @freight_number);")
    }
  }

  $sql.AddRange([string[]]@(
    "  exec @ret = dbo.dx_create_order_from_stops @validate output, @mv, '', @billto, @source_date, 'DX', @billto, 'Y', @division, '', '', '', 0, 'PO', @pilot_id, @remark, 'T', 0, '', 0, 0, '', '', 0, 0, 'PP', '', 'N', @carrier output, @dispatch_status output, @leg_type output, 'N', 10, @partner, @supplier, @ordnum output;"
    "  if @ret < 1 or nullif(rtrim(@ordnum), '') is null throw 50012, 'dx_create_order_from_stops failed', 1;"
    '  declare @order_hdrnumber int; select @order_hdrnumber = ord_hdrnumber from dbo.orderheader where ord_number = @ordnum;'
    "  if @order_hdrnumber is null throw 50013, 'created TMW order could not be resolved', 1;"
  ))

  for ($stopIndex = 1; $stopIndex -le $stops.Count; $stopIndex++) {
    $freight = @($stops[$stopIndex - 1].freight)
    for ($freightIndex = 1; $freightIndex -le $freight.Count; $freightIndex++) {
      $sql.Add("  declare @created_fgt${stopIndex}_$freightIndex int = (select freight_number from @scope where stop_index = $stopIndex and freight_index = $freightIndex);")
      $sql.Add("  exec @ret = dbo.dx_add_refnumber_to_freight @created_fgt${stopIndex}_$freightIndex, 'SID', @supid${stopIndex}_$freightIndex;")
      $sql.Add("  if @ret < 1 throw 50025, 'could not add Pilot supplier contract reference', 1;")
      $sql.Add("  exec @ret = dbo.dx_add_refnumber_to_freight @created_fgt${stopIndex}_$freightIndex, 'SUN', @supname${stopIndex}_$freightIndex;")
      $sql.Add("  if @ret < 1 throw 50026, 'could not add Pilot supplier name reference', 1;")
      $sql.Add("  exec @ret = dbo.dx_add_refnumber_to_freight @created_fgt${stopIndex}_$freightIndex, 'PO', @oid${stopIndex}_$freightIndex;")
      $sql.Add("  if @ret < 1 throw 50027, 'could not add Pilot item PO reference', 1;")
    }
  }

  for ($stopIndex = 1; $stopIndex -le $stops.Count; $stopIndex++) {
    if (-not ($stops[$stopIndex - 1].address1 -or $stops[$stopIndex - 1].city)) {
      $sql.Add("  update s set cmp_name = @name$stopIndex, stp_arrivaldate = @arrival$stopIndex, stp_departuredate = @late$stopIndex, stp_origarrival = @early$stopIndex, stp_schdtlatest = @late$stopIndex, stp_timewindow = @window$stopIndex from dbo.stops s join (select distinct stop_number from @scope where stop_index = $stopIndex) x on x.stop_number = s.stp_number where s.ord_hdrnumber = @order_hdrnumber;")
      $sql.Add("  if @@rowcount <> 1 throw 50021, 'could not populate one Pilot stop', 1;")
      continue
    }
    $sql.Add("  declare @city_code$stopIndex int;")
    $sql.Add("  select @city_code$stopIndex = coalesce((select min(cty_code) from dbo.city where upper(rtrim(cty_name)) = upper(rtrim(@city_name$stopIndex)) and upper(rtrim(cty_state)) = upper(rtrim(@state$stopIndex)) and rtrim(cty_zip) = rtrim(@zip$stopIndex)), (select min(cty_code) from dbo.city where upper(rtrim(cty_name)) = upper(rtrim(@city_name$stopIndex)) and upper(rtrim(cty_state)) = upper(rtrim(@state$stopIndex))));")
    $sql.Add("  if @city_code$stopIndex is null throw 50020, 'Pilot stop city is absent from TMW', 1;")
    $sql.Add("  update s set cmp_name = @name$stopIndex, stp_address = @address1_$stopIndex, stp_address2 = @address2_$stopIndex, stp_city = @city_code$stopIndex, stp_state = @state$stopIndex, stp_zipcode = @zip$stopIndex, stp_arrivaldate = @arrival$stopIndex, stp_departuredate = @late$stopIndex, stp_origarrival = @early$stopIndex, stp_schdtlatest = @late$stopIndex, stp_timewindow = @window$stopIndex from dbo.stops s join (select distinct stop_number from @scope where stop_index = $stopIndex) x on x.stop_number = s.stp_number where s.ord_hdrnumber = @order_hdrnumber;")
    $sql.Add("  if @@rowcount <> 1 throw 50021, 'could not populate one Pilot stop address', 1;")
  }

  $stopCount = $stops.Count
  $sql.AddRange([string[]]@(
    "  if exists (select 1 from @scope x join dbo.freightdetail f on f.fgt_number = x.freight_number where rtrim(isnull(f.fgt_supplier, 'UNKNOWN')) <> 'UNKNOWN') throw 50024, 'Pilot supplier must remain UNKNOWN for DX mapping', 1;"
    "  if (select count(1) from dbo.stops s left join dbo.city c on c.cty_code = s.stp_city where s.ord_hdrnumber = @order_hdrnumber and nullif(rtrim(s.cmp_name), '') is not null and (rtrim(s.cmp_name) in ('NO TERMINAL', 'NO LOCATION') or (c.cty_code is not null and nullif(rtrim(s.stp_address), '') is not null and nullif(rtrim(s.stp_state), '') is not null and nullif(rtrim(s.stp_zipcode), '') is not null)) and s.stp_departuredate > s.stp_arrivaldate and s.stp_schdtlatest = s.stp_departuredate and ((s.stp_event = 'LUL' and rtrim(s.stp_timewindow) = 'Custom') or (s.stp_event = 'LLD' and nullif(rtrim(s.stp_timewindow), '') is null))) <> $stopCount throw 50022, 'created order has incomplete display stops or delivery windows', 1;"
    "  update dbo.orderheader set ord_revtype1 = @division, ord_booked_revtype1 = @division where ord_hdrnumber = @order_hdrnumber;"
    "  if @@rowcount <> 1 throw 50023, 'could not route Pilot order to its division', 1;"
    "  exec @ret = dbo.dx_add_refnumber_to_order @ordnum, 'SCA', @scac;"
    "  if @ret < 1 throw 50018, 'dx_add_refnumber_to_order failed for the SCAC', 1;"
    "  if not exists (select 1 from dbo.orderheader where ord_hdrnumber = @order_hdrnumber and ord_order_source = 'EDI' and ord_editradingpartner = @partner and ord_edistate = 10 and ord_revtype1 = @division and rtrim(ord_bookedby) = 'DX') throw 50014, 'created order did not land in the Pilot accept queue', 1;"
    "  if not exists (select 1 from dbo.referencenumber where ref_table = 'orderheader' and ref_tablekey = @order_hdrnumber and ref_type = 'SCA' and ref_number = @scac) throw 50019, 'created order has no exact SCAC reference', 1;"
    '  declare @archive_header_id bigint;'
    '  insert dbo.dx_Archive_header (dx_importid, dx_sourcename, dx_sourcedate, dx_accepted, dx_ordernumber, dx_orderhdrnumber, dx_movenumber, dx_doctype, dx_docnumber, dx_createdby, dx_createdate, dx_processed, dx_trpid, dx_billto)'
    "  values ('dx_204', @source_name, @source_date, null, @ordnum, @order_hdrnumber, @mv, '204', '', 'PILOTFEED', @source_date, 'DONE', @partner, @billto);"
    '  set @archive_header_id = convert(bigint, scope_identity());'
  ))

  foreach ($row in @($plan.rows)) {
    $fieldSql = @{}
    foreach ($fieldName in @('dx_field001','dx_field002','dx_field003','dx_field004','dx_field005','dx_field006','dx_field007','dx_field008','dx_field009','dx_field013','dx_field014')) {
      $value = $row.fields[$fieldName]
      if ([string]$value -eq $script:OrderNumberToken) {
        $width = if ($fieldName -eq 'dx_field005') { 20 } else { 80 }
        $fieldSql[$fieldName] = "left(convert(varchar($width), @ordnum) + replicate(' ', $width), $width)"
      } elseif ($null -eq $value) {
        $fieldSql[$fieldName] = 'null'
      } else {
        $parameterName = '@d{0}_{1}' -f $row.sequence, $fieldName.Substring(3)
        [void]$parameters.Add((New-TmwParameter $parameterName 'VarChar' 200 ([string]$value)))
        $fieldSql[$fieldName] = $parameterName
      }
    }
    $stopSql = if ($row.stopIndex -gt 0) {
      "(select top (1) stop_number from @scope where stop_index = $($row.stopIndex) order by freight_index)"
    } else { 'null' }
    $freightSql = if ($row.freightIndex -gt 0) {
      "(select freight_number from @scope where stop_index = $($row.stopIndex) and freight_index = $($row.freightIndex))"
    } else { 'null' }
    $sql.Add(('  insert dbo.dx_Archive_detail (dx_Archive_header_id, dx_seq, dx_stopnumber, dx_freightnumber, dx_manifeststop, dx_field001, dx_field002, dx_field003, dx_field004, dx_field005, dx_field006, dx_field007, dx_field008, dx_field009, dx_field013, dx_field014) ' +
      "select @archive_header_id, $($row.sequence), $stopSql, $freightSql, null, " +
      (@($fieldSql['dx_field001'], $fieldSql['dx_field002'], $fieldSql['dx_field003'], $fieldSql['dx_field004'],
         $fieldSql['dx_field005'], $fieldSql['dx_field006'], $fieldSql['dx_field007'], $fieldSql['dx_field008'],
         $fieldSql['dx_field009'], $fieldSql['dx_field013'], $fieldSql['dx_field014']) -join ', ') + ';'))
  }

  $detailCount = @($plan.rows).Count
  $sql.AddRange([string[]]@(
    "  if (select count(1) from dbo.dx_Archive_detail where dx_Archive_header_id = @archive_header_id) <> $detailCount throw 50015, 'DX archive detail count mismatch', 1;"
    '  if @commit = 1 commit transaction; else rollback transaction;'
    "  select cast(1 as bit) ok, case when @commit = 1 then 'CREATED' else 'VALIDATED' end action, cast(0 as bit) requires_review, @pilot_id pilot_order_id, @order_hdrnumber order_hdrnumber, rtrim(@ordnum) order_number, @archive_header_id archive_header_id, convert(tinyint, 10) edistate, 'AVL' order_status, $detailCount detail_rows, @fingerprint incoming_fingerprint, cast(null as varchar(64)) existing_fingerprint, db_name() database_name;"
    'end try'
    'begin catch'
    '  if @@trancount > 0 rollback transaction;'
    '  throw;'
    'end catch;'
  ))

  [pscustomobject]@{
    sql = $sql -join "`n"
    parameters = $parameters.ToArray()
    archive = $plan
  }
}

function Add-TmwSqlParameter {
  param($Command, $Definition)
  $sqlType = [System.Enum]::Parse([System.Data.SqlDbType], [string]$Definition.type)
  $parameter = if ($Definition.size -gt 0) {
    $Command.Parameters.Add($Definition.name, $sqlType, $Definition.size)
  } else {
    $Command.Parameters.Add($Definition.name, $sqlType)
  }
  $parameter.Value = if ($null -eq $Definition.value -or [string]$Definition.value -eq '') {
    if ($Definition.type -eq 'VarChar') { [string]$Definition.value } else { [DBNull]::Value }
  } else { $Definition.value }
}

function Invoke-TmwOrder {
  param(
    [Parameter(Mandatory)]$PilotOrder,
    [Parameter(Mandatory)]$Cfg,
    [string]$ConnectionString,
    [switch]$Commit
  )
  $commandPlan = New-TmwOrderCommand $PilotOrder $Cfg -Commit:$Commit
  if (-not $ConnectionString) { throw 'TMW connection string is required.' }

  $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
  $command = $connection.CreateCommand()
  $command.CommandText = $commandPlan.sql
  $command.CommandTimeout = [int](Get-TmwValue $Cfg 'tmw' 'command_timeout_seconds' 120)
  foreach ($definition in $commandPlan.parameters) { Add-TmwSqlParameter $command $definition }
  try {
    $connection.Open()
    $reader = $command.ExecuteReader()
    try {
      $result = $null
      do {
        $names = @($(for ($i = 0; $i -lt $reader.FieldCount; $i++) { $reader.GetName($i) }))
        if ($names -contains 'action' -and $reader.Read()) {
          $result = [ordered]@{}
          foreach ($name in $names) {
            $value = $reader[$name]
            $result[$name] = if ($value -is [DBNull]) { $null } else { $value }
          }
        }
      } while ($reader.NextResult())
      if (-not $result) { throw 'TMW direct staging returned no result row.' }
      [pscustomobject]$result
    } finally {
      $reader.Dispose()
    }
  } finally {
    $command.Dispose()
    $connection.Dispose()
  }
}

function Invoke-TmwRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Operation,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 2
  )
  if ($MaxAttempts -lt 1) { throw 'MaxAttempts must be at least 1.' }
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $result = & $Operation
      $result | Add-Member -NotePropertyName attempts -NotePropertyValue $attempt -Force
      return $result
    } catch {
      if ($attempt -eq $MaxAttempts) { throw }
      Write-Warning "TMW attempt $attempt failed: $($_.Exception.Message). Retrying."
      Start-Sleep -Seconds ($DelaySeconds * $attempt)
    }
  }
}

function Write-TmwOrders {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$Orders,
    [Parameter(Mandatory)]$Cfg,
    [string]$ConnectionString,
    [switch]$Commit
  )
  $items = @($Orders)
  if (-not $items.Count) { return @() }
  $maxParallel = [Math]::Max(1, [Math]::Min(20, [int](Get-TmwValue $Cfg 'tmw' 'max_parallel' 10)))
  $maxAttempts = [Math]::Max(1, [int](Get-TmwValue $Cfg 'tmw' 'retry_attempts' 3))
  $retryDelay = [Math]::Max(0, [int](Get-TmwValue $Cfg 'tmw' 'retry_delay_seconds' 2))
  $modulePath = Join-Path $PSScriptRoot 'PilotCarrierIntegration.psd1'
  $cfgJson = $Cfg | ConvertTo-Json -Depth 20 -Compress
  $pool = [RunspaceFactory]::CreateRunspacePool(1, $maxParallel)
  $pool.ApartmentState = 'MTA'
  $pool.Open()
  $workers = [System.Collections.Generic.List[object]]::new()
  $workerScript = {
    param($Order, $CfgJson, $ConnectionString, $Commit, $ModulePath, $MaxAttempts, $RetryDelay)
    $workerCfg = $CfgJson | ConvertFrom-Json
    try {
      & (Import-Module $ModulePath -PassThru) {
        param($o, $c, $cs, $cm, $ma, $rd)
        Invoke-TmwRetry -MaxAttempts $ma -DelaySeconds $rd -Operation { Invoke-TmwOrder -PilotOrder $o -Cfg $c -ConnectionString $cs -Commit:$cm }
      } $Order $workerCfg $ConnectionString $Commit $MaxAttempts $RetryDelay
    } catch {
      [pscustomobject]@{
        ok = $false; action = 'FAILED'; pilot_order_id = [string]$Order.pilotOrderId
        requires_review = $false
        order_hdrnumber = $null; order_number = $null; archive_header_id = $null
        edistate = $null; detail_rows = 0; database_name = $null
        attempts = $MaxAttempts; error = $_.Exception.Message
      }
    }
  }
  try {
    foreach ($order in $items) {
      $pipeline = [PowerShell]::Create()
      [void]$pipeline.AddScript($workerScript)
      [void]$pipeline.AddArgument($order)
      [void]$pipeline.AddArgument($cfgJson)
      [void]$pipeline.AddArgument($ConnectionString)
      [void]$pipeline.AddArgument([bool]$Commit)
      [void]$pipeline.AddArgument($modulePath)
      [void]$pipeline.AddArgument($maxAttempts)
      [void]$pipeline.AddArgument($retryDelay)
      $pipeline.RunspacePool = $pool
      $workers.Add([pscustomobject]@{ pipeline = $pipeline; handle = $pipeline.BeginInvoke(); ref = $order.pilotOrderId })
    }
    while (@($workers | Where-Object { -not $_.handle.IsCompleted }).Count) {
      Start-Sleep -Milliseconds 100
    }
    @($workers | ForEach-Object {
      $worker = $_
      try {
        @($worker.pipeline.EndInvoke($worker.handle)) | Select-Object -Last 1
      } catch {
        [pscustomobject]@{
          ok = $false; action = 'FAILED'; pilot_order_id = [string]$worker.ref
          requires_review = $false
          attempts = $maxAttempts; error = $_.Exception.Message
        }
      } finally {
        $worker.pipeline.Dispose()
      }
    })
  } finally {
    $pool.Close()
    $pool.Dispose()
  }
}

# the TMW writer reads settings through PSObject.Properties, so the order path works on the JSON object shape
function ConvertTo-PilotOrderCfg([hashtable]$Settings) { $Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

# DataAgent source: Pilot orders ready to stage, translated
function Read-PilotCarrierOrders {
  param([hashtable]$Options)
  $session = New-PilotCarrierSession $Options.Settings.pilot
  $orders = @(Receive-PilotOrders (ConvertTo-PilotOrderCfg $Options.Settings) $session)
  Write-Log "Orders : $($orders.Count) from Pilot to stage"
  $orders
}

# DataAgent formatter: keep the translated orders, types intact, for the destination
function Save-PilotOrderPlan {
  param($Data, [hashtable]$Options)
  $null = New-Item -ItemType Directory -Force (Split-Path $Options.Path)
  @($Data) | Export-Clixml -LiteralPath $Options.Path -Depth 20
}

# DataAgent destination: stage each order in TMW; dry_run validates and rolls back
function Send-PilotOrderPlan {
  param([string]$Path, [hashtable]$Options)
  $orders = @(Import-Clixml -LiteralPath $Path)
  $cfg = ConvertTo-PilotOrderCfg $Options.Settings
  $commit = -not $Options.Settings.dry_run
  Write-Log "Stage  : $($orders.Count) order(s), $(if ($commit) { 'commit' } else { 'validate only' })"
  $results = @(Write-TmwOrders -Orders $orders -Cfg $cfg -ConnectionString $cfg.tmw.connection_string -Commit:$commit)
  foreach ($result in $results) {
    if ($result.requires_review) { Write-Log ("Review : {0} {1}: TMW order {2}, status {3}, state {4}" -f $result.pilot_order_id, $result.action, $result.order_number, $result.order_status, $result.edistate) }
    elseif ($result.ok) { Write-Log ("{0,-7}: {1}: TMW order {2}, state {3}" -f $result.action, $result.pilot_order_id, $result.order_number, $result.edistate) }
    else { Write-Log ("Failed : {0} after {1} attempt(s): {2}" -f $result.pilot_order_id, $result.attempts, $result.error) }
  }
  $failed = @($results | Where-Object { -not $_.ok })
  if ($failed.Count) { throw "$($failed.Count) Pilot order(s) failed after retries; the next run tries again." }
}
