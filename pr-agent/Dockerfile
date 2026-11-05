# PR-Agent with review memory kept on while automatic runs publish check runs (see patch-review-memory.py).
# On a version bump the build fails if the patch no longer applies; re-check it against the new source.
FROM pragent/pr-agent:0.49.0-github_app
# The app code is root-owned and read-only for the runtime user, so patch it as root and switch back.
USER root
COPY patch-review-memory.py /tmp/patch-review-memory.py
RUN python /tmp/patch-review-memory.py && rm /tmp/patch-review-memory.py
USER pragent
