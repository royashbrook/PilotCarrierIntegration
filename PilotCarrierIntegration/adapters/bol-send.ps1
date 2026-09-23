# DataAgent destination: send every ready completion to Pilot
param($Data, [hashtable] $Options)
& (Get-Module PilotCarrierIntegration) { param($p, $o) Send-PilotBolPlan -Path $p -Options $o } ([string]$Data) $Options
