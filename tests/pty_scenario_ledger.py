"""The PTY scenario list is checked against the code that runs the scenarios.

Increment 86 built `make test-pty-isolation` and `python3 tests/pty_smoke.py
--scenario <name>` to answer one question: does this scenario pass on its own?
Increment 89 answered a different question -- two full `make test` runs failed on
two different scenarios, both on an assertion about a completed repaint, and
both passed ten times out of ten alone -- and found that the page-switch step
which had just failed was **unreachable by the tool**: it lived inside `main`
with no name of its own, so it was in neither `SCENARIOS` nor anything
`--scenario` could be given.  The sweep reported 17/17 on the very runs the
matrix was failing.

That is the same accounting error this project has now made several times, and
recording the lesson in a document does not make it stop: the cheap form of
"check the list against the code" has to run.  So this is that check, and it is
a static comparison rather than a measurement -- no PTY session, no host state --
because the thing being asserted is a property of two pieces of source.

Three things are asserted, and the third exists because the first two can both
pass for the wrong reason:

1. Every scenario `main()` runs is named in `SCENARIOS`, so a failure in the
   matrix is always diagnosable on demand.  This is the regression.
2. The only `run_*` functions allowed to be unnamed are the two that are not
   scenarios: `run_session`, the primitive every scenario calls, and
   `run_isolation`, the driver.  Naming that pair explicitly is what stops a
   third helper from escaping the list unnoticed -- an unnamed helper is exactly
   how the page-switch step hid.
3. At least one listed scenario is actually invoked from `main()`.  Without this
   a list that drifted away from the suite entirely would pass clauses 1 and 2
   while diagnosing nothing.

The list is counted too, so a scenario deleted from both the code and the list
is noticed rather than absorbed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent / "pty_smoke.py"

# The two `run_*` functions that are not scenarios.  Both are named here so that
# the exception is a decision rather than a residue.
NOT_SCENARIOS = frozenset({"run_session", "run_isolation"})

EXPECTED_SCENARIOS = 18


def main() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    problems: list[str] = []

    defined = set(re.findall(r"^def (run_\w+)\(", text, re.M))
    match = re.search(r"^SCENARIOS = \((.*?)^\)", text, re.M | re.S)
    if match is None:
        print("SCENARIOS could not be found in pty_smoke.py", file=sys.stderr)
        return 1
    listed = set(re.findall(r'"(run_\w+)"', match.group(1)))

    main_body = text[text.index("def main() -> None:"):]
    called = set(re.findall(r"^    (run_\w+)\(\)", main_body, re.M))

    unreachable = sorted(called - listed)
    if unreachable:
        problems.append(
            "scenarios the suite runs that --scenario cannot name, so a failure "
            "in them cannot be diagnosed on demand: " + ", ".join(unreachable)
        )

    escaped = sorted(defined - listed - NOT_SCENARIOS)
    if escaped:
        problems.append(
            "run_* functions that are neither scenarios nor one of the two "
            "named exceptions, and so cannot be run on their own: "
            + ", ".join(escaped)
        )

    stale = sorted(listed - defined)
    if stale:
        problems.append(
            "names in SCENARIOS with no matching function: " + ", ".join(stale)
        )

    # Clause 3: the list has to be attached to the suite, not decorative.
    if not (listed & called):
        problems.append(
            "no listed scenario is called from main(); the list has drifted away "
            "from the suite and would diagnose nothing"
        )

    if len(listed) != EXPECTED_SCENARIOS:
        problems.append(
            f"SCENARIOS holds {len(listed)} names, not the {EXPECTED_SCENARIOS} "
            "this check was written against; a scenario added or removed has to "
            "be looked at rather than absorbed"
        )

    if problems:
        for problem in problems:
            print("pty-scenario-ledger: " + problem, file=sys.stderr)
        return 1
    print(
        f"pty-scenario-ledger: {len(listed)} scenarios, all reachable by "
        f"--scenario ({len(called)} run from the suite)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
