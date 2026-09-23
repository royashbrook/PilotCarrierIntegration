# Pilot BOL completions: correlate TMW completed freight to Pilot order items, plan, PUT /bol.

function New-PilotBolPlan {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$TmwRows,
    [Parameter(Mandatory)][AllowEmptyCollection()]$PilotOrders,
    [Parameter(Mandatory)][AllowEmptyCollection()]$AvailableBols
  )

  $ready = [Collections.Generic.List[object]]::new()
  $deferred = [Collections.Generic.List[object]]::new()

  foreach ($tmwOrder in @($TmwRows | Group-Object tmwOrderId)) {
    $refs = @($tmwOrder.Group.pilotOrderRef | Where-Object { $_ } | Sort-Object -Unique)
    if ($refs.Count -ne 1) {
      $deferred.Add([pscustomobject]@{
        tmwOrderId = [long]$tmwOrder.Name
        reason = if ($refs.Count) { 'multiple Pilot PO references' } else { 'no Pilot PO reference' }
      })
      continue
    }

    $pilotId = 0L
    if (-not [long]::TryParse([string]$refs[0], [ref]$pilotId) -or $pilotId -le 0) {
      $deferred.Add([pscustomobject]@{
        tmwOrderId = [long]$tmwOrder.Name
        reason = 'Pilot PO reference is not a positive numeric dispatchOrderId'
      })
      continue
    }

    $rows = @(
      $tmwOrder.Group |
        Group-Object freightId |
        ForEach-Object { @($_.Group | Sort-Object freightSequence)[0] } |
        Sort-Object freightSequence, freightId
    )
    $freightIds = @($rows.freightId | Sort-Object -Unique)
    $errors = [Collections.Generic.List[string]]::new()
    $normalized = [Collections.Generic.List[object]]::new()
    $pilotOrder = @($PilotOrders | Where-Object { [long]$_.dispatchOrderId -eq $pilotId })
    if ($pilotOrder.Count -ne 1) {
      $errors.Add("Pilot order correlation found $($pilotOrder.Count) orders")
    }
    $expectedItems = if ($pilotOrder.Count -eq 1) {
      @($pilotOrder[0].dispatchOrderItems | Where-Object { -not $_.isDeleted })
    } else { @() }
    if (-not $errors.Count -and $expectedItems.Count -ne $freightIds.Count) {
      $errors.Add("Pilot expects $($expectedItems.Count) active items; TMW has $($freightIds.Count) freight lines")
    }

    $usedSourceBols = [Collections.Generic.HashSet[string]]::new()
    foreach ($row in $rows) {
      $valid = $true
      $itemId = 0L
      $bol = 0L
      if (-not [long]::TryParse([string]$row.bolNumber, [ref]$bol) -or $bol -le 0) {
        $errors.Add("freight $($row.freightId): invalid BOL")
        $valid = $false
      }
      if ($null -eq $row.grossGallons -or [decimal]$row.grossGallons -le 0) {
        $errors.Add("freight $($row.freightId): missing gross gallons")
        $valid = $false
      }
      if ($null -eq $row.netGallons -or [decimal]$row.netGallons -le 0) {
        $errors.Add("freight $($row.freightId): missing net gallons")
        $valid = $false
      }
      if (-not $row.startPullDateTime) {
        $errors.Add("freight $($row.freightId): missing pull start")
        $valid = $false
      }
      if (-not $row.endPullDateTime) {
        $errors.Add("freight $($row.freightId): missing pull end")
        $valid = $false
      }
      if (-not $row.dropDateTime) {
        $errors.Add("freight $($row.freightId): missing drop time")
        $valid = $false
      }

      if ([long]::TryParse([string]$row.pilotOrderItemId, [ref]$itemId) -and $itemId -gt 0) {
        $activeItemIds = @($expectedItems.dispatchOrderItemId | ForEach-Object { [long]$_ })
        if ($expectedItems.Count -and $itemId -notin $activeItemIds) {
          $errors.Add("freight $($row.freightId): Pilot order item ID is not active on the order")
          $valid = $false
        }
      } elseif ($valid -and $expectedItems.Count) {
        $ranked = @($AvailableBols | Where-Object {
          [long]$_.orderNumber -eq $pilotId -and
          [long]$_.bolNumber -eq $bol -and
          -not $usedSourceBols.Contains(('{0}/{1}' -f $_.product360Id, $_.bolNumber))
        } | ForEach-Object {
          [pscustomobject]@{
            source = $_
            grossDifference = [math]::Abs([decimal]$_.grossGallons - [decimal]$row.grossGallons)
            netDifference = [math]::Abs([decimal]$_.netGallons - [decimal]$row.netGallons)
          }
        } | Where-Object {
          $_.grossDifference -le 2 -and $_.netDifference -le 2
        } | Sort-Object @{ Expression = { $_.grossDifference + $_.netDifference } })

        if (-not $ranked.Count) {
          $errors.Add("freight $($row.freightId): no exact available-BOL product match")
          $valid = $false
        } elseif ($ranked.Count -gt 1 -and
          ($ranked[0].grossDifference + $ranked[0].netDifference) -eq
          ($ranked[1].grossDifference + $ranked[1].netDifference)) {
          $errors.Add("freight $($row.freightId): ambiguous available-BOL product match")
          $valid = $false
        } else {
          $source = $ranked[0].source
          $itemMatches = @($expectedItems | Where-Object {
            [long]$_.productSystemId -eq [long]$source.product360Id -or
            [long]$_.wraProductSystemId -eq [long]$source.product360Id
          })
          if ($itemMatches.Count -ne 1) {
            $errors.Add("freight $($row.freightId): product $($source.product360Id) maps to $($itemMatches.Count) Pilot items")
            $valid = $false
          } else {
            $itemId = [long]$itemMatches[0].dispatchOrderItemId
            [void]$usedSourceBols.Add(('{0}/{1}' -f $source.product360Id, $source.bolNumber))
          }
        }
      } else {
        $errors.Add("freight $($row.freightId): invalid Pilot order item ID")
        $valid = $false
      }

      if ($valid) {
        $normalized.Add([pscustomobject]@{
          freightId = [long]$row.freightId
          freightSequence = [int]$row.freightSequence
          dispatchOrderItemId = [long]$itemId
          billOfLadingNumber = [long]$bol
          grossGallons = [decimal]$row.grossGallons
          netGallons = [decimal]$row.netGallons
          startPullDateTime = [datetime]$row.startPullDateTime
          endPullDateTime = [datetime]$row.endPullDateTime
          dropDateTime = [datetime]$row.dropDateTime
          railCarNumber = if ($row.railCarNumber) { [string]$row.railCarNumber } else { $null }
        })
      }
    }

    $itemIds = @($normalized.dispatchOrderItemId | Sort-Object -Unique)
    if (-not $errors.Count -and $itemIds.Count -ne $freightIds.Count) {
      $errors.Add('Pilot order item IDs are not one-to-one with TMW freight lines')
    }
    $expectedItemIds = @($expectedItems.dispatchOrderItemId | ForEach-Object { [long]$_ } | Sort-Object -Unique)
    if (-not $errors.Count -and @($expectedItemIds | Where-Object { $_ -notin $itemIds }).Count) {
      $errors.Add('Resolved TMW freight does not cover every expected Pilot order item')
    }
    if ($errors.Count) {
      $deferred.Add([pscustomobject]@{
        tmwOrderId = [long]$tmwOrder.Name
        dispatchOrderId = [long]$pilotId
        reason = (@($errors | Sort-Object -Unique) -join '; ')
      })
      continue
    }

    $payload = [Collections.Generic.List[object]]::new()
    foreach ($row in $normalized) {
      $payload.Add([pscustomobject][ordered]@{
        grossGallons = $row.grossGallons
        netGallons = $row.netGallons
        billOfLadingNumber = $row.billOfLadingNumber
        dispatchOrderId = [long]$pilotId
        dispatchOrderItemId = $row.dispatchOrderItemId
        dropDateTime = $row.dropDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
        startPullDateTime = $row.startPullDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
        endPullDateTime = $row.endPullDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
        railCarNumber = $row.railCarNumber
      })
    }

    $ready.Add([pscustomobject]@{
      key = ('{0}/{1}' -f $pilotId, (@($payload | ForEach-Object {
        '{0}:{1}' -f $_.dispatchOrderItemId, $_.billOfLadingNumber
      }) -join ','))
      tmwOrderId = [long]$tmwOrder.Name
      dispatchOrderId = [long]$pilotId
      freightLines = $freightIds.Count
      payload = @($payload)
    })
  }

  [pscustomobject]@{
    ready = @($ready)
    deferred = @($deferred)
  }
}

# Pilot orders around each TMW order date, plus Pilot's available BOLs for the legacy product match
function Get-PilotBolContext {
  param([Parameter(Mandatory)][AllowEmptyCollection()]$TmwRows, [Parameter(Mandatory)]$Session)
  $ordersById = @{}
  $dates = @($TmwRows.orderDate | Where-Object { $_ } | ForEach-Object { ([datetime]$_).Date } | Sort-Object -Unique)
  if (-not $dates.Count) { throw 'TMW BOL candidates have no order dates for Pilot correlation.' }
  foreach ($date in $dates) {
    foreach ($order in @(Get-PilotOrder -Session $Session -StartDate $date.AddDays(-1) -EndDate $date.AddDays(2))) {
      $ordersById[[string]$order.dispatchOrderId] = $order
    }
  }
  [pscustomobject]@{ orders = @($ordersById.Values); availableBols = @(Get-PilotBol -Session $Session) }
}

# one order's completion; Pilot status 4 is the acknowledgement, its status text can be stale
function Send-PilotBol {
  param([Parameter(Mandatory)]$Batch, [Parameter(Mandatory)]$Session)
  $response = Set-PilotBol -Session $Session -Payload $Batch.payload
  if ($response.status -ne 'success') { throw "Pilot BOL update failed for $($Batch.key): $($response.status)" }
  $returned = $response.data.payload
  if ([long]$returned.dispatchOrderId -ne [long]$Batch.dispatchOrderId) { throw "Pilot BOL response order mismatch for $($Batch.key)." }
  if ([int]$returned.dispatchOrderStatusTypeId -ne 4) { throw "Pilot BOL response did not Kiosk order $($Batch.dispatchOrderId)." }
  [int]$returned.dispatchOrderStatusTypeId
}

# DataAgent formatter: TMW rows in, plan file out
function Save-PilotBolPlan {
  param($Data, [hashtable]$Options)
  $session = New-PilotCarrierSession $Options.Pilot
  $rows = @($Data)
  $context = Get-PilotBolContext -TmwRows $rows -Session $session
  $plan = New-PilotBolPlan -TmwRows $rows -PilotOrders $context.orders -AvailableBols $context.availableBols
  Write-Log "Orders : $(@($rows | Group-Object tmwOrderId).Count) completed in TMW, $(@($plan.ready).Count) ready, $(@($plan.deferred).Count) deferred"
  foreach ($item in @($plan.deferred)) { Write-Log "Waiting: TMW $($item.tmwOrderId): $($item.reason)" }
  $null = New-Item -ItemType Directory -Force (Split-Path $Options.Path)
  [pscustomobject]@{ ready = @($plan.ready); deferred = @($plan.deferred) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Options.Path
}

# DataAgent destination: send every ready order, in parallel; failures retry in the next overlapping window
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
      $status = & (Import-Module $using:module -PassThru) { param($b, $s) Send-PilotBol -Batch $b -Session $s } $batch $using:session
      [pscustomobject]@{ ok = $true; batch = $batch; status = $status; error = $null }
    } catch {
      [pscustomobject]@{ ok = $false; batch = $batch; status = $null; error = $_.Exception.Message }
    }
  } -ThrottleLimit $throttle)
  foreach ($result in $results) {
    $bols = @($result.batch.payload.billOfLadingNumber) -join ','
    if ($result.ok) { Write-Log "Sent   : TMW $($result.batch.tmwOrderId), Pilot $($result.batch.dispatchOrderId), BOL $bols, status $($result.status)" }
    else { Write-Log "Failed : TMW $($result.batch.tmwOrderId), Pilot $($result.batch.dispatchOrderId): $($result.error)" }
  }
  $failed = @($results | Where-Object { -not $_.ok })
  if ($failed.Count) { throw "$($failed.Count) Pilot BOL request(s) failed; the next run retries them." }
}
