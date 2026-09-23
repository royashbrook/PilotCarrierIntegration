# PilotCarrierIntegration

Pilot carrier feeds as [DataAgent](https://github.com/royashbrook/DataAgent) runs, on
[PilotCarrierClient](https://github.com/royashbrook/PilotCarrierClient). DataAgent runs each feed in
its settings file's folder, so the log, cleanup and idle marker match any other DataAgent job.

```powershell
Import-Module PilotCarrierIntegration   # brings DataAgent and PilotCarrierClient with it
Invoke-PilotCarrierBols "$PSScriptRoot/settings.json"     # or Invoke-PilotCarrierOrders
```

## BOL completions

TMW completed freight -> correlate to Pilot order items -> Pilot `PUT /bol`.

The feed's own query returns completed freight, one row per freight line. It needs `tmwOrderId`,
`pilotOrderRef` (the TMW `PO`, Pilot's `dispatchOrderId`), `orderDate`, `freightId`,
`freightSequence`, `pilotOrderItemId` (the freight `OID`), `bolNumber`, `grossGallons`, `netGallons`,
`startPullDateTime`, `endPullDateTime`, `dropDateTime` and optionally `railCarNumber`.

| TMW value | Pilot field |
|---|---|
| order `PO` | `dispatchOrderId` |
| freight `OID` | `dispatchOrderItemId` |
| freight BOL | `billOfLadingNumber` |
| gross and net quantities | `grossGallons`, `netGallons` |
| pickup events | `startPullDateTime`, `endPullDateTime` |
| delivery event | `dropDateTime` |

- Freight without an `OID` is matched to a Pilot item only through one exact Pilot BOL and product
  match, within 2 gallons.
- A whole order waits until every active Pilot item has one unambiguous freight line and BOL.
- Ready orders are sent in parallel. Pilot status `4` is the acknowledgement; its status text can
  be stale.
- Every run sends the current snapshot of the query's window. Replays are expected and harmless.
  There is no in-run retry or sent ledger: a failure goes again in the next overlapping window, and
  the run ends red naming it.

```json
{
  "keepdays": 10,
  "purgefiles": "*.log",
  "pilot": {
    "base_url": "env:PILOT_BASE_URL",
    "token_url": "env:PILOT_TOKEN_URL",
    "scope": "env:PILOT_SCOPE",
    "client_id": "env:PILOT_CLIENT_ID",
    "client_secret": "env:PILOT_CLIENT_SECRET",
    "carrier_id": 123
  },
  "tmw": {
    "InputFile": "get-data.sql",
    "ConnectionString": "env:TMW_CONNECTION_STRING",
    "Variable": ["LookbackMinutes=120"],
    "QueryTimeout": 1800
  },
  "throttle_limit": 8
}
```

`tmw` is passed to `Invoke-Sqlcmd`. Any value written as `env:NAME` is read from that environment
variable, so the committed file holds names, never secrets. To test, add `"dry_run": true`: the run
plans and names what would go, and sends nothing.

`New-PilotCarrierBolConfig` returns the DataAgent config without running it.

## Orders

Pilot carrier orders -> translate -> stage each one in TMW DataExchange at EDI state 10, for people
to accept or reject in TMW.

- Orders are read over a rolling window (`poll.window_days`, 30 by default, at least 2) and orders
  whose `poll.status_field` is in `poll.skip_values` are skipped, like Kiosked ones.
- Pilot's reference data only fills in names and addresses. TMW maps each stop by its id. A missing
  terminal, location or contract id stages as `UNKNOWN`; an id the reference data lacks keeps the
  id. Either way that stop comes over with no address for people to finish in EDI. A partial
  address, a missing delivery window or no positive gallons still stops the order.
- One order is one transaction through TMW's own `dx_*` procedures, with a matching DX archive.
  The Pilot id is the idempotency key: an unchanged order is skipped, a changed one is flagged for
  review instead of overwriting TMW.
- The SQL checks `db_name()` against `tmw.expected_database` before it writes anything.
- Orders stage in parallel (`tmw.max_parallel`) with retries (`tmw.retry_attempts`).

```json
{
  "keepdays": 10,
  "purgefiles": "*.log",
  "pilot": { "base_url": "env:PILOT_BASE_URL", "...": "as above", "carrier_id": 123 },
  "poll": { "window_days": 30, "status_field": "dispatchOrderStatusTypeId", "skip_values": [4] },
  "create": { "partner": "PILOT", "billto": "BILLTO", "division": "DIV", "scac": "SCAC" },
  "tmw": {
    "connection_string": "env:TMW_CONNECTION_STRING",
    "expected_database": "TMW_Test",
    "max_parallel": 10,
    "retry_attempts": 3,
    "retry_delay_seconds": 2,
    "command_timeout_seconds": 120
  },
  "idempotency": { "pilot_id_as_po_ref": true, "archive_source_prefix": "PILOTAPI" }
}
```

TMW needs the trading partner (`create.partner`) set up with its bill-to and DX 204 settings, and an
`UNKNOWN` company and commodity. To test, add `"dry_run": true`: every order runs through the full
staging SQL and is rolled back.

`New-PilotCarrierOrderConfig` returns the DataAgent config without running it.
