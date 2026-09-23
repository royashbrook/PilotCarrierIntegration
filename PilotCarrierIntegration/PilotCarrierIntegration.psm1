# PilotCarrierIntegration: Pilot carrier feeds as DataAgent runs, on PilotCarrierClient.
# Each Invoke-* runs DataAgent in the settings file's folder, so the log and output land there.

. (Join-Path $PSScriptRoot 'Bols.ps1')

# "env:NAME" anywhere in the settings is read from that environment variable, so secrets stay out of the file
function Resolve-EnvValue($Value) {
  if ($Value -is [string]) {
    if ($Value -match '^env:(.+)$') { return [Environment]::GetEnvironmentVariable($Matches[1]) }
    return $Value
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = @{}
    foreach ($key in $Value.Keys) { $copy[$key] = Resolve-EnvValue $Value[$key] }
    return $copy
  }
  if ($Value -is [System.Collections.IList]) { return , @(foreach ($item in $Value) { Resolve-EnvValue $item }) }
  $Value
}

function Read-PilotCarrierSettings([string]$Path) {
  $full = (Resolve-Path -LiteralPath $Path).Path
  $settings = Resolve-EnvValue (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json -AsHashtable)
  $settings.directory = Split-Path $full
  $settings
}

function New-PilotCarrierSession([hashtable]$Pilot) {
  $credential = [pscredential]::new($Pilot.client_id, (ConvertTo-SecureString $Pilot.client_secret -AsPlainText -Force))
  New-PilotSession -BaseUrl $Pilot.base_url -TokenUrl $Pilot.token_url -Scope $Pilot.scope -Credential $credential -CarrierId $Pilot.carrier_id
}

# l returns its line; a source must keep its output stream for records, so the log line goes to the host
function Write-Log([string]$Message) { l $Message | Write-Host }

function Get-AdapterPath([string]$Name) { Join-Path $PSScriptRoot "adapters/$Name.ps1" }

# BOL completions: TMW completed freight (the feed's query) -> plan -> Pilot PUT /bol
function New-PilotCarrierBolConfig {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  $s = Read-PilotCarrierSettings $Settings
  $config = @{
    directory = $s.directory
    src = @{ adapter = 'sql'; args = $s.tmw }
    fmt = @{ adapter = Get-AdapterPath 'bol-plan'; args = @{ Path = 'out/pilot-bol-plan.json'; Pilot = $s.pilot } }
    dst = if ($s.dry_run) {
      @{ adapter = Get-AdapterPath 'bol-dry-run'; args = @{} }
    } else {
      @{ adapter = Get-AdapterPath 'bol-send'; args = @{ Pilot = $s.pilot; ThrottleLimit = $s.throttle_limit } }
    }
  }
  foreach ($name in 'keepdays', 'purgefiles') { if ($s.ContainsKey($name)) { $config[$name] = $s[$name] } }
  $config
}

function Invoke-PilotCarrierBols {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  Invoke-DataAgent (New-PilotCarrierBolConfig $Settings)
}

Export-ModuleMember -Function Invoke-PilotCarrierBols, New-PilotCarrierBolConfig
