# PilotCarrierIntegration

Pilot carrier feeds as [DataAgent](https://github.com/royashbrook/DataAgent) runs, on
[PilotCarrierClient](https://github.com/royashbrook/PilotCarrierClient). DataAgent runs each feed in
its settings file's folder, so the log, cleanup and idle marker match any other DataAgent job.

```powershell
Import-Module PilotCarrierIntegration   # brings DataAgent and PilotCarrierClient with it
Invoke-PilotCarrierBols "$PSScriptRoot/settings.json"     # or Invoke-PilotCarrierOrders, Invoke-PilotCarrierDocuments
```

## BOL completions

TMW completed freight -> one Pilot `PUT /bol` per order, once every line is complete.

The feed's own query returns completed freight, one row per freight line. It needs `tmwOrderId`,
`pilotOrderRef` (the TMW `PO`, Pilot's `dispatchOrderId`), `freightId`,
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

- The order is judged complete from TMW alone: every freight line needs its `OID`, a BOL, gross and
  net gallons, and pull and drop times, and no two lines may share an `OID`. The `OID` is the key on
  Pilot's side, so a line without one waits. Until then the order waits, and the log names what is
  missing.
- A post Kiosks the whole order (status `4`, even with only one item's BOL), so an order goes once,
  every line together. There is no Pilot read first.
- Ready orders are posted in parallel. An order is done when Pilot answers with it Kiosked (status
  `4`; the status text can be stale) and `allItemsHasBols` true. A post to an order already Kiosked
  is answered the same way, so it is simply done.
- Each done order leaves a file in the cache folder, `cache/<dispatchOrderId>.json` (`cache` in settings
  to move it), like the other order feeds: what was sent, a hash of it, and Pilot's answer. The query's
  window overlaps runs; an order that matches its cache file is logged `Already:` and not sent again, and a gallons or BOL correction
  is sent again. A cache file goes `keep_days` (2 by default) after its send.
- An answer that is not done (turned down, or not every item with a BOL) is logged `Not done:` with
  Pilot's answer and tried again next run. The run fails only when Pilot cannot be reached (auth,
  throttling, a server error, a timeout).

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

- Orders are read over a rolling window starting `poll.lookback_days` before today (0 by default) and
  running `poll.window_days` (30 by default, at least 2; Pilot reads at most 30). Pilot's read
  has no status filter, so one filter runs right after it: a status in `poll.include_statuses`
  (Scheduled, `2`, by default), a delivery window that ends after it starts, and at least one active
  item, every one with gallons. An order that fails stays in Pilot and is read again next run.
- The cache folder (`cache`, default `cache`) keeps one file per Pilot order: `staged` with its TMW
  order, or `skipped` with the reason. A staged order is passed over before anything else, and a skip
  reason is logged only when it is new or changes. An order file goes `keep_days` (7 by default)
  after its last update, by the date inside it. A dry run keeps no cache.
- Pilot's location, terminal and contract lists only fill in names and addresses, and TMW maps each
  stop by its id. The lists are kept in the cache (`reference-*.json`) and read from Pilot again when an order names an id the kept copy lacks, or once the kept
  copy is older than `keep_days`. A missing id stages as `UNKNOWN`; an id the lists
  lack keeps the id. Either way that stop comes over with no address for people to finish in EDI. A
  partial address stages too, each missing part marked `MISSING` (state `??`).
- One order is one transaction through TMW's own `dx_*` procedures, with a matching DX archive.
  The Pilot id is the key: an order already in TMW logs `EXISTS` and is left alone, changed or not.
- The SQL checks `db_name()` against `tmw.expected_database` before it writes anything.
- Orders stage in parallel (`tmw.max_parallel`) with retries (`tmw.retry_attempts`).

```json
{
  "keepdays": 10,
  "purgefiles": "*.log",
  "pilot": { "base_url": "env:PILOT_BASE_URL", "...": "as above", "carrier_id": 123 },
  "poll": { "lookback_days": 0, "window_days": 30, "include_statuses": [2] },
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
