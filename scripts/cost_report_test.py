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

    def test_split_and_scaled_to_a_month(self):
        cost = report.monthly_costs(
            {
                "Amazon Simple Storage Service": 3.0,
                "AWS Lambda": 1.0,
                "Amazon Route 53": 6.0,
                "Amazon Relational Database Service": 9.0,
            },
            days=30,
            devices=4,
        )
        scale = report.MONTH_DAYS / 30
        self.assertAlmostEqual(cost["per_device_total"], 4.0 * scale)
        self.assertAlmostEqual(cost["fixed_total"], 6.0 * scale)
        self.assertAlmostEqual(cost["total"], 10.0 * scale)
        self.assertAlmostEqual(cost["per_device_each"], 1.0 * scale)
        self.assertAlmostEqual(cost["all_in_each"], 2.5 * scale)
        self.assertIn("Amazon Relational Database Service", cost["excluded"])

    def test_no_devices_no_cost_per_device(self):
        cost = report.monthly_costs({"AWS Lambda": 1.0}, days=30, devices=0)
        self.assertIsNone(cost["per_device_each"])
        self.assertIsNone(cost["all_in_each"])


class RenderTest(unittest.TestCase):
    def test_tiles_and_escaping(self):
        stats = report.device_stats({"prod": [["a"], ["a", "b"]]})
        cost = report.monthly_costs({"<b>Service</b>": 1.0, "AWS IoT": 2.0}, 30, 2)
        page = report.render(
            stats,
            {"prod": (2, 2)},
            cost,
            (datetime.date(2026, 9, 14), datetime.date(2026, 10, 14)),
            datetime.datetime(2026, 10, 15, 12, 0, tzinfo=datetime.timezone.utc),
        )
        self.assertIn("1.50 <small>± 0.50</small>", page)
        self.assertIn("&lt;b&gt;Service&lt;/b&gt;", page)
        self.assertNotIn("<b>Service</b>", page)
        self.assertIn("Costs from 2026-09-14 to 2026-10-13", page)


if __name__ == "__main__":
    unittest.main()
