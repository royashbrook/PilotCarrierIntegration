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
`startPullDateTime`, `endPullDateTime`, `dropDateTime`, `sourceUpdatedAt` (the latest TMW change on the
order, for the cursor) and optionally `railCarNumber`.

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
- One Pilot order on two TMW orders would be two posts to one Pilot record, each Kiosking it with only
  its own lines, so every TMW order sharing a Pilot id waits, and the log names the other.
- Each order leaves a file in the cache folder, `cache/<dispatchOrderId>.json` (`cache` in settings
  to move it), like the other order feeds: what goes, its TMW rows, a hash of it, its state and Pilot's
  answer. It is written `pending` before the post and marked `done` when Pilot finishes the order. An
  order that matches a done file is logged `Already:` and not sent again, and a gallons or BOL
  correction is sent again. A done file goes `keep_days` (2 by default) after its send. A pending one
  goes `keep_days` after it was first staged, logged `Dropped:`.
- The query reads from a cursor, `cache/cursor.json`, like gravitate: the job passes it as
  `Since=<time>` (`Since=none` before the first run), and the query reads from the earlier of that and
  its own lookback. So a missed run, however long, loses nothing. The cursor moves to the latest change
  read, every run.
- An answer that is not done (turned down, or not every item with a BOL) is logged `Not done:`, and
  not reaching Pilot (auth, throttling, a server error, a timeout) is logged `Failed :`. Either way the
  order stays pending and the run stays green. A pending order the query no longer returns is read
  again from its cache file, logged `Pending:`, so it goes again next run whatever TMW returns. The log
  ends with `Summary: N sent, P pending (oldest staged <time>), cursor <time>`.

For BOL completions, orders and documents, optional `filename_date_format` (`yyyyMMdd`
or `yyyy-MM-dd`) passes filename-day cleanup to DataAgent. The cutoff day is
retained; without the setting, file cleanup uses filesystem age. Business cache
retention remains separate.

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
    "Variable": ["BillTo=ACME", "LookbackMinutes=1440"],
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

### Mapping and checks

The data-only [order-mapping.psd1](PilotCarrierIntegration/order-mapping.psd1) names source paths,
literal values, destinations and validation rules. The bundled table is the default. To own the
mapping in a caller repo, copy that complete file beside settings.json and add
`"order_mapping": "order-mapping.psd1"` to settings. The path is relative to the settings folder,
not the shell's working directory. A branch can change that file without changing the module.

Example rows from the complete table:

```powershell
@{ destination = 'pilotOrderId'; source = 'record.dispatchOrderId'; cast = 'string' }
@{ destination = 'uom'; value = 'GAL' }
@{ destination = 'commodityName'; sources = @('item.productCode', 'item.wraProductDescription'); format = '{0} / {1}' }
```

`Order`, `Freight`, `Pickup` and `Delivery` keep their canonical destinations. A row chooses
`source`, `sources` plus a format, or a literal `value`. A source array uses the first truthy value
(the existing reference-data fallbacks). `default` supplies the existing fallback; `blank = $true`
also treats whitespace as absent. Casts are `string`, `nullable_string` and `datetime`; omitted
casts preserve the source type. Input roots are `record`, `item`, `terminal`, `location`, `contract`,
`context`, and `cfg.create` only. Credential and connection settings are not mapping inputs.

The `Validation` table refers to a mapped field, so a source change follows through its check.
For a formatted field, `part` selects its zero-based input (part 1 is the WRA description).
Scalar checks use regex, for example `pattern = '\S'` for a nonblank value. Gallons use invariant
positive-decimal parsing; scheduled windows use invariant date parsing and end-after-start.
Validation order and messages preserve the prior identity/status/window/quantity/item precedence.
One bad active item still holds the whole order. Regex evaluation has a one-second timeout.
Pre-lookup checks can use only their available record/item/create data, not later reference or
derived values. The reference join keys have the same restriction. Order-level checks cannot
depend on an item. Validation, reference joins and aggregation share the available input context.
Vendor order/item identity rows are shown in the table but cannot be overridden: replay, cache
keys and outbound routing are operational contracts, not configurable payload formatting.

The loader uses `Import-PowerShellDataFile`, not script execution. Malformed configuration,
unsupported targets/casts/checks and blank rejection messages refuse before the Pilot read.
Mapping does not replace the TMW destination type/width contract. Eligibility, exact polling,
reference enrichment, address completion, stop grouping, SQL transactions, retries, `EXISTS` and
cache lifecycle remain code, not configurable expressions or validation failures. The released
0.7.10 canonical orders, EDI archives, SQL and parameters are pinned by parity fixtures.

### Intake

- Orders are read over a rolling window starting `poll.lookback_days` before today (0 by default) and
  running `poll.window_days` (30 by default, at least 2; Pilot reads at most 30). Pilot's read
  has no status filter, so one filter runs right after it. Only Scheduled (`2`) orders can stage;
  `poll.include_statuses` can restrict that, not admit other statuses. Every required field below
  must be filled on every active item. An order that fails stays in Pilot and is read again next run.
- Set `poll.start_from` to `now` for an exact scheduled-start window, for example
  `"poll": { "start_from": "now", "lookback_days": 0, "window_days": 14, "include_statuses": [2] }`.
  The run captures the clock once: scheduled start must be at or after that instant and before
  14 calendar days later, using the runner's local calendar. Explicit offsets and native UTC dates
  are compared as instants. Pilot's client sends dates only, so the API query covers whole days
  around that interval; the exact filter runs before reference lookups or translation. A partial
  tail day needs one extra query day, so `now` mode refuses a covering query over Pilot's 30-day
  limit. Both day settings remain configurable. Omitted `start_from` (or `today`) keeps the existing
  midnight behavior. Already-staged cache entries are not rewritten, and orders starting before the
  lower bound are no longer eligible for a late-arrival catch-up.
- `scheduledStartDateTime` and `scheduledEndDateTime` supply the TMW stop earliest/latest windows.
  `deliveryWindowStartDateTime` and `deliveryWindowEndDateTime` are ignored, including when populated.
  Missing or reversed scheduled timestamps are not replaced with those optional delivery fields.
- `productCode / wraProductDescription` supplies the freight description, for example
  `91E10 / SUP` or `NO2ULS / DSL-AS`. The product code is what to lift and carries the octane. The
  WRA product says which tank it goes in: one code can go to different tanks, and the WRA long name
  is not enough, since `Diesel` covers `DSL` and `DSL-AS`. Both parts are required.
- Every freight line stages in gallons. TMW's `dx_add_neworder_freight_to_stop` copies the count
  unit into the freight unit, so added lines pass a blank count unit and take the fuel default,
  like a stop's first line.
- The cache folder (`cache`, default `cache`) keeps one file per Pilot order: `staged` with its TMW
  order, or `skipped` with the reason. A staged order's file also keeps the Pilot order record and
  the location, terminal and contract rows it was staged from, written once when the order is
  created in TMW, so what Pilot sent can be checked later. An order TMW already had keeps no record,
  since TMW was not built from this read. A staged order is passed over before anything else, and a skip
  reason is logged only when it is new or changes. An order file goes `keep_days` (7 by default)
  after its last update, by the date inside it. A dry run keeps no cache.
- Pilot's location, terminal and contract lists only fill in names and addresses, and TMW maps each
  stop by its id. The lists are kept in the cache (`reference-*.json`) and read from Pilot again when an order names an id the kept copy lacks, or once the kept
  copy is older than `keep_days`. A missing terminal or supplier id stages as `UNKNOWN`; an id the lists
  lack keeps the id. Either way that stop comes over with no address for people to finish in EDI. A
  partial address stages too, each missing part marked `MISSING` (state `??`).
- One order is one transaction through TMW's own `dx_*` procedures, with a matching DX archive.
  The Pilot id is the key: an order already in TMW logs `EXISTS` and is left alone, changed or not.
- The SQL checks `db_name()` against `tmw.expected_database` before it writes anything.
- Orders stage in parallel (`tmw.max_parallel`) with retries (`tmw.retry_attempts`).

### Required Fields (0.7.9)

Blank means null, empty or whitespace. One incomplete active item holds the whole order before
reference lookups or SQL staging. Its skip reason is logged only when new or changed. Terminal
and supplier are the only optional source fields in this table.

| Need | Pilot source | TMW destination | Check |
|---|---|---|---|
| When | `scheduledStartDateTime`, `scheduledEndDateTime` | Every stop's earliest/latest | Both dates valid; end after start |
| Pickup | `lineOfOperationsSystemId` | Pickup company match value | Blank becomes `UNKNOWN` |
| Quantity | `gallons` | Freight volume, `GAL` | Positive number |
| Product | `productCode` + `wraProductDescription` | Commodity match value, `code / description`; code also supplies `L06` | Neither blank |
| Supplier | `looSystemId` | Freight `SID` reference | Blank becomes `UNKNOWN` |
| Delivery | `locationSystemId` | Delivery company match value | Not blank |
| Identity | `dispatchOrderId`, each `dispatchOrderItemId` | Order `PO`/replay key; freight `OID`/`PO` | Not blank |
| Status | `dispatchOrderStatusTypeId` | Intake filter | `2` (Scheduled) |

Reference lists still only enrich display names and addresses. A missing reference row keeps its
source id with no address; missing supplier display text remains `NO SUPPLIER`.
Fixed values remain the configured trading partner, bill-to, division and SCAC, EDI state `10`,
and freight unit `GAL`.

0.7.9 removes the `customerLocationSystemId` delivery fallback, the product-code fallbacks to
`wraProductId`/`wraProductSystemId`, and the WRA-only/`NO PRODUCT` commodity fallback. Missing delivery
ids now hold the order at the intake check. A confirmed existing TMW order still logs `EXISTS`
and is left alone; that operational outcome is separate from source validation.

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

## Test coverage

Run the local suite with `Invoke-Pester ./tests`. Its API and SQL calls are mocked. A passing local
suite establishes the behavior below, not a live carrier-system acceptance result. Live tests need
separate before/after observations at each destination. The full list is not a one-session checklist.

| ID | Scenario | Current automated coverage |
|---|---|---|
| P01 | Incoming order identities, item references, supplier/product keys and GAL quantity | Translation fixtures in `Orders.Tests.ps1`. |
| P02 | Scheduled timestamps override optional delivery-window fields | Present, absent, invalid and conflicting optional fields; missing/equal/reversed scheduled bounds. |
| P03 | Several products, pickups, deliveries and suppliers | Translation/grouping fixtures. Not every real TMW load topology is qualified by these tests. |
| P04 | Missing lookup data, partial addresses and required identifiers | Placeholders and refusal cases. Actual dispatcher mapping remains a separate acceptance step. |
| P05 | Wrong status, absent items or nonpositive gallons | Eligibility, skipped reasons and already-staged cache checks. |
| P06 | TMW duplicate staging and transactional DX output | Generated SQL/archive assertions and mocked staging outcomes, not live SQL execution. Existing orders remain unchanged. |
| P07 | Missing BOL, OID, gallons or completion times | Whole-order hold and reason assertions in `PilotCarrierIntegration.Tests.ps1`. |
| P08 | Repeated item IDs or two TMW orders sharing one carrier order | Planner holds rather than sending ambiguous completions. |
| P09 | Identical done payload versus changed payload | Same retained hash suppresses; changed hash is ready again. This is cache-bounded, not permanent duplicate prevention. |
| P10 | Pending work absent from the next SQL result | Retained rows supply the retry; receipt expiry removes them. |
| P11 | Receipt expiry and cursor inputs | Receipt-date cleanup and cursor configuration are tested. A caller query's inclusive boundary and source reselection need feed-level tests too. |
| P12 | Completion acknowledgment | Matching order, Kiosked and all items with BOLs are required. Incomplete or mismatched responses remain pending. |
| P13 | Ordinary refusal versus auth/rate-limit/server/timeout failure | 4xx other than 401/403/429 stays pending, including lock refusals until A01 is implemented. 401/403/429/5xx and timeout preserve the original exception at the send boundary. The batch retains pending work. |
| P14 | Misleading validation text | A generic HTTP 400 about invalid input is not a completed, already-validated order. |
| P15 | Document targeting and duplicate attachment names | Order/BOL/item correlation, multiple targets, deferred matches and existing attachments in `Documents.Tests.ps1`. |
| P16 | PDF payload and document refusal | PDF signature, item/name requirements, request fields and refused-upload behavior. No downstream document-storage proof. |
| P17 | Dry runs and idle jobs | Planning/no-send behavior for BOLs and documents, plus idle logs. TMW order dry runs still require a guarded test database. |

The following are acceptance cases or implementation gaps, not green local tests:

| ID | Scenario | Remaining work |
|---|---|---|
| A01 | A definitive already-validated/locked update rejection finishes the payload | Not implemented. Capture the provider discriminator, then test done/hash suppression with a rejection reason. An arbitrary HTTP 400 is not sufficient evidence. |
| A02 | Changed BOL data before versus after remote validation | Joint acceptance test: accepted correction before the lock, definitive rejection after it, exact response and unchanged remote data on refusal. |
| A03 | Identical acknowledgment retry versus a later changed correction | Local behavior is covered above; remote idempotency and validation timing still need destination evidence. |
| A04 | Remote reset with unchanged data and existing documents | No reset detector or reset-generation handling. Receipt expiry is not a reset signal. |
| A05 | Incoming changes after initial staging | Not applied to an existing TMW order. Test and define a separate update policy before adding that behavior. |
| A06 | Documents before any matching remote BOL data | The current planner defers them. A different correlation contract is needed for an unrestricted documents-first flow. |
| A07 | Paperwork preservation, source reporting and competing user applications | Destination-side acceptance evidence, outside the mocked module suite. |
| A08 | Credential disable or endpoint outage through receipt expiry | Real destination/auth recovery and caller-query reselection tests. Local failures do not prove recovery after an arbitrary outage duration. |
| A09 | All operational load shapes and lifecycle variants | Synthetic TMW test fixtures for representative pickup/drop/product combinations, incomplete closeout, cancellations, late changes and billing exceptions. |

A completed receipt means no more action for that retained payload. A future terminal-refusal rule
must say when the update was rejected rather than applied. It must not turn authentication,
throttling, malformed data or uncertain delivery into apparent success. Once a receipt expires,
the source query may select the same unchanged order again, including at a stalled inclusive cursor.
