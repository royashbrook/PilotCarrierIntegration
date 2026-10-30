# From one Pilot order record to the order object Tmw.ps1 stages: the map applied row by row, the skip
# reason when a required value is blank, one stop per place with its freight lines.

# a partial address from Pilot still stages: each missing part is marked so dispatch sees what to finish
function Complete-PilotAddress {
  param([Parameter(Mandatory)]$Address)
  if (-not (@($Address.address1, $Address.city, $Address.state, $Address.zip) -match '\S')) { return $Address }
  foreach ($part in @{ address1 = 'MISSING'; city = 'MISSING'; zip = 'MISSING'; state = '??' }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$Address.($part.Key))) { $Address.($part.Key) = $part.Value }
  }
  $Address
}

function Resolve-PilotPath($Context, [string]$Path) {
  $value = $Context
  foreach ($part in $Path.Split('.')) { $value = $value.$part }
  $value
}

function Test-PilotCheck([string]$Name, $Value) {
  $check = $script:PilotOrderChecks[$Name]
  if ($check -is [scriptblock]) { & $check $Value } else { [string]$Value -match $check }
}

# the first check in map order that fails, as the skip reason, naming every item that failed it
function Get-PilotMapReason($Rows, [object[]]$Contexts) {
  foreach ($row in $Rows) {
    foreach ($path in @($row.src)) {
      $bad = @($Contexts | Where-Object { -not (Test-PilotCheck $row.check (Resolve-PilotPath $_ $path)) })
      if ($bad.Count) {
        $items = @($bad | ForEach-Object { $_.item.dispatchOrderItemId })
        return 'no {0}{1}' -f $path.Split('.')[-1], $(if ($bad[0].ContainsKey('item')) { ' on item ' + ($items -join ', ') })
      }
    }
  }
}

# one model object from a scope's rows, as the writer reads it
function New-PilotMapObject([string]$Scope, $Context) {
  $object = [ordered]@{}
  foreach ($row in @($script:PilotOrderMap | Where-Object dst -like "$Scope.*")) {
    $values = @(foreach ($path in @($row.src)) { Resolve-PilotPath $Context $path })
    $value = $null
    if ($row.ContainsKey('value')) { $value = $row.value }
    elseif ($row.format) { $value = $row.format -f $values }
    else { foreach ($candidate in $values) { if ("$candidate" -match '\S') { $value = $candidate; break } } }
    if ("$value" -notmatch '\S' -and $row.ContainsKey('default')) { $value = $row.default }
    if ($row.cast) { $value = $value -as ($row.cast -as [type]) }
    $object[$row.dst.Split('.')[1]] = $value
  }
  [pscustomobject]$object
}

function ConvertFrom-PilotOrder {
  param(
    [Parameter(Mandatory)]$Record,
    $Cfg,
    [Parameter(Mandatory)]$References
  )

  $reason = Get-PilotOrderSkipReason $Record
  if ($reason) { throw "Pilot order $($Record.dispatchOrderId): $reason." }
  $order = New-PilotMapObject order @{ order = $Record; cfg = $Cfg }
  $items = @($Record.dispatchOrderItems | Where-Object { -not $_.isDeleted })
  # the reference rows this order used, kept with it when it is staged
  $used = [ordered]@{ terminals = @{}; locations = @{}; contracts = @{} }
  $stops = [ordered]@{}
  foreach ($item in $items) {
    $context = @{ order = $Record; item = $item; cfg = $Cfg }
    # the lists only fill in names and addresses; TMW maps each stop by its id. an id their list lacks
    # keeps the id, and the stop comes over with no address for ops to finish in EDI
    foreach ($list in $script:PilotReferenceLists) {
      $id = [string]$item.($list.id)
      $context[$list.name] = $References."$($list.name)s"[$id]
      if ($context[$list.name]) { $used["$($list.name)s"][$id] = $context[$list.name] }
    }
    $freight = New-PilotMapObject freight $context
    # one stop per place, its freight lines in item order
    foreach ($scope in 'pickup', 'delivery') {
      $stop = Complete-PilotAddress (New-PilotMapObject $scope $context)
      $key = '{0}|{1}' -f $stop.type, $stop.locationCode
      if (-not $stops.Contains($key)) {
        $stops[$key] = $stop | Add-Member -PassThru -NotePropertyMembers @{ earliest = $order.deliveryWindowStart; latest = $order.deliveryWindowEnd; freight = [Collections.Generic.List[object]]::new() }
      }
      $stops[$key].freight.Add($freight)
    }
  }

  $order | Add-Member -PassThru -NotePropertyMembers @{
    stops = @($stops.Values | Where-Object type -eq 'PU') + @($stops.Values | Where-Object type -eq 'DR')
    raw = $Record
    references = [pscustomobject]$used
  }
}

# why a Pilot order is not staged this run, or nothing for a good load. the map's checked rows run in
# list order, with the checks that span fields (status, the scheduled window, active items) between the
# order rows and the item rows. it reads only the order itself, so it runs before anything else is read
function Get-PilotOrderSkipReason {
  param([Parameter(Mandatory)]$Record, [int[]]$Include = @(2), $Window)
  $rows = @($script:PilotOrderMap | Where-Object check)
  $reason = Get-PilotMapReason @($rows | Where-Object dst -like 'order.*') @(@{ order = $Record })
  if ($reason) { return $reason }
  $status = 0
  if (-not [int]::TryParse([string]$Record.dispatchOrderStatusTypeId, [ref]$status) -or $status -ne 2 -or $status -notin $Include) { return "status $($Record.dispatchOrderStatusTypeId) $($Record.dispatchOrderStatusTypeName)".Trim() }
  if ([string]::IsNullOrWhiteSpace([string]$Record.scheduledStartDateTime) -or [string]::IsNullOrWhiteSpace([string]$Record.scheduledEndDateTime)) { return 'no scheduled window' }
  $dates = @()
  foreach ($field in 'scheduledStartDateTime', 'scheduledEndDateTime') {
    $value = $Record.$field
    $date = [datetime]::MinValue
    if ($value -is [datetime]) { $date = $value }
    elseif (-not [datetime]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { return 'invalid scheduled window' }
    $dates += $date
  }
  if ([DateTimeOffset]$dates[1] -le [DateTimeOffset]$dates[0]) { return 'scheduled window ends before it starts' }
  if ($Window.exact) {
    $scheduled = [DateTimeOffset]$dates[0]
    if ($scheduled -lt [DateTimeOffset]$Window.start -or $scheduled -ge [DateTimeOffset]$Window.end) { return 'scheduled start outside poll window' }
  }
  $items = @($Record.dispatchOrderItems | Where-Object { -not $_.isDeleted })
  if (-not $items.Count) { return 'no active items' }
  Get-PilotMapReason @($rows | Where-Object dst -notlike 'order.*') @($items | ForEach-Object { @{ order = $Record; item = $_ } })
}
