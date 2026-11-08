import unittest

from release import read_version, release_event


class ReleaseVersionTest(unittest.TestCase):
    def test_version_and_ci_build_number(self):
        result = read_version("name: getfor\nversion: 0.1.0\n", "42")
        self.assertEqual((result["version"], result["tag"], result["build_number"]), ("0.1.0", "v0.1.0", "42"))
        self.assertEqual(result["prerelease"], "false")

    def test_explicit_build_and_prerelease(self):
        result = read_version("version: 1.2.3-rc.1+50 # comment\n", "42")
        self.assertEqual(result["version"], "1.2.3-rc.1")
        self.assertEqual(result["build_name"], "1.2.3")
        self.assertEqual(result["build_number"], "50")
        self.assertEqual(result["prerelease"], "true")

    def test_malformed_or_ambiguous_versions_fail(self):
        for text in ("", "version: 1.2", "version: 01.2.3", "version: 1.2.3+0", "version: 1.2.3\nversion: 2.0.0"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                read_version(text)

    def test_invalid_android_build_numbers_fail(self):
        for number in ("0", "-1", "bad", "2100000001"):
            with self.subTest(number=number), self.assertRaises(ValueError):
                read_version("version: 1.2.3", number)

    def test_only_main_and_matching_tags_publish(self):
        self.assertTrue(release_event("push", "refs/heads/main", "v1.2.3"))
        self.assertTrue(release_event("push", "refs/tags/v1.2.3", "v1.2.3"))
        self.assertTrue(release_event("workflow_dispatch", "refs/heads/main", "v1.2.3"))
        self.assertFalse(release_event("pull_request", "refs/heads/main", "v1.2.3"))
        self.assertFalse(release_event("push", "refs/heads/feature", "v1.2.3"))
        with self.assertRaises(ValueError):
            release_event("push", "refs/tags/v9.0.0", "v1.2.3")


if __name__ == "__main__":
    unittest.main()
