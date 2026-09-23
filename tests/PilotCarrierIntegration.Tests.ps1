BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  function Plan($TmwRows, $PilotOrders, $AvailableBols) {
    & (Get-Module PilotCarrierIntegration) { param($t, $o, $b) New-PilotBolPlan -TmwRows $t -PilotOrders $o -AvailableBols $b } $TmwRows $PilotOrders $AvailableBols
  }
}

Describe 'Pilot BOL completion plan' {
  BeforeEach {
    $tmwRows = @(Get-Content "$PSScriptRoot/fixtures/tmw-bols.json" -Raw | ConvertFrom-Json)
    $pilotOrders = @(
      [pscustomobject]@{
        dispatchOrderId = 12025078
        dispatchOrderItems = @(
          [pscustomobject]@{ dispatchOrderItemId = 12690001; productSystemId = 963; isDeleted = $false }
          [pscustomobject]@{ dispatchOrderItemId = 12690002; productSystemId = 952; isDeleted = $false }
        )
      }
      [pscustomobject]@{
        dispatchOrderId = 12024244
        dispatchOrderItems = @(
          [pscustomobject]@{ dispatchOrderItemId = 12690003; productSystemId = 954; isDeleted = $false }
        )
      }
    )
    $availableBols = @(
      [pscustomobject]@{ orderNumber = 12025078; bolNumber = 967385; product360Id = 963; grossGallons = 4501; netGallons = 4406 }
      [pscustomobject]@{ orderNumber = 12025078; bolNumber = 967385; product360Id = 952; grossGallons = 3499; netGallons = 3445 }
    )
  }

  It 'plans multi-freight orders with a complete item and BOL set' {
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready).Count | Should -Be 2
    @($plan.deferred).Count | Should -Be 0
    $multi = @($plan.ready | Where-Object tmwOrderId -eq 10670001)[0]
    @($multi.payload).Count | Should -Be 2
    @($multi.payload.dispatchOrderItemId) | Should -Be @(12690002, 12690001)
    @($multi.payload.grossGallons) | Should -Be @(3499, 4500)
  }

  It 'plans valid single-freight rows in the overlapping activity window' {
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready.dispatchOrderId) | Should -Be @(12025078, 12024244)
  }

  It 'defers the entire order until every expected freight has a BOL' {
    $tmwRows[1].bolNumber = $null
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready).Count | Should -Be 1
    @($plan.deferred).Count | Should -Be 1
    @($plan.deferred.reason | Where-Object { $_ -match 'invalid BOL' }).Count | Should -Be 1
  }

  It 'resolves legacy freight without OID through exact Pilot BOL product rows' {
    $tmwRows[0].pilotOrderItemId = $null
    $tmwRows[1].pilotOrderItemId = $null
    $plan = Plan $tmwRows $pilotOrders $availableBols
    $multi = @($plan.ready | Where-Object tmwOrderId -eq 10670001)[0]
    @($multi.payload.dispatchOrderItemId) | Should -Be @(12690002, 12690001)
  }

  It 'defers the entire legacy order when a BOL product match is ambiguous' {
    $tmwRows[0].pilotOrderItemId = $null
    $tmwRows[1].pilotOrderItemId = $null
    $availableBols += [pscustomobject]@{
      orderNumber = 12025078
      bolNumber = 967385
      product360Id = 963
      grossGallons = 3499
      netGallons = 3445
    }
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready.dispatchOrderId) | Should -Not -Contain 12025078
    @($plan.deferred.reason | Where-Object { $_ -match 'ambiguous available-BOL product match' }).Count |
      Should -Be 1
  }

  It 'defers an order when item IDs are not one-to-one with freight' {
    $tmwRows[1].pilotOrderItemId = $tmwRows[0].pilotOrderItemId
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready).Count | Should -Be 1
    @($plan.deferred).Count | Should -Be 1
    $plan.deferred[0].reason | Should -Match 'not one-to-one'
  }

  It 'defers the order when Pilot expects another item' {
    $tmwRows = @($tmwRows | Where-Object freightId -ne 1031069)
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready.dispatchOrderId) | Should -Not -Contain 12025078
    @($plan.deferred.reason | Where-Object { $_ -match 'Pilot expects 2 active items' }).Count | Should -Be 1
  }

  It 'defers a nonnumeric Pilot PO reference' {
    $tmwRows[0].pilotOrderRef = 'PILOT-UNKNOWN'
    $tmwRows[1].pilotOrderRef = 'PILOT-UNKNOWN'
    $plan = Plan $tmwRows $pilotOrders $availableBols
    @($plan.ready).Count | Should -Be 1
    $plan.deferred[0].reason | Should -Match 'not a positive numeric dispatchOrderId'
  }
}


Describe 'a BOL run through DataAgent' {
  BeforeAll {
    $global:PcJob = Join-Path $TestDrive 'job'
    New-Item -ItemType Directory $PcJob | Out-Null
    'select 1' | Set-Content "$PcJob/get-data.sql"
    $env:PC_TEST_SECRET = 'from-env-secret'
    function Set-PcSettings([hashtable]$Extra = @{}) {
      $settings = @{
        keepdays = 10; purgefiles = '*.log'
        pilot = @{ base_url = 'https://pilot.example/public/carrier'; token_url = 'https://login.example/token'; scope = 's'; client_id = 'id'; client_secret = 'env:PC_TEST_SECRET'; carrier_id = 123 }
        tmw = @{ InputFile = 'get-data.sql'; ConnectionString = 'x'; Variable = @('BillTo=ACME', 'LookbackMinutes=120') }
      }
      foreach ($key in $Extra.Keys) { $settings[$key] = $Extra[$key] }
      $settings | ConvertTo-Json -Depth 8 | Set-Content "$PcJob/settings.json"
    }
    function Get-PcLog { Get-Content (Join-Path $PcJob ('{0:yyyyMMdd}.log' -f (Get-Date))) | ForEach-Object { ($_ -split "`t")[-1] } }
  }
  BeforeEach {
    Remove-Item "$PcJob/out", "$PcJob/*.log" -Recurse -Force -ErrorAction Ignore
    Set-Location $TestDrive
    $global:PcRows = @(Get-Content "$PSScriptRoot/fixtures/tmw-bols.json" -Raw | ConvertFrom-Json)
    Mock Invoke-Sqlcmd -ModuleName DataAgent { $global:PcRows }
    Mock Get-PilotOrder -ModuleName PilotCarrierIntegration {
      @(
        [pscustomobject]@{ dispatchOrderId = 12025078; dispatchOrderItems = @([pscustomobject]@{ dispatchOrderItemId = 12690001; productSystemId = 963; isDeleted = $false }, [pscustomobject]@{ dispatchOrderItemId = 12690002; productSystemId = 952; isDeleted = $false }) }
        [pscustomobject]@{ dispatchOrderId = 12024244; dispatchOrderItems = @([pscustomobject]@{ dispatchOrderItemId = 12690003; productSystemId = 954; isDeleted = $false }) }
      )
    }
    Mock Get-PilotBol -ModuleName PilotCarrierIntegration { @() }
  }
  It 'dry_run plans from TMW rows and Pilot orders, reads the secret from the environment, sends nothing' {
    Set-PcSettings @{ dry_run = $true }
    Mock New-PilotSession -ModuleName PilotCarrierIntegration { [pscustomobject]@{ BaseUrl = $BaseUrl; Secret = $Credential.GetNetworkCredential().Password } }
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    $log = Get-PcLog
    $log | Should -Contain 'Orders : 2 completed in TMW, 2 ready, 0 deferred'
    $log | Should -Contain 'Dry run, not sending: Pilot 12025078, Pilot 12024244'
    $log | Should -Contain 'End'
    Should -Invoke New-PilotSession -ModuleName PilotCarrierIntegration -ParameterFilter { $Credential.GetNetworkCredential().Password -eq 'from-env-secret' }
    Should -Invoke Invoke-Sqlcmd -ModuleName DataAgent -Times 1 -Exactly -ParameterFilter { $InputFile -eq 'get-data.sql' -and @($Variable) -contains 'LookbackMinutes=120' }
    Test-Path "$TestDrive/out" | Should -BeFalse
  }
  It 'logs the idle marker when TMW has no completions' {
    Set-PcSettings @{ dry_run = $true }
    $global:PcRows = @()
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    Get-PcLog | Should -Contain 'No data available'
    Should -Invoke Get-PilotOrder -ModuleName PilotCarrierIntegration -Times 0
  }
}

Describe 'sending one completion' {
  BeforeAll {
    $batch = [pscustomobject]@{ key = 'k'; dispatchOrderId = 12024244; payload = @([pscustomobject]@{ dispatchOrderId = 12024244; dispatchOrderItemId = 12690003 }) }
    $session = [pscustomobject]@{ BaseUrl = 'https://pilot.example' }
    function Send($b, $s) { & (Get-Module PilotCarrierIntegration) { param($x, $y) Send-PilotBol -Batch $x -Session $y } $b $s }
  }
  It 'accepts status 4 even when the status text is stale' {
    Mock Set-PilotBol -ModuleName PilotCarrierIntegration { [pscustomobject]@{ status = 'success'; data = [pscustomobject]@{ payload = [pscustomobject]@{ dispatchOrderId = 12024244; dispatchOrderStatusTypeId = 4; dispatchOrderStatusTypeName = 'Created' } } } }
    Send $batch $session | Should -Be 4
    Should -Invoke Set-PilotBol -ModuleName PilotCarrierIntegration -Times 1 -Exactly -ParameterFilter { @($Payload).Count -eq 1 }
  }
  It 'throws when Pilot does not acknowledge the order' {
    Mock Set-PilotBol -ModuleName PilotCarrierIntegration { [pscustomobject]@{ status = 'success'; data = [pscustomobject]@{ payload = [pscustomobject]@{ dispatchOrderId = 12024244; dispatchOrderStatusTypeId = 2 } } } }
    { Send $batch $session } | Should -Throw '*did not Kiosk*'
  }
}
