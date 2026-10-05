#!/usr/bin/env python3
"""
Gatecrash conformance suite.

The same black-box tests, run against any implementation. Nothing here knows
whether it is talking to Rails, FastAPI, Hono or net/http — it speaks the
contract in spec/openapi.yaml and nothing else.

    # 1. start postgres, the app, and fake-psp
    # 2. reseed from spec/fixtures/seed.json
    # 3.
    python3 run.py --base-url http://localhost:3000

Options:
    --only C1,C7        run a subset
    --list              show the case catalogue and exit
    --psp-url URL       fake-psp control plane (default http://localhost:4242)
    --admin-token TOK   bearer token for /api/admin routes
    --allow-skips       exit 0 even if a case skipped (by default a skip fails the run)
"""

import argparse
import json
import re
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / "cases")]

from harness import Client, Ctx, Failure, REGISTRY, run  # noqa: E402

# importing the case modules is what populates REGISTRY
import cases.checkout     # noqa: E402,F401
import cases.idempotency  # noqa: E402,F401
import cases.webhooks     # noqa: E402,F401
import cases.inventory    # noqa: E402,F401
import cases.ledger       # noqa: E402,F401
import cases.tickets      # noqa: E402,F401
import cases.money        # noqa: E402,F401

DIM, RED, GREEN, YELLOW, BOLD, OFF = (
    ("\033[2m", "\033[31m", "\033[32m", "\033[33m", "\033[1m", "\033[0m")
    if sys.stdout.isatty() else ("", "", "", "", "", ""))


def _order(c):
    """Sort by chapter number, then case number — not lexically."""
    ch = int(re.sub(r"\D", "", c.chapter) or 99)
    n = int(re.sub(r"\D", "", c.id) or 0)
    return (ch, n, c.id)


def preflight(app, psp):
    problems = []
    try:
        r = app.get("/api/events")
        if r.status != 200:
            problems.append(f"app GET /api/events returned {r.status}, expected 200")
    except Failure as e:
        problems.append(f"app unreachable: {e}")
    try:
        r = psp.get("/_control/health")
        if r.status != 200:
            problems.append(f"fake-psp health returned {r.status}")
    except Failure as e:
        problems.append(f"fake-psp unreachable: {e}")
    return problems


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default=os.environ.get("BASE_URL", "http://localhost:3000"))
    p.add_argument("--psp-url", default=os.environ.get("PSP_URL", "http://localhost:4242"))
    p.add_argument("--admin-token", default=os.environ.get("ADMIN_TOKEN", "dev-admin-token"))
    p.add_argument("--seed", default=str(HERE.parent / "fixtures" / "seed.json"))
    p.add_argument("--only", default="")
    p.add_argument("--list", action="store_true")
    p.add_argument("--allow-skips", action="store_true",
                   help="exit 0 when cases skip; by default a skip fails the run")
    args = p.parse_args()

    cases = sorted(REGISTRY, key=_order)


    if args.list:
        print(f"\n{BOLD}Gatecrash conformance catalogue{OFF}\n")
        for c in cases:
            print(f"  {c.id:5} {DIM}{c.chapter:5}{OFF} {c.title}")
        print(f"\n  {len(cases)} cases\n")
        return 0

    if args.only:
        wanted = {s.strip().upper() for s in args.only.split(",")}
        cases = [c for c in cases if c.id.upper() in wanted]
        if not cases:
            print(f"{RED}no cases matched {args.only!r}{OFF}")
            return 2

    app = Client(args.base_url, admin_token=args.admin_token)
    psp = Client(args.psp_url)
    seed = json.loads(pathlib.Path(args.seed).read_text())

    print(f"\n{BOLD}Gatecrash conformance{OFF}")
    print(f"  {DIM}app     {OFF}{args.base_url}")
    print(f"  {DIM}fake-psp{OFF} {args.psp_url}")
    print(f"  {DIM}cases   {OFF}{len(cases)}\n")

    if problems := preflight(app, psp):
        print(f"{RED}preflight failed{OFF}")
        for prob in problems:
            print(f"  - {prob}")
        print(f"\n{DIM}Start postgres, the app, and fake-psp, then reseed "
              f"from spec/fixtures/seed.json{OFF}\n")
        return 2

    started = time.time()
    results = run(cases, Ctx(app=app, psp=psp, seed=seed))

    for r in results:
        if r.skipped:
            mark, colour = "○", YELLOW
        elif r.ok:
            mark, colour = "✓", GREEN
        else:
            mark, colour = "✗", RED
        print(f"  {colour}{mark}{OFF} {r.case.id:5} {r.case.title} "
              f"{DIM}({r.seconds:.1f}s){OFF}")
        if r.skipped:
            print(f"        {YELLOW}skipped: {r.error}{OFF}")
        elif not r.ok:
            for line in r.error.split("\n"):
                print(f"        {RED}{line}{OFF}")

    passed = sum(1 for r in results if r.ok and not r.skipped)
    skipped = sum(1 for r in results if r.skipped)
    failed = sum(1 for r in results if not r.ok)

    print(f"\n  {GREEN}{passed} passed{OFF}"
          + (f"  {YELLOW}{skipped} skipped{OFF}" if skipped else "")
          + (f"  {RED}{failed} failed{OFF}" if failed else "")
          + f"  {DIM}in {time.time() - started:.1f}s{OFF}\n")
    if skipped and not args.allow_skips:
        # A skip is a case that did not run, and a run with one is not a pass.
        print(f"  {YELLOW}A skip is not a pass. Fix its precondition, or pass "
              f"--allow-skips to accept it.{OFF}\n")
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
