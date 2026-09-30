BeforeAll {
  Import-Module "$PSScriptRoot/../PilotCarrierIntegration/PilotCarrierIntegration.psd1" -Force
  function Plan($TmwRows) {
    & (Get-Module PilotCarrierIntegration) { param($t) New-PilotBolPlan -TmwRows $t } $TmwRows
  }
}

Describe 'Pilot BOL completion plan' {
  BeforeEach {
    $tmwRows = @(Get-Content "$PSScriptRoot/fixtures/tmw-bols.json" -Raw | ConvertFrom-Json)
  }

  It 'plans each order from TMW alone, one line per freight with its Pilot item' {
    $plan = Plan $tmwRows
    @($plan.ready.dispatchOrderId) | Should -Be @(12025078, 12024244)
    @($plan.deferred).Count | Should -Be 0
    $multi = @($plan.ready | Where-Object tmwOrderId -eq 10670001)[0]
    @($multi.payload.dispatchOrderItemId) | Should -Be @(12690002, 12690001)
    @($multi.payload.grossGallons) | Should -Be @(3499, 4500)
    @($multi.payload.billOfLadingNumber) | Should -Be @(967385, 967385)
    $multi.payload[0].dropDateTime | Should -Be '2026-08-02T09:09:00'
  }

  It 'holds the whole order while any line is missing its BOL' {
    $tmwRows[1].bolNumber = $null
    $plan = Plan $tmwRows
    @($plan.ready.dispatchOrderId) | Should -Be @(12024244)
    $plan.deferred[0].reason | Should -Be 'freight 1031069: missing BOL'
  }

  It 'holds the whole order while any line has no Pilot item id, and names everything missing' {
    $tmwRows[0].pilotOrderItemId = $null
    $tmwRows[0].netGallons = $null
    $plan = Plan $tmwRows
    @($plan.ready.dispatchOrderId) | Should -Be @(12024244)
    $plan.deferred[0].reason | Should -Be 'freight 1031068: missing Pilot item id (OID), net gallons'
  }

  It 'holds an order when two lines carry the same Pilot item id' {
    $tmwRows[1].pilotOrderItemId = $tmwRows[0].pilotOrderItemId
    $plan = Plan $tmwRows
    $plan.deferred[0].reason | Should -Match 'same Pilot item id'
  }

  It 'holds an order with no numeric Pilot PO reference' {
    $tmwRows[0].pilotOrderRef = 'PILOT-UNKNOWN'
    $tmwRows[1].pilotOrderRef = 'PILOT-UNKNOWN'
    $plan = Plan $tmwRows
    @($plan.ready).Count | Should -Be 1
    $plan.deferred[0].reason | Should -Match 'not a positive numeric dispatchOrderId'
  }

  It 'holds every TMW order that shares one Pilot order, ready or not' {
    $tmwRows[2].pilotOrderRef = '12025078'
    $plan = Plan $tmwRows
    @($plan.ready).Count | Should -Be 0
    @($plan.deferred.tmwOrderId) | Should -Be @(10670001, 10670002)
    $plan.deferred[0].reason | Should -Be 'Pilot order 12025078 is also on TMW 10670002'
    $plan.deferred[1].reason | Should -Be 'Pilot order 12025078 is also on TMW 10670001'

    $tmwRows[2].bolNumber = $null
    $plan = Plan $tmwRows
    @($plan.ready).Count | Should -Be 0
    $plan.deferred[1].reason | Should -Match '^freight \d+: missing BOL; Pilot order 12025078 is also on TMW 10670001$'
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
        tmw = @{ InputFile = 'get-data.sql'; ConnectionString = 'x'; Variable = @('BillTo=ACME', 'LookbackMinutes=1440') }
      }
      foreach ($key in $Extra.Keys) { $settings[$key] = $Extra[$key] }
      $settings | ConvertTo-Json -Depth 8 | Set-Content "$PcJob/settings.json"
    }
    function Get-PcLog { Get-Content (Join-Path $PcJob ('{0:yyyyMMdd}.log' -f (Get-Date))) | ForEach-Object { ($_ -split "`t")[-1] } }
    function Get-PcCache($Id) { Get-Content "$PcJob/cache/$Id.json" -Raw | ConvertFrom-Json -DateKind String }
  }
  BeforeEach {
    Remove-Item "$PcJob/out", "$PcJob/*.log", "$PcJob/cache" -Recurse -Force -ErrorAction Ignore
    Set-Location $TestDrive
    $global:PcRows = @(Get-Content "$PSScriptRoot/fixtures/tmw-bols.json" -Raw | ConvertFrom-Json)
    # the read goes through DataAgent's sql source, called from this module's scope
    Mock Invoke-Sqlcmd -ModuleName PilotCarrierIntegration { $global:PcRows }
    Mock New-PilotSession -ModuleName PilotCarrierIntegration { [pscustomobject]@{ BaseUrl = $BaseUrl } }
  }
  It 'dry_run plans from TMW alone, never calls Pilot, sends nothing' {
    Set-PcSettings @{ dry_run = $true }
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    $log = Get-PcLog
    $log | Should -Contain 'Orders : 2 completed in TMW, 2 ready, 0 waiting, 0 already done'
    $log | Should -Contain 'Dry run, not sending: Pilot 12025078, Pilot 12024244'
    $log | Should -Contain 'End'
    Should -Invoke New-PilotSession -ModuleName PilotCarrierIntegration -Times 0
    Should -Invoke Invoke-Sqlcmd -ModuleName PilotCarrierIntegration -Times 1 -Exactly -ParameterFilter {
      $InputFile -eq 'get-data.sql' -and @($Variable) -contains 'LookbackMinutes=1440' -and @($Variable) -contains 'Since=none' }
    Test-Path "$PcJob/cache" | Should -BeFalse
  }
  It 'reads the Pilot secret from the environment for the send, and keeps the cache two days' {
    Set-PcSettings
    $config = New-PilotCarrierBolConfig "$PcJob/settings.json"
    $config.dst.args.Pilot.client_secret | Should -Be 'from-env-secret'
    $config.dst.args.Cache | Should -Be 'cache'
    $config.src.args.KeepDays | Should -Be 2
    (New-PilotCarrierBolConfig "$PcJob/settings.json").src.args.Tmw.Variable | Should -Contain 'Since=none'
  }
  It 'holds back an order already done unchanged, and sends it again once it changes' {
    Set-PcSettings @{ dry_run = $true }
    $hash = & (Get-Module PilotCarrierIntegration) {
      param($rows)
      Get-PilotBolHash ((New-PilotBolPlan -TmwRows $rows).ready | Where-Object dispatchOrderId -eq 12025078).payload
    } $global:PcRows
    New-Item -ItemType Directory "$PcJob/cache" | Out-Null
    @{ state = 'done'; sent_at = [datetime]::UtcNow.ToString('o'); hash = $hash } | ConvertTo-Json | Set-Content "$PcJob/cache/12025078.json"
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    $log = Get-PcLog
    $log | Should -Contain 'Orders : 2 completed in TMW, 1 ready, 0 waiting, 1 already done'
    $log | Should -Contain 'Dry run, not sending: Pilot 12024244'
    @($log | Where-Object { $_ -like 'Already: *Pilot 12025078, done *' }).Count | Should -Be 1

    @{ state = 'done'; sent_at = [datetime]::UtcNow.ToString('o'); hash = 'something else' } | ConvertTo-Json | Set-Content "$PcJob/cache/12025078.json"
    Remove-Item "$PcJob/*.log" -Force
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    Get-PcLog | Should -Contain 'Dry run, not sending: Pilot 12025078, Pilot 12024244'
  }
  It 'reads from the cursor once a send leaves one, and looks back until then' {
    Set-PcSettings
    New-Item -ItemType Directory "$PcJob/cache" | Out-Null
    @{ since = '2026-08-02T10:15:00.250' } | ConvertTo-Json | Set-Content "$PcJob/cache/cursor.json"
    (New-PilotCarrierBolConfig "$PcJob/settings.json").src.args.Tmw.Variable | Should -Contain 'Since=2026-08-02T10:15:00.250'
  }
  It 'stages every order before posting, stays green when Pilot is not reached, and moves the cursor' {
    Set-PcSettings
    Mock Get-PilotToken -ModuleName PilotCarrierIntegration { throw 'token service down' }
    { Invoke-PilotCarrierBols "$PcJob/settings.json" } | Should -Not -Throw
    $log = Get-PcLog
    @($log | Where-Object { $_ -like 'Failed : *no token: token service down' }).Count | Should -Be 2
    @($log | Where-Object { $_ -like 'Summary: 0 sent, 2 pending (oldest staged *Z), cursor 2026-08-02T10:15:00.250' }).Count | Should -Be 1
    $cached = Get-PcCache 12024244
    $cached.state | Should -Be 'pending'
    $cached.pilot | Should -Be 'not reached: no token: token service down'
    @($cached.rows).Count | Should -Be 1
    (Get-Content "$PcJob/cache/cursor.json" -Raw | ConvertFrom-Json -DateKind String).since | Should -Be '2026-08-02T10:15:00.250'
  }
  It 'reads a pending order again from its cache file when the query no longer returns it, and drops it after keep_days' {
    Set-PcSettings
    Mock Get-PilotToken -ModuleName PilotCarrierIntegration { throw 'token service down' }
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    $staged = (Get-PcCache 12024244).staged_at

    $global:PcRows = @()
    Remove-Item "$PcJob/*.log" -Force
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    $log = Get-PcLog
    @($log | Where-Object { $_ -like 'Pending: TMW 1067000?, Pilot 120*, staged *, read again from the cache' }).Count | Should -Be 2
    $log | Should -Contain 'Orders : 2 completed in TMW, 2 ready, 0 waiting, 0 already done'
    @($log | Where-Object { $_ -like 'Failed : *no token: token service down' }).Count | Should -Be 2
    (Get-PcCache 12024244).staged_at | Should -Be $staged

    $old = Get-Content "$PcJob/cache/12024244.json" -Raw | ConvertFrom-Json
    $old.staged_at = [datetime]::UtcNow.AddDays(-3).ToString('o')
    $old | ConvertTo-Json -Depth 8 | Set-Content "$PcJob/cache/12024244.json"
    Remove-Item "$PcJob/*.log" -Force
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    $log = Get-PcLog
    @($log | Where-Object { $_ -like 'Dropped: TMW 10670002, Pilot 12024244, pending since *, last: not reached: no token: token service down' }).Count | Should -Be 1
    Test-Path "$PcJob/cache/12024244.json" | Should -BeFalse
    $log | Should -Contain 'Orders : 1 completed in TMW, 1 ready, 0 waiting, 0 already done'
    @($log | Where-Object { $_ -like 'Summary: 0 sent, 1 pending *, cursor 2026-08-02T10:15:00.250' }).Count | Should -Be 1
  }
  It 'logs the idle marker when TMW has no completions' {
    Set-PcSettings @{ dry_run = $true }
    $global:PcRows = @()
    Invoke-PilotCarrierBols "$PcJob/settings.json"
    Get-PcLog | Should -Contain 'No data available'
  }
}

Describe 'sending one completion' {
  BeforeAll {
    $batch = [pscustomobject]@{ dispatchOrderId = 12024244; payload = @([pscustomobject]@{ dispatchOrderId = 12024244; dispatchOrderItemId = 12690003 }) }
    $session = [pscustomobject]@{ BaseUrl = 'https://pilot.example' }
    function Send($b, $s) { & (Get-Module PilotCarrierIntegration) { param($x, $y) Send-PilotBol -Batch $x -Session $y } $b $s }
    function Answer($Status, $AllItems) {
      [pscustomobject]@{ status = 'success'; data = [pscustomobject]@{ payload = [pscustomobject]@{
        dispatchOrderId = 12024244; dispatchOrderStatusTypeId = $Status; dispatchOrderStatusTypeName = 'Created'; allItemsHasBols = $AllItems } } }
    }
  }
  It 'is done when Pilot answers Kiosked with a BOL on every item, whatever the status text says' {
    Mock Set-PilotBol -ModuleName PilotCarrierIntegration { Answer 4 $true }
    $outcome = Send $batch $session
    $outcome.done | Should -BeTrue
    $outcome.note | Should -Be 'status 4, allItemsHasBols True'
    Should -Invoke Set-PilotBol -ModuleName PilotCarrierIntegration -Times 1 -Exactly -ParameterFilter { @($Payload).Count -eq 1 }
  }
  It 'is not done, and says so, when Pilot answers without every item carrying a BOL' {
    Mock Set-PilotBol -ModuleName PilotCarrierIntegration { Answer 4 $false }
    $outcome = Send $batch $session
    $outcome.done | Should -BeFalse
    $outcome.note | Should -Be 'posted, Pilot shows order 12024244 status 4, allItemsHasBols False'
  }
  It 'records a post Pilot turns down instead of failing' {
    Mock Set-PilotBol -ModuleName PilotCarrierIntegration { [pscustomobject]@{ status = 'error'; data = $null } }
    (Send $batch $session).note | Should -Be 'turned down: error'
  }
}
