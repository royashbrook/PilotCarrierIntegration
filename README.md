# PilotCarrierIntegration

Pilot carrier feeds as [DataAgent](https://github.com/royashbrook/DataAgent) runs, on
[PilotCarrierClient](https://github.com/royashbrook/PilotCarrierClient). DataAgent runs each feed in
its settings file's folder, so the log, cleanup and idle marker match any other DataAgent job.

```powershell
Import-Module PilotCarrierIntegration   # brings DataAgent and PilotCarrierClient with it
Invoke-PilotCarrierBols "$PSScriptRoot/settings.json"     # or Invoke-PilotCarrierOrders, Invoke-PilotCarrierDocuments
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

## Documents

Scanned BOLs -> the Pilot order item they belong to -> Pilot `PUT /document`, each once. A
[DocumentAgent](https://github.com/royashbrook/DocumentAgent) run, so documents are fetched, sent
one at a time and kept in receipts the same way as any other document job.

The feed's own query returns one row per scanned document and order reference: `EbeDocumentId`,
`DocumentType`, `OrderNumber`, `BolNumber`, `PilotOrderRef` (Pilot's `dispatchOrderId`), `IndexedAt`,
and optionally `DispatchOrderId`, `DispatchOrderItemId` and `AttachmentName`. The run adds
`LookbackDays=<lookback_days>` to the query's variables, and reads Pilot orders over the same days.

- A document goes only when Pilot's BOL list has its BOL on exactly one of its orders, and that order
  has an item carrying the BOL. A single-item order matches on the order's BOL. Otherwise it waits,
  and the log says why.
- One document can go to several items of an order, one upload each.
- A document already attached to the item on Pilot is skipped, receipt or not.
- The upload is the PDF inline, with the scan's index time in UTC as `bolDatetime`. The index time
  is read as the runner's local time.
- Receipts are `sent/<order>-<item>-<document>.json`. A refused upload gets no receipt, the rest
  continue, and the run fails naming it.

```json
{
  "keepdays": 10,
  "purgefiles": "*.log",
  "lookback_days": 7,
  "pilot": { "base_url": "env:PILOT_BASE_URL", "...": "as above", "carrier_id": 123 },
  "query": {
    "InputFile": "get-data.sql",
    "ConnectionString": "env:IMAGING_CONNECTION_STRING",
    "Variable": ["BillTo=BILLTO"],
    "QueryTimeout": 1800
  },
  "documents": {
    "adapter": "ships",
    "args": { "BaseUrl": "https://host/ships5web/", "Username": "reader", "Password": "env:READER_PASSWORD" }
  }
}
```

`query` is passed to `Invoke-Sqlcmd`, and `documents` is any DocumentAgent documents source. To
test, add `"dry_run": true`: the run reads and plans, names what would go, and fetches and sends
nothing. `max_sends` caps the uploads per run.

`New-PilotCarrierDocumentConfig` returns the DataAgent config without running it.
