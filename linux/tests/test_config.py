import os
import unittest
from unittest.mock import patch

from local_jarvis_linux.config import JarvisLinuxConfiguration


class JarvisLinuxConfigurationTests(unittest.TestCase):
    def test_default_step_limit_is_unlimited(self):
        with patch.dict(os.environ, {}, clear=True):
            configuration = JarvisLinuxConfiguration.from_environment()

        self.assertIsNone(configuration.maximum_step_count)

    def test_positive_step_limit_can_be_restored(self):
        with patch.dict(os.environ, {"JARVIS_MAXIMUM_STEPS": "25"}, clear=True):
            configuration = JarvisLinuxConfiguration.from_environment()

        self.assertEqual(configuration.maximum_step_count, 25)

    def test_zero_selects_unlimited_mode(self):
        with patch.dict(os.environ, {"JARVIS_MAXIMUM_STEPS": "0"}, clear=True):
            configuration = JarvisLinuxConfiguration.from_environment()

        self.assertIsNone(configuration.maximum_step_count)

    def test_invalid_step_limit_is_rejected(self):
        with patch.dict(os.environ, {"JARVIS_MAXIMUM_STEPS": "invalid"}, clear=True):
            with self.assertRaisesRegex(ValueError, "positive integer"):
                JarvisLinuxConfiguration.from_environment()


if __name__ == "__main__":
    unittest.main()
