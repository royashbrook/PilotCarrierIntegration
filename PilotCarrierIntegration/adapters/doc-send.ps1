# DocumentAgent delivery: upload one document to its Pilot order item
param([string] $Key, [string[]] $Files, [hashtable] $Options, [object[]] $Documents)
& (Get-Module PilotCarrierIntegration) { param($k, $f, $o, $d) Send-PilotCarrierDocument -Key $k -Files $f -Options $o -Documents $d } $Key $Files $Options $Documents
