# DataAgent destination: stage each order in TMW DataExchange
param($Data, [hashtable] $Options)
& (Get-Module PilotCarrierIntegration) { param($p, $o) Send-PilotOrderPlan -Path $p -Options $o } ([string]$Data) $Options
