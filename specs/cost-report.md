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
- **Cost per device per month:** the per-device costs (below) shared
  among the devices; under it, the cost per device with the fixed costs
  shared too.
- **Total cost per month:** per-device and fixed costs together.
- The costs per service, in three tables: per device, fixed, and left out.

## How costs are counted

- **Cost Explorer**, usage charges only (record type `Usage`): credits
  would otherwise hide them, and refunds and tax aren't usage. Both stages
  together: their resources aren't told apart by a cost allocation tag.
- **The last 30 full days** (`--days`), ending the day before yesterday
  (Cost Explorer's latest day is still being filled in), scaled to an
  average month (365.25 / 12 days).
- **Only Presence's services** count; the account holds other projects
  (their services are listed as left out):
  - **per device**, growing with devices: S3, data transfer, Lambda, API
    Gateway, DynamoDB, IoT (live sync), Cognito;
  - **fixed**: Route 53 (hosted zones and the site's health checks),
    CloudFront, Secrets Manager (payments), CloudWatch and its events (the
    recognition functions' warm-up schedule).
- **The free tier** is charged $0, so it's in neither: costs grow faster
  than the report says once it's used up.
- On 2026-10-15: 5 profiles (3 prod, 2 RC), 4 devices (all prod), 1.00 ±
  0.00 profiles per device, $0.24 per device and $7.51 a month in all, of
  which $6.28 is Route 53.

## Tests

`python3 -m unittest scripts/cost_report_test.py`: devices counted once
per stage with their profiles, mean and standard deviation, no devices,
the cost window, the split and monthly scaling, and the page's values and
escaping.
