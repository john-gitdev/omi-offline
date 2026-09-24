"""Check that harness extraction fails closed when production seams drift."""

import unittest

from run import HERE, SOURCE, notification_source, replace_seam, section


class ExtractionTest(unittest.TestCase):
    def test_notification_mode_is_independent_of_storage_and_pigeon(self):
        source = SOURCE.read_text(encoding="utf-8")
        source = source[:source.index("    inner class StorageDownloadSession(")]
        template = (HERE / "NotificationSubscriptionStubs.kt").read_text(encoding="utf-8")
        result = notification_source(source, template)
        self.assertIn("fun subscribeCharacteristic", result)
        self.assertIn("fun processNextCommand", result)
        self.assertNotIn("// PRODUCTION_", result)

    def test_missing_duplicate_and_reversed_boundaries_fail(self):
        for source in ("start body", "start start end", "start end end", "end start"):
            with self.subTest(source=source), self.assertRaisesRegex(RuntimeError, "seam changed"):
                section(source, "start", "end", "test")

    def test_missing_or_duplicate_placeholders_fail(self):
        for template in ("none", "marker marker"):
            with self.subTest(template=template), self.assertRaisesRegex(RuntimeError, "seam changed"):
                replace_seam(template, "marker", "body")

    def test_duplicate_descriptor_callback_fails(self):
        source = SOURCE.read_text(encoding="utf-8")
        source += "\n        override fun onDescriptorWrite(fake: Int) {\n        }"
        template = (HERE / "NotificationSubscriptionStubs.kt").read_text(encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Descriptor callback seam changed"):
            notification_source(source, template)


if __name__ == "__main__":
    unittest.main()
