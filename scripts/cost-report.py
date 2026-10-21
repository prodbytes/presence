#!/usr/bin/env python3
"""Writes an HTML report of Presence's profiles, devices and AWS costs.

- Profiles and devices come from each stage's ProfilesTable (its stack's
  `ProfilesTable`): a profile item lists its devices (`devices`, the device
  slots the auth API keeps). A device is counted once per stage; profiles
  per device is how many of the stage's profiles list it.
- Costs come from Cost Explorer: what AWS charged for usage (record type
  Usage, so credits don't hide it, nor do refunds or tax count) over the
  last --days full days, scaled to an average month, by service and by the
  `tenancy` cost-allocation tag every Presence stack carries (GA, RC, or
  shared for what serves both; scripts/deploy.sh). Costs tagged
  project=presence are Presence's, by stage; other projects' (their own
  project tag, some with the same tenancy values) are never read. Untagged ones (usage no resource carries, such as
  live sync's messages or data transfer) count for both stages when their
  service is one Presence uses, and are left out otherwise: the account
  holds other projects, and Route 53's zone is shared with them.
- Each service is per device (it grows with devices: storage, functions,
  API calls, live sync) or fixed (the site, secrets, logs, keys). A
  stage's cost per device is its per-device costs, with its share of both
  stages' (by its devices), over its devices. Usage inside the AWS free
  tier is charged $0, so it's left out.

Needs AWS credentials that may scan the tables and read Cost Explorer
(each Cost Explorer call costs $0.01). Run from anywhere:

    python3 scripts/cost-report.py [--out cost-report.html] [--days 30]
"""
import argparse
import datetime
import html
import json
import statistics
import subprocess
import sys

# The stages: their auth API stacks and their `tenancy` tag.
STAGES = {"prod": "presence-auth-api", "rc": "presence-rc-auth-api"}
TENANCY = {"prod": "GA", "rc": "RC"}

# Both stages' costs: tagged shared, or untagged.
BOTH = "both"

# Services whose cost grows with devices; any other Presence cost is fixed.
PER_DEVICE_SERVICES = {
    "Amazon Simple Storage Service",
    "AWS Data Transfer",
    "AWS Lambda",
    "Amazon API Gateway",
    "Amazon DynamoDB",
    "AWS IoT",
    "Amazon Cognito",
}

# Services whose untagged costs are Presence's (both stages): what Presence
# uses that no resource tag carries, and no other project in the account
# uses much. Route 53 isn't: its zone serves the domain and other projects.
UNTAGGED_SERVICES = PER_DEVICE_SERVICES | {
    "Amazon CloudFront",
    "AmazonCloudWatch",
    "CloudWatch Events",
}

# Days in an average month.
MONTH_DAYS = 365.25 / 12


def aws(*args: str) -> dict:
    """Runs the AWS CLI with JSON output and returns what it printed."""
    out = subprocess.run(
        ["aws", *args, "--output", "json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out) if out.strip() else {}


def profiles_table(stack: str) -> str | None:
    """The physical name of [stack]'s ProfilesTable; None without the stack."""
    try:
        detail = aws(
            "cloudformation",
            "describe-stack-resource",
            "--stack-name",
            stack,
            "--logical-resource-id",
            "ProfilesTable",
        )
    except subprocess.CalledProcessError:
        return None
    return detail["StackResourceDetail"]["PhysicalResourceId"]


def scan_profiles(table: str) -> list[list[str]]:
    """Each profile's device IDs (the CLI pages through the whole table)."""
    items = aws(
        "dynamodb",
        "scan",
        "--table-name",
        table,
        "--projection-expression",
        "id, devices",
    ).get("Items", [])
    return [devices_of(item) for item in items]


def devices_of(item: dict) -> list[str]:
    """The device IDs a DynamoDB profile item lists."""
    return [d["S"] for d in item.get("devices", {}).get("L", []) if "S" in d]


def device_stats(stages: dict[str, list[list[str]]]) -> dict:
    """Profiles, devices and profiles per device (mean and population
    standard deviation) over every stage's profiles: a device listed by
    several of a stage's profiles counts once, with that many profiles."""
    per_device: dict[tuple[str, str], int] = {}
    profiles = 0
    for stage, devices_by_profile in stages.items():
        profiles += len(devices_by_profile)
        for devices in devices_by_profile:
            for device in set(devices):
                per_device[(stage, device)] = per_device.get((stage, device), 0) + 1
    counts = list(per_device.values())
    return {
        "profiles": profiles,
        "devices": len(counts),
        "mean": statistics.fmean(counts) if counts else None,
        "stdev": statistics.pstdev(counts) if counts else None,
    }


def cost_window(today: datetime.date, days: int) -> tuple[datetime.date, datetime.date]:
    """The last [days] full days before yesterday (Cost Explorer's latest
    day is still being filled in): start inclusive, end exclusive."""
    end = today - datetime.timedelta(days=1)
    return end - datetime.timedelta(days=days), end


# Usage charges of Presence's resources (project=presence), and of what no
# project tag carries. Other projects in the account carry their own
# project, and some the same tenancy values.
USAGE_FILTER = {
    "And": [
        {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Usage"]}},
        {
            "Or": [
                {"Tags": {"Key": "project", "Values": ["presence"]}},
                {"Tags": {"Key": "project", "MatchOptions": ["ABSENT"]}},
            ]
        },
    ]
}


def tagged_costs(start: datetime.date, end: datetime.date) -> dict[tuple[str, str], float]:
    """What AWS charged for usage between [start] and [end] to Presence's
    resources and untagged usage ([USAGE_FILTER]), by `tenancy` tag value
    ("" untagged) and service."""
    result = aws(
        "ce",
        "get-cost-and-usage",
        "--time-period",
        f"Start={start.isoformat()},End={end.isoformat()}",
        "--granularity",
        "MONTHLY",
        "--metrics",
        "UnblendedCost",
        "--filter",
        json.dumps(USAGE_FILTER),
        "--group-by",
        "Type=TAG,Key=tenancy",
        "Type=DIMENSION,Key=SERVICE",
    )
    costs: dict[tuple[str, str], float] = {}
    for period in result.get("ResultsByTime", []):
        for group in period.get("Groups", []):
            tag, service = group["Keys"]
            # Cost Explorer names a tag value "tenancy$GA", and none "tenancy$".
            tenancy = tag.split("$", 1)[1] if "$" in tag else ""
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            costs[(tenancy, service)] = costs.get((tenancy, service), 0.0) + amount
    return costs


def stage_of(tenancy: str, service: str) -> str | None:
    """Whose cost it is: a stage's tenancy (GA, RC), [BOTH], or None when
    it isn't Presence's."""
    if tenancy in TENANCY.values():
        return tenancy
    if tenancy == "shared" or (tenancy == "" and service in UNTAGGED_SERVICES):
        return BOTH
    if tenancy == "":
        return None
    # Another tenancy value on a Presence resource: Presence's, though not
    # one stage's.
    return BOTH


def monthly_costs(
    costs: dict[tuple[str, str], float], days: int, devices: dict[str, int]
) -> dict:
    """[costs] (by tenancy and service) over [days] scaled to a month: by
    service and stage, per stage (per device and fixed), what's left out,
    and the cost per device of each stage and of all. [devices] counts
    each tenancy's (GA, RC) devices."""
    scale = MONTH_DAYS / days
    columns = [*TENANCY.values(), BOTH]
    services: dict[str, dict[str, float]] = {}
    excluded: dict[str, float] = {}
    stages = {c: {"per_device": 0.0, "fixed": 0.0} for c in columns}
    for (tenancy, service), amount in costs.items():
        amount *= scale
        stage = stage_of(tenancy, service)
        if stage is None:
            excluded[service] = excluded.get(service, 0.0) + amount
            continue
        row = services.setdefault(service, {c: 0.0 for c in columns})
        row[stage] += amount
        kind = "per_device" if service in PER_DEVICE_SERVICES else "fixed"
        stages[stage][kind] += amount
    for s in stages.values():
        s["total"] = s["per_device"] + s["fixed"]

    all_devices = sum(devices.values())
    both = stages[BOTH]
    for tenancy in TENANCY.values():
        n = devices.get(tenancy, 0)
        share = n / all_devices if all_devices else 0.0
        stage = stages[tenancy]
        stage["devices"] = n
        stage["per_device_each"] = (
            (stage["per_device"] + both["per_device"] * share) / n if n else None
        )
    per_device = sum(s["per_device"] for s in stages.values())
    fixed = sum(s["fixed"] for s in stages.values())
    return {
        "services": services,
        "excluded": excluded,
        "stages": stages,
        "tagged": any(t for t, _ in costs if t),
        "per_device_total": per_device,
        "fixed_total": fixed,
        "total": per_device + fixed,
        "per_device_each": per_device / all_devices if all_devices else None,
        "all_in_each": (per_device + fixed) / all_devices if all_devices else None,
    }


def money(amount: float | None) -> str:
    if amount is None:
        return "—"
    return f"${amount:,.2f}" if amount >= 0.01 or amount == 0 else f"${amount:.4f}"


def render(
    stats: dict,
    stage_stats: dict[str, dict],
    cost: dict,
    window: tuple[datetime.date, datetime.date],
    generated: datetime.datetime,
) -> str:
    """The report's HTML. [stage_stats]: [device_stats] of each tenancy."""
    e = html.escape
    mean = "—" if stats["mean"] is None else f"{stats['mean']:.2f}"
    stdev = "" if stats["stdev"] is None else f"<small>± {stats['stdev']:.2f}</small>"
    start, end = window
    last = end - datetime.timedelta(days=1)
    columns = [*TENANCY.values(), BOTH]
    names = {BOTH: "Both stages"}

    def tile(label: str, value: str, note: str = "") -> str:
        return (
            f'<div class="tile"><div class="label">{e(label)}</div>'
            f'<div class="value">{value}</div>'
            + (f'<div class="note">{e(note)}</div>' if note else "")
            + "</div>"
        )

    each = " · ".join(
        f"{t} {money(cost['stages'][t]['per_device_each'])}" for t in TENANCY.values()
    )
    tiles = "".join(
        [
            tile("Profiles", str(stats["profiles"])),
            tile("Devices", str(stats["devices"])),
            tile("Profiles per device", f"{mean} {stdev}", "mean ± standard deviation"),
            tile(
                "Cost per device per month",
                money(cost["per_device_each"]),
                f"{each}; {money(cost['all_in_each'])} with the fixed costs shared too",
            ),
            tile(
                "Total cost per month",
                money(cost["total"]),
                f"{money(cost['per_device_total'])} per device usage + "
                f"{money(cost['fixed_total'])} fixed",
            ),
        ]
    )

    stage_rows = ""
    for c in columns:
        s = cost["stages"][c]
        counts = stage_stats.get(c)
        stage_rows += (
            f"<tr><td>{e(names.get(c, c))}</td>"
            f"<td>{counts['profiles'] if counts else ''}</td>"
            f"<td>{counts['devices'] if counts else ''}</td>"
            f"<td>{money(s['per_device'])}</td><td>{money(s['fixed'])}</td>"
            f"<td>{money(s['total'])}</td>"
            f"<td>{money(s.get('per_device_each')) if c != BOTH else ''}</td></tr>"
        )
    stage_table = (
        "<h2>By stage</h2><p class=\"note\">Tagged costs by their stack's "
        "<code>tenancy</code>; both stages: tagged shared, or untagged usage "
        "(live sync's messages, data transfer, logs). A stage's cost per device "
        "takes its share of both stages' per-device costs.</p>"
        "<table><thead><tr><th>Stage</th><th>Profiles</th><th>Devices</th>"
        "<th>Per device usage</th><th>Fixed</th><th>Total</th><th>Per device</th>"
        f"</tr></thead><tbody>{stage_rows}</tbody></table>"
    )

    service_rows = "".join(
        f"<tr><td>{e(service)}</td><td>"
        f"{'per device' if service in PER_DEVICE_SERVICES else 'fixed'}</td>"
        + "".join(f"<td>{money(row[c])}</td>" for c in columns)
        + "</tr>"
        for service, row in sorted(cost["services"].items(), key=lambda r: -sum(r[1].values()))
    )
    service_table = (
        "<h2>By service</h2><table><thead><tr><th>Service</th><th>Grows</th>"
        + "".join(f"<th>{e(names.get(c, c))}</th>" for c in columns)
        + f"</tr></thead><tbody>{service_rows}</tbody></table>"
    )

    excluded_table = ""
    if cost["excluded"]:
        rows = "".join(
            f"<tr><td>{e(s)}</td><td>{money(a)}</td></tr>"
            for s, a in sorted(cost["excluded"].items(), key=lambda r: -r[1])
        )
        excluded_table = (
            "<h2>Left out</h2><p class=\"note\">Untagged, and not a service only "
            "Presence uses: other projects in the account, and Route 53's shared "
            "zone.</p><table><thead><tr><th>Service</th><th>Per month</th></tr>"
            f"</thead><tbody>{rows}</tbody></table>"
        )

    untagged = (
        ""
        if cost["tagged"]
        else '<p class="warn">No cost carries the <code>tenancy</code> tag in this '
        "window yet (it's active since 2026-10-15; the backfill of earlier months "
        "takes up to a day): every Presence cost is under both stages.</p>"
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Presence Costs</title>
<style>
:root {{
  --bg: #f7f7f5; --surface: #ffffff; --text: #1c1c1a; --muted: #6b6b66;
  --line: #e2e2dd; --warn: #8a5a00; --warn-bg: #fff4dc;
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg: #161615; --surface: #1f1f1d; --text: #ececea; --muted: #a0a09a;
    --line: #33332f; --warn: #f0c060; --warn-bg: #2e2510;
  }}
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
}}
main {{ max-width: 960px; margin: 0 auto; padding: 32px 16px 48px; }}
h1 {{ font-size: 24px; margin: 0 0 4px; }}
h2 {{ font-size: 17px; margin: 32px 0 4px; }}
.note, .meta {{ color: var(--muted); font-size: 13px; margin: 0; }}
.warn {{
  color: var(--warn); background: var(--warn-bg); border-radius: 8px;
  padding: 8px 12px; margin: 16px 0 0; font-size: 13px;
}}
.tiles {{
  display: grid; gap: 12px; margin-top: 24px;
  grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
}}
.tile {{
  background: var(--surface); border: 1px solid var(--line);
  border-radius: 10px; padding: 16px;
}}
.label {{ color: var(--muted); font-size: 13px; }}
.value {{
  font-size: 28px; font-weight: 600; margin-top: 4px;
  font-variant-numeric: tabular-nums;
}}
.value small {{ font-size: 14px; font-weight: 400; color: var(--muted); }}
.tile .note {{ margin-top: 6px; }}
.scroll {{ overflow-x: auto; }}
table {{
  width: 100%; border-collapse: collapse; margin-top: 8px;
  background: var(--surface); border: 1px solid var(--line);
}}
th, td {{
  text-align: right; padding: 8px 12px; border-bottom: 1px solid var(--line);
  font-variant-numeric: tabular-nums; white-space: nowrap;
}}
th:first-child, td:first-child {{ text-align: left; }}
tr:last-child td {{ border-bottom: 0; }}
th {{ color: var(--muted); font-weight: 500; font-size: 13px; }}
</style>
</head>
<body>
<main>
<h1>Presence costs</h1>
<p class="meta">Generated {e(generated.strftime("%Y-%m-%d %H:%M UTC"))}.
Costs from {e(start.isoformat())} to {e(last.isoformat())}, scaled to a month.</p>
{untagged}
<div class="tiles">{tiles}</div>
<div class="scroll">{stage_table}</div>
<div class="scroll">{service_table}</div>
<div class="scroll">{excluded_table}</div>
<h2>How it's counted</h2>
<p class="note">Profiles and devices: each stage's profiles table; a device is
counted once per stage, and its profiles are the stage's profiles that list it.
Costs: Cost Explorer's usage charges (credits, refunds and tax left out). Usage
inside the AWS free tier is charged $0, so costs grow faster than this once
it's used up.</p>
</main>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="cost-report.html", help="the HTML file to write")
    parser.add_argument("--days", type=int, default=30, help="days of costs to average")
    args = parser.parse_args()
    if args.days < 1:
        parser.error("--days must be at least 1")

    stages: dict[str, list[list[str]]] = {}
    for stage, stack in STAGES.items():
        table = profiles_table(stack)
        if table is None:
            print(f"cost-report: no {stack} stack, {stage} skipped", file=sys.stderr)
            continue
        stages[stage] = scan_profiles(table)
    stats = device_stats(stages)
    stage_stats = {TENANCY[s]: device_stats({s: p}) for s, p in stages.items()}

    now = datetime.datetime.now(datetime.timezone.utc)
    window = cost_window(now.date(), args.days)
    cost = monthly_costs(
        tagged_costs(*window),
        args.days,
        {t: s["devices"] for t, s in stage_stats.items()},
    )

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(render(stats, stage_stats, cost, window, now))
    print(
        f"cost-report: {stats['profiles']} profiles, {stats['devices']} devices, "
        f"{money(cost['per_device_each'])} per device, {money(cost['total'])} a month"
        f"{'' if cost['tagged'] else ' (no tenancy tags yet)'}: {args.out}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
