"""Tests of scripts/cost-report.py's counting and cost arithmetic (no AWS).

    python3 -m unittest scripts/cost_report_test.py
"""
import datetime
import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location(
    "cost_report", pathlib.Path(__file__).resolve().parent / "cost-report.py"
)
report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report)


class DeviceStatsTest(unittest.TestCase):
    def test_devices_counted_once_with_their_profiles(self):
        stats = report.device_stats(
            {"prod": [["a"], ["a", "b"], [], ["c", "c"]], "rc": [["a"]]}
        )
        self.assertEqual(stats["profiles"], 5)
        # prod a (2 profiles), prod b (1), prod c (1, listed twice), rc a (1).
        self.assertEqual(stats["devices"], 4)
        self.assertAlmostEqual(stats["mean"], 1.25)
        self.assertAlmostEqual(stats["stdev"], 0.4330127)

    def test_no_devices(self):
        stats = report.device_stats({"prod": [[], []]})
        self.assertEqual((stats["profiles"], stats["devices"]), (2, 0))
        self.assertIsNone(stats["mean"])
        self.assertIsNone(stats["stdev"])

    def test_devices_of_a_dynamodb_item(self):
        item = {"id": {"S": "p"}, "devices": {"L": [{"S": "a"}, {"S": "b"}]}}
        self.assertEqual(report.devices_of(item), ["a", "b"])
        self.assertEqual(report.devices_of({"id": {"S": "p"}}), [])


class CostTest(unittest.TestCase):
    def test_window_ends_before_yesterday(self):
        start, end = report.cost_window(datetime.date(2026, 10, 15), 30)
        self.assertEqual(end, datetime.date(2026, 10, 14))
        self.assertEqual(start, datetime.date(2026, 9, 14))

    def test_stage_of(self):
        self.assertEqual(report.stage_of("GA", "AWS Lambda"), "GA")
        self.assertEqual(report.stage_of("RC", "Amazon Route 53"), "RC")
        self.assertEqual(report.stage_of("shared", "Amazon S3"), report.BOTH)
        self.assertEqual(report.stage_of("", "AWS IoT"), report.BOTH)
        # Untagged, not a service only Presence uses: another project's.
        self.assertIsNone(report.stage_of("", "Amazon Route 53"))
        self.assertIsNone(report.stage_of("", "Amazon Relational Database Service"))

    def test_split_by_stage_and_scaled_to_a_month(self):
        cost = report.monthly_costs(
            {
                ("GA", "Amazon Simple Storage Service"): 3.0,
                ("GA", "AWS Key Management Service"): 1.0,
                ("RC", "AWS Lambda"): 1.0,
                ("", "AWS IoT"): 2.0,
                ("shared", "Amazon Simple Storage Service"): 2.0,
                ("", "Amazon Route 53"): 9.0,
            },
            days=30,
            devices={"GA": 3, "RC": 1},
        )
        k = report.MONTH_DAYS / 30
        ga, rc, both = (cost["stages"][c] for c in ("GA", "RC", report.BOTH))
        self.assertAlmostEqual(ga["per_device"], 3.0 * k)
        self.assertAlmostEqual(ga["fixed"], 1.0 * k)
        self.assertAlmostEqual(both["per_device"], 4.0 * k)
        # Each stage's own, with its share of both stages' (3 of 4 devices).
        self.assertAlmostEqual(ga["per_device_each"], (3.0 + 4.0 * 0.75) / 3 * k)
        self.assertAlmostEqual(rc["per_device_each"], (1.0 + 4.0 * 0.25) / 1 * k)
        self.assertAlmostEqual(cost["per_device_each"], 8.0 / 4 * k)
        self.assertAlmostEqual(cost["total"], 9.0 * k)
        self.assertAlmostEqual(cost["all_in_each"], 9.0 / 4 * k)
        self.assertEqual(set(cost["excluded"]), {"Amazon Route 53"})
        self.assertAlmostEqual(
            cost["services"]["Amazon Simple Storage Service"][report.BOTH], 2.0 * k
        )
        self.assertTrue(cost["tagged"])

    def test_no_devices_no_cost_per_device(self):
        cost = report.monthly_costs({("", "AWS Lambda"): 1.0}, days=30, devices={})
        self.assertIsNone(cost["per_device_each"])
        self.assertIsNone(cost["all_in_each"])
        self.assertIsNone(cost["stages"]["GA"]["per_device_each"])
        self.assertFalse(cost["tagged"])


class RenderTest(unittest.TestCase):
    def test_tiles_tables_and_escaping(self):
        stats = report.device_stats({"prod": [["a"], ["a", "b"]]})
        stage_stats = {"GA": stats, "RC": report.device_stats({"rc": []})}
        cost = report.monthly_costs(
            {("GA", "<b>Service</b>"): 1.0, ("", "AWS IoT"): 2.0},
            30,
            {"GA": 2, "RC": 0},
        )
        page = report.render(
            stats,
            stage_stats,
            cost,
            (datetime.date(2026, 9, 14), datetime.date(2026, 10, 14)),
            datetime.datetime(2026, 10, 15, 12, 0, tzinfo=datetime.timezone.utc),
        )
        self.assertIn("1.50 <small>± 0.50</small>", page)
        self.assertIn("&lt;b&gt;Service&lt;/b&gt;", page)
        self.assertNotIn("<b>Service</b>", page)
        self.assertIn("Costs from 2026-09-14 to 2026-10-13", page)
        self.assertIn("<th>Both stages</th>", page)
        self.assertNotIn('class="warn"', page)

    def test_warns_without_tags(self):
        stats = report.device_stats({})
        cost = report.monthly_costs({("", "AWS IoT"): 1.0}, 30, {})
        page = report.render(
            stats,
            {},
            cost,
            (datetime.date(2026, 9, 14), datetime.date(2026, 10, 14)),
            datetime.datetime(2026, 10, 15, 12, 0, tzinfo=datetime.timezone.utc),
        )
        self.assertIn('class="warn"', page)


if __name__ == "__main__":
    unittest.main()
