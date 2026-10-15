#!/usr/bin/env python3
"""Writes an HTML report of Presence's profiles, devices and AWS costs.

- Profiles and devices come from each stage's ProfilesTable (its stack's
  `ProfilesTable`): a profile item lists its devices (`devices`, the device
  slots the auth API keeps). A device is counted once per stage; profiles
  per device is how many of the stage's profiles list it.
- Costs come from Cost Explorer: what AWS charged for usage (record type
  Usage, so credits don't hide it, nor do refunds or tax count) over the
  last --days full days, scaled to an average month. Only Presence's
  services count: the account holds other projects. Each is either per
  device (it grows with devices: storage, functions, API calls, live sync)
  or fixed (the site, DNS and health checks, secrets). The cost per device
  is the per-device part shared among the devices; the total is everything.
  Usage inside the AWS free tier is charged $0, so it's left out of both.

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

# The stages and their auth API stacks.
STAGES = {"prod": "presence-auth-api", "rc": "presence-rc-auth-api"}

# Presence's services in Cost Explorer, by how their cost grows.
PER_DEVICE_SERVICES = {
    "Amazon Simple Storage Service",
    "AWS Data Transfer",
    "AWS Lambda",
    "Amazon API Gateway",
    "Amazon DynamoDB",
    "AWS IoT",
    "Amazon Cognito",
}
FIXED_SERVICES = {
    "Amazon Route 53",
    "Amazon CloudFront",
    "AWS Secrets Manager",
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


def service_costs(start: datetime.date, end: datetime.date) -> dict[str, float]:
    """What AWS charged for usage per service between [start] and [end]."""
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
        json.dumps({"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Usage"]}}),
        "--group-by",
        "Type=DIMENSION,Key=SERVICE",
    )
    costs: dict[str, float] = {}
    for period in result.get("ResultsByTime", []):
        for group in period.get("Groups", []):
            service = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            costs[service] = costs.get(service, 0.0) + amount
    return costs


def monthly_costs(costs: dict[str, float], days: int, devices: int) -> dict:
    """[costs] over [days] scaled to a month, split into per device, fixed
    and other projects' (left out), with the cost per device and the
    total."""
    scale = MONTH_DAYS / days
    rows = {"per_device": {}, "fixed": {}, "excluded": {}}
    for service, amount in costs.items():
        kind = (
            "per_device"
            if service in PER_DEVICE_SERVICES
            else "fixed"
            if service in FIXED_SERVICES
            else "excluded"
        )
        rows[kind][service] = amount * scale
    per_device = sum(rows["per_device"].values())
    fixed = sum(rows["fixed"].values())
    return {
        **rows,
        "per_device_total": per_device,
        "fixed_total": fixed,
        "total": per_device + fixed,
        "per_device_each": per_device / devices if devices else None,
        "all_in_each": (per_device + fixed) / devices if devices else None,
    }


def money(amount: float | None) -> str:
    if amount is None:
        return "—"
    return f"${amount:,.2f}" if amount >= 0.01 or amount == 0 else f"${amount:.4f}"


def render(
    stats: dict,
    stage_counts: dict[str, tuple[int, int]],
    cost: dict,
    window: tuple[datetime.date, datetime.date],
    generated: datetime.datetime,
) -> str:
    """The report's HTML."""
    e = html.escape
    mean = "—" if stats["mean"] is None else f"{stats['mean']:.2f}"
    stdev = "" if stats["stdev"] is None else f"<small>± {stats['stdev']:.2f}</small>"
    start, end = window
    last = end - datetime.timedelta(days=1)

    def tile(label: str, value: str, note: str = "") -> str:
        return (
            f'<div class="tile"><div class="label">{e(label)}</div>'
            f'<div class="value">{value}</div>'
            + (f'<div class="note">{e(note)}</div>' if note else "")
            + "</div>"
        )

    def table(title: str, rows: dict[str, float], note: str) -> str:
        if not rows:
            return ""
        body = "".join(
            f"<tr><td>{e(s)}</td><td>{money(a)}</td></tr>"
            for s, a in sorted(rows.items(), key=lambda r: -r[1])
        )
        return (
            f"<h2>{e(title)}</h2><p class=\"note\">{e(note)}</p>"
            f"<table><thead><tr><th>Service</th><th>Per month</th></tr></thead>"
            f"<tbody>{body}</tbody></table>"
        )

    stages = ", ".join(
        f"{e(s)}: {p} profiles, {d} devices" for s, (p, d) in stage_counts.items()
    )
    tiles = "".join(
        [
            tile("Profiles", str(stats["profiles"])),
            tile("Devices", str(stats["devices"])),
            tile(
                "Profiles per device",
                f"{mean} {stdev}",
                "mean ± standard deviation",
            ),
            tile(
                "Cost per device per month",
                money(cost["per_device_each"]),
                f"{money(cost['all_in_each'])} with the fixed costs shared too",
            ),
            tile(
                "Total cost per month",
                money(cost["total"]),
                f"{money(cost['per_device_total'])} per device usage + "
                f"{money(cost['fixed_total'])} fixed",
            ),
        ]
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
  --line: #e2e2dd; --accent: #2f6f5e;
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg: #161615; --surface: #1f1f1d; --text: #ececea; --muted: #a0a09a;
    --line: #33332f; --accent: #6fbfa8;
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
table {{
  width: 100%; border-collapse: collapse; margin-top: 8px;
  background: var(--surface); border: 1px solid var(--line); border-radius: 10px;
}}
th, td {{ text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); }}
td:last-child, th:last-child {{ text-align: right; font-variant-numeric: tabular-nums; }}
tr:last-child td {{ border-bottom: 0; }}
th {{ color: var(--muted); font-weight: 500; font-size: 13px; }}
</style>
</head>
<body>
<main>
<h1>Presence costs</h1>
<p class="meta">Generated {e(generated.strftime("%Y-%m-%d %H:%M UTC"))}.
Costs from {e(start.isoformat())} to {e(last.isoformat())}, scaled to a month.
{stages}.</p>
<div class="tiles">{tiles}</div>
{table("Per device usage", cost["per_device"], "Grows with devices: storage, functions, API calls, live sync. Shared among the devices.")}
{table("Fixed", cost["fixed"], "The same whatever the devices: the site, DNS and health checks, secrets, logs.")}
{table("Left out", cost["excluded"], "Charged to the account but not Presence's services.")}
<h2>How it's counted</h2>
<p class="note">Profiles and devices: each stage's profiles table; a device is
counted once per stage, and its profiles are the stage's profiles that list it.
Costs: Cost Explorer's usage charges (credits, refunds and tax left out), for
both stages together. Usage inside the AWS free tier is charged $0, so costs
grow faster than this once it's used up.</p>
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
    stage_counts = {s: device_stats({s: p}) for s, p in stages.items()}

    now = datetime.datetime.now(datetime.timezone.utc)
    window = cost_window(now.date(), args.days)
    cost = monthly_costs(service_costs(*window), args.days, stats["devices"])

    page = render(
        stats,
        {s: (c["profiles"], c["devices"]) for s, c in stage_counts.items()},
        cost,
        window,
        now,
    )
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)
    print(
        f"cost-report: {stats['profiles']} profiles, {stats['devices']} devices, "
        f"{money(cost['per_device_each'])} per device, {money(cost['total'])} a month: "
        f"{args.out}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
