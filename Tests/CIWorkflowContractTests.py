"""Regression tests for the CI workflow verifier itself (Python stdlib only)."""

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script" / "test_ci_workflow.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class CIWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def run_contract(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ci.yml"
            path.write_text(text, encoding="utf-8")
            return subprocess.run(
                ["bash", str(SCRIPT), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )

    def substitute(self, before, after):
        self.assertIn(before, self.workflow, "fixture no longer matches CI; update this test")
        return self.workflow.replace(before, after, 1)

    def test_repository_workflow_satisfies_contract(self):
        result = self.run_contract(self.workflow)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_full_suite_driver(self):
        altered = self.substitute("run: bash script/test_suites.sh", "run: echo no tests")
        self.assertNotEqual(self.run_contract(altered).returncode, 0)

    def test_rejects_comment_only_pretend_suite(self):
        altered = self.substitute(
            "run: bash script/test_suites.sh", "run: |\n          # bash script/test_suites.sh\n          echo no tests"
        )
        self.assertNotEqual(self.run_contract(altered).returncode, 0)

    def test_rejects_missing_pull_request_trigger(self):
        altered = self.substitute("  pull_request:\n", "  workflow_dispatch:\n")
        self.assertNotEqual(self.run_contract(altered).returncode, 0)

    def test_rejects_credentials_persisted(self):
        altered = self.substitute("persist-credentials: false", "persist-credentials: true")
        self.assertNotEqual(self.run_contract(altered).returncode, 0)

    def test_rejects_wrong_runner(self):
        altered = self.substitute("runs-on: macos-26", "runs-on: self-hosted")
        self.assertNotEqual(self.run_contract(altered).returncode, 0)

    def test_rejects_missing_main_branch(self):
        altered = self.substitute("branches: [main]", "branches: [develop]")
        self.assertNotEqual(self.run_contract(altered).returncode, 0)


if __name__ == "__main__":
    unittest.main()
