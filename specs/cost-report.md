# Cost report

`python3 scripts/cost-report.py` writes an HTML page (`--out`, default
`cost-report.html`, git-ignored) of how many profiles and devices Presence
has and what they cost in AWS a month. It needs AWS credentials that may
scan the auth API's tables and read Cost Explorer (each run makes one Cost
Explorer call, $0.01).

## What it shows

- **Profiles:** the items of each stage's `ProfilesTable` (prod's
  `presence-auth-api` stack and RC's `presence-rc-auth-api`; a stage
  without its stack is skipped).
- **Devices:** the device IDs the profiles list (`devices`, the device
  slots the auth API keeps, see [Membership](membership.md)), each counted
  once per stage.
- **Profiles per device:** for each device, how many of its stage's
  profiles list it; the mean, with the population standard deviation
  beside it in smaller type ("1.00 ± 0.00").
- **Cost per device per month:** all per-device costs over all devices;
  under it, each stage's (GA, RC), and the cost per device with the fixed
  costs shared too.
- **Total cost per month:** per-device and fixed costs together.
- **By stage:** GA, RC and both stages, each with its profiles and devices,
  its per-device and fixed costs, total, and (GA, RC) cost per device.
- **By service:** each service's cost in GA, RC and both stages, and
  whether it grows with devices; then the services **left out**.
- A warning when no cost in the window carries the `tenancy` tag yet:
  everything is then under both stages.

## How costs are counted

- **Cost Explorer**, usage charges only (record type `Usage`): credits
  would otherwise hide them, and refunds and tax aren't usage.
- **The last 30 full days** (`--days`), ending the day before yesterday
  (Cost Explorer's latest day is still being filled in), scaled to an
  average month (365.25 / 12 days).
- **By the cost-allocation tags** every Presence stack carries (see
  [Production deploy](deploy.md)), active in Cost Explorer since
  2026-10-15 (earlier months backfilled):
  - only costs tagged `project=presence`, or with no `project` tag, are
    read: other projects in the account carry their own `project`, and
    some the same `tenancy` values;
  - `tenancy=GA` is the GA stage's (`prod`), `tenancy=RC` the RC's, and
    `tenancy=shared` both stages';
  - untagged usage (live sync's messages, data transfer, logs, the
    recognition functions' warm-up schedule) counts for both stages when
    its service is one only Presence uses much (S3, data transfer, Lambda,
    API Gateway, DynamoDB, IoT, Cognito, CloudFront, CloudWatch and its
    events), and is left out otherwise: Route 53's zone (`nu01.com`)
    serves the domain and other projects (Presence has no hosted zone or
    health check of its own), and Secrets Manager holds only theirs.
- **Per device or fixed:** S3, data transfer, Lambda, API Gateway,
  DynamoDB, IoT and Cognito grow with devices; everything else of
  Presence's (CloudFront, logs, the session key in KMS) is fixed.
- **A stage's cost per device** is its own per-device costs plus its share
  of both stages' (by its devices), over its devices.
- **The free tier** is charged $0, so it's in neither: costs grow faster
  than the report says once it's used up.
- On 2026-10-15, before the tags reached Cost Explorer: 5 profiles (GA 3,
  RC 2), 4 devices (all GA), 1.00 ± 0.00 profiles per device, $0.24 per
  device and $0.97 a month in all (Route 53, Secrets Manager and other
  projects' services left out; before, counting Route 53 and Secrets
  Manager as Presence's, it said $7.51).

## Tests

`python3 -m unittest scripts/cost_report_test.py`: devices counted once
per stage with their profiles, mean and standard deviation, no devices,
the cost window, whose each cost is (stage, both, left out), the split by
stage and kind with monthly scaling and each stage's cost per device, and
the page's values, escaping and the untagged warning.
