"""Keep PR-Agent's review memory on while automatic runs publish check runs.

PR-Agent stores the findings of a review in a hidden marker of its persistent review comment and gives them to the
next /review, so a finding that still applies is repeated word for word and its inline comment is recognised as
already posted. Upstream turns that memory off whenever github.publish_as_check_run is on, and the check run is our
only progress signal for automatic runs. Without memory the model rewords every finding on every push, the inline
fingerprints no longer match, and the same finding is posted again.

With this guard removed the review goes to the persistent comment (with its state) instead of the check run, and the
GitHub App server still opens the check run as in progress and completes it when the command finishes.

Run at image build time. Fails the build if the guard is not found exactly once, so a PR-Agent upgrade that changes
this code cannot silently ship without the patch.
"""

import importlib.util
import pathlib
import re

GUARD = re.compile(
    r'\n        if \(\n'
    r'            getattr\(getattr\(settings, "github", None\), "publish_as_check_run", False\)\n'
    r'            and callable\(getattr\(provider, "_publish_check_run", None\)\)\n'
    r'        \):\n'
    r'            return False'
)

spec = importlib.util.find_spec("pr_agent.tools.pr_reviewer")
path = pathlib.Path(spec.origin)
source, count = GUARD.subn("", path.read_text())
if count != 1:
    raise SystemExit(f"{path}: the publish_as_check_run guard was found {count} times, expected 1; "
                     "re-check pr-agent/patch-review-memory.py against this PR-Agent version")
path.write_text(source)
print(f"patched {path}")
