# Pilot BOL completions: TMW completed freight -> one PUT /bol per order, once every line is complete.
#
# The order is decided complete from TMW alone. Every freight line carries its Pilot item id (the OID
# pil-order staged), so no Pilot read is needed first: a post Kiosks the whole order, which is why an
# order goes only when every line has its item, BOL, gallons and times. Pilot's answer says whether the
# order is Kiosked with a BOL on every item; that is the done signal, recorded in the cache.

function New-PilotBolPlan {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$TmwRows)

  $ready = [Collections.Generic.List[object]]::new()
  $deferred = [Collections.Generic.List[object]]::new()

  foreach ($tmwOrder in @($TmwRows | Group-Object tmwOrderId)) {
    $refs = @($tmwOrder.Group.pilotOrderRef | Where-Object { $_ } | Sort-Object -Unique)
    $pilotId = 0L
    $reason = if ($refs.Count -ne 1) { if ($refs.Count) { 'multiple Pilot PO references' } else { 'no Pilot PO reference' } }
      elseif (-not [long]::TryParse([string]$refs[0], [ref]$pilotId) -or $pilotId -le 0) { 'Pilot PO reference is not a positive numeric dispatchOrderId' }
    if ($reason) {
      $deferred.Add([pscustomobject]@{ tmwOrderId = [long]$tmwOrder.Name; reason = $reason })
      continue
    }

    # one row per freight line, first by sequence when the query repeats one
    $rows = @(
      $tmwOrder.Group |
        Group-Object freightId |
        ForEach-Object { @($_.Group | Sort-Object freightSequence)[0] } |
        Sort-Object freightSequence, freightId
    )
    $errors = [Collections.Generic.List[string]]::new()
    $payload = [Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
      $itemId = 0L; $bol = 0L
      $missing = @(
        if (-not [long]::TryParse([string]$row.pilotOrderItemId, [ref]$itemId) -or $itemId -le 0) { 'Pilot item id (OID)' }
        if (-not [long]::TryParse([string]$row.bolNumber, [ref]$bol) -or $bol -le 0) { 'BOL' }
        if ($null -eq $row.grossGallons -or [decimal]$row.grossGallons -le 0) { 'gross gallons' }
        if ($null -eq $row.netGallons -or [decimal]$row.netGallons -le 0) { 'net gallons' }
        if (-not $row.startPullDateTime) { 'pull start' }
        if (-not $row.endPullDateTime) { 'pull end' }
        if (-not $row.dropDateTime) { 'drop time' }
      )
      if ($missing.Count) { $errors.Add("freight $($row.freightId): missing $($missing -join ', ')"); continue }
      $payload.Add([pscustomobject][ordered]@{
        grossGallons = [decimal]$row.grossGallons
        netGallons = [decimal]$row.netGallons
        billOfLadingNumber = [long]$bol
        dispatchOrderId = [long]$pilotId
        dispatchOrderItemId = [long]$itemId
        dropDateTime = ([datetime]$row.dropDateTime).ToString('yyyy-MM-ddTHH:mm:ss')
        startPullDateTime = ([datetime]$row.startPullDateTime).ToString('yyyy-MM-ddTHH:mm:ss')
        endPullDateTime = ([datetime]$row.endPullDateTime).ToString('yyyy-MM-ddTHH:mm:ss')
        railCarNumber = if ($row.railCarNumber) { [string]$row.railCarNumber } else { $null }
      })
    }
    if (-not $errors.Count -and @($payload.dispatchOrderItemId | Sort-Object -Unique).Count -ne $payload.Count) {
      $errors.Add('two freight lines carry the same Pilot item id')
    }
    if ($errors.Count) {
      $deferred.Add([pscustomobject]@{ tmwOrderId = [long]$tmwOrder.Name; dispatchOrderId = [long]$pilotId; reason = ($errors -join '; ') })
      continue
    }
    $ready.Add([pscustomobject]@{ tmwOrderId = [long]$tmwOrder.Name; dispatchOrderId = [long]$pilotId; payload = @($payload) })
  }

  [pscustomobject]@{ ready = @($ready); deferred = @($deferred) }
}

# one file per Pilot order in the cache folder (settings "cache", default "cache", like the other order feeds): what went, when, and Pilot's answer. a run sends
# an order again only when what it would send differs, so the TMW lookback can overlap runs
function Get-PilotBolHash($Payload) {
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($Payload) -Depth 6 -Compress))
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-PilotBolCache([string]$Folder, $DispatchOrderId) {
  $path = Join-Path $Folder "$DispatchOrderId.json"
  if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

# one order's completion. done means Pilot answered with the order Kiosked (status 4; its status text can
# be stale) and a BOL on every item. Pilot turning the post down is an answer, recorded and tried again
# next run; only not reaching Pilot (auth, throttling, a server error, a timeout) throws.
function Send-PilotBol {
  param([Parameter(Mandatory)]$Batch, [Parameter(Mandatory)]$Session)
  try {
    $response = Set-PilotBol -Session $Session -Payload $Batch.payload
  } catch {
    $code = [int]$_.Exception.Response.StatusCode
    if ($code -lt 400 -or $code -ge 500 -or $code -in 401, 403, 429) { throw }
    return [pscustomobject]@{ done = $false; note = "turned down, HTTP $code $($_.ErrorDetails.Message)".Trim() }
  }
  $returned = $response.data.payload
  if ($response.status -ne 'success') { return [pscustomobject]@{ done = $false; note = "turned down: $($response.status)" } }
  $state = "status $($returned.dispatchOrderStatusTypeId), allItemsHasBols $($returned.allItemsHasBols)"
  $done = [long]$returned.dispatchOrderId -eq [long]$Batch.dispatchOrderId -and
    [int]$returned.dispatchOrderStatusTypeId -eq 4 -and $returned.allItemsHasBols -eq $true
  [pscustomobject]@{ done = $done; note = if ($done) { $state } else { "posted, Pilot shows order $($returned.dispatchOrderId) $state" } }
}

# DataAgent formatter: TMW rows in, plan file out
function Save-PilotBolPlan {
  param($Data, [hashtable]$Options)
  $rows = @($Data)
  $plan = New-PilotBolPlan -TmwRows $rows
  $ready = [Collections.Generic.List[object]]::new()
  $sent = [Collections.Generic.List[object]]::new()
  foreach ($item in @($plan.ready)) {
    $item | Add-Member -NotePropertyName hash -NotePropertyValue (Get-PilotBolHash $item.payload) -Force
    $cached = Get-PilotBolCache $Options.Cache $item.dispatchOrderId
    if ($cached -and $cached.hash -eq $item.hash) { $sent.Add([pscustomobject]@{ item = $item; at = $cached.sent_at }) } else { $ready.Add($item) }
  }
  Write-Log "Orders : $(@($rows | Group-Object tmwOrderId).Count) completed in TMW, $($ready.Count) ready, $(@($plan.deferred).Count) waiting, $($sent.Count) already done"
  foreach ($item in @($plan.deferred)) { Write-Log "Waiting: TMW $($item.tmwOrderId): $($item.reason)" }
  foreach ($s in $sent) { Write-Log "Already: TMW $($s.item.tmwOrderId), Pilot $($s.item.dispatchOrderId), done $($s.at)" }
  $null = New-Item -ItemType Directory -Force (Split-Path $Options.Path)
  [pscustomobject]@{ ready = @($ready); deferred = @($plan.deferred) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Options.Path
}

# DataAgent destination: post every ready order, in parallel. an order Pilot does not finish is logged
# and goes again next run; the run fails only when Pilot could not be reached
function Send-PilotBolPlan {
  param([string]$Path, [hashtable]$Options)
  $ready = @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).ready)
  if (-not $ready.Count) { Write-Log 'Nothing ready to send'; return }
  $session = New-PilotCarrierSession $Options.Pilot
  $null = Get-PilotToken $session
  $module = Join-Path $PSScriptRoot 'PilotCarrierIntegration.psd1'
  $throttle = if ($Options.ThrottleLimit) { [int]$Options.ThrottleLimit } else { 8 }
  $results = @($ready | ForEach-Object -Parallel {
    $batch = $_
    try {
      $outcome = & (Import-Module $using:module -PassThru) { param($b, $s) Send-PilotBol -Batch $b -Session $s } $batch $using:session
      [pscustomobject]@{ batch = $batch; outcome = $outcome; error = $null }
    } catch {
      [pscustomobject]@{ batch = $batch; outcome = $null; error = $_.Exception.Message }
    }
  } -ThrottleLimit $throttle)
  foreach ($result in $results) {
    $label = "TMW $($result.batch.tmwOrderId), Pilot $($result.batch.dispatchOrderId), BOL $(@($result.batch.payload.billOfLadingNumber) -join ',')"
    if ($result.error) { Write-Log "Failed : $label`: $($result.error)"; continue }
    if (-not $result.outcome.done) { Write-Log "Not done: $label`: $($result.outcome.note)"; continue }
    $null = New-Item -ItemType Directory -Force $Options.Cache
    [pscustomobject]@{
      sent_at = [datetime]::UtcNow.ToString('o'); tmwOrderId = $result.batch.tmwOrderId; dispatchOrderId = $result.batch.dispatchOrderId
      hash = $result.batch.hash; pilot = $result.outcome.note; payload = $result.batch.payload
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Options.Cache "$($result.batch.dispatchOrderId).json")
    Write-Log "Sent   : $label, $($result.outcome.note)"
  }
  $failed = @($results | Where-Object error)
  if ($failed.Count) { throw "$($failed.Count) Pilot BOL request(s) could not reach Pilot; the next run tries them again." }
}
