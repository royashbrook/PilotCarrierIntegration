# DataAgent destination for a dry run: name what would go, send nothing
param($Data, [hashtable] $Options)
$ready = @((Get-Content -LiteralPath ([string]$Data) -Raw | ConvertFrom-Json).ready)
l "Dry run, not sending: $(@($ready | ForEach-Object { "Pilot $($_.dispatchOrderId)" }) -join ', ')"
