# DataAgent source: Pilot orders ready to stage
param($Data, [hashtable] $Options)
& (Get-Module PilotCarrierIntegration) { param($o) Read-PilotCarrierOrders -Options $o } $Options
