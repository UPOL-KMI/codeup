# UPcode — verified source revisions

**What this file is.** `repos.lock` records *which* revisions the stack is pinned to. This file
records *what was verified about them*, and what is known not to work. A commit hash cannot tell
you whether anybody ever ran it.

Bump both together: change `repos.lock`, re-verify, and add a row here saying what you ran.

---

## Verified set — 2026-09-11

| Component  | Source                       | Commit     | Dated      |
| ---------- | ---------------------------- | ---------- | ---------- |
| `api`      | `upol-kmi/upcode-api`        | `7471b71f` | 2026-07-23 |
| `worker`   | `upol-kmi/upcode-worker`     | `f267aa9`  | 2025-10-25 |
| `isolate`  | `upol-kmi/upcode-isolate`    | `25d3f48`  | 2025-07-14 |
| `monitor`  | `upol-kmi/upcode-monitor`    | `e6f8a1d`  | 2026-02-13 |
| `broker`   | `upol-kmi/upcode-broker`     | `abdc95c`  | 2022-12-04 |
| `cleaner`  | `upol-kmi/upcode-cleaner`    | `0a5e390`  | 2025-07-16 |
| `web-app`  | `ReCodEx/web-app` (upstream) | `fc6fdaf`  | 2026-08-01 |
| `web-next` | `upol-kmi/upcode-web-ui`     | `a118d4e`  | 2026-09-11 |

**How it was verified.** Against a seeded instance (`pnpm seed`), the new frontend's full suite:
**311 end-to-end tests pass and 3 skip, 0 failures**, with `retries` at 0, plus 287 unit tests and
five static checks (`typecheck`, `lint`, `format:check`, `build`, `test`). The three skips are one
fixture this deployment can no longer produce — a submission failure, which took a sandbox that
could not run (see below and `web-next`'s PF-017) — and each says so rather than passing quietly.

The previous verified set was built on a wiped database and ran 313 tests twice with the seeded
fixtures unchanged afterwards, which is the stronger check of the two and worth repeating here
whenever the database is next rebuilt; this set was verified on an instance seeded in place.

**Evaluation is verified end to end as of 2026-09-11** — a correct seeded solution scores full
points and a wrong one zero, through the real submit path. See "The sandbox works" below for what
it took and what was verified; the paragraph that used to stand here said submitted code does not
run on this host, and that has not been true since plan 002.

**This is a source pin, not an image pin,** and on 2026-09-11 the two disagreed: the running
`recodex-api` and `recodex-worker` images predated the C#/Java toolchain change already committed
here (see "Language runtimes" below). The revisions above describe `repos/`; what is actually
serving traffic depends on when `docker compose build` last ran. Worth checking with
`docker image inspect recodex-api recodex-worker --format '{{.Created}}'` before believing a
verdict about the stack.

**`api` is pinned to the base of its `upcode` branch, not the tip.** The tip carries a README commit
that was not part of this build. Code-identical; this file is about what ran.

---

## What is forked, and what is not

Our forks live in the [`upol-kmi`](https://github.com/upol-kmi) organisation as
`upcode-<component>`. In each one:

| Branch   | What it is                                                                |
| -------- | ------------------------------------------------------------------------- |
| `master` | Untouched mirror of upstream. Nothing of ours is committed there.         |
| `upcode` | Our integration branch, and the default, on the three we change.          |

`api`, `worker` and `isolate` have an `upcode` branch and a fork notice in the README.
`monitor`, `broker` and `cleaner` are unmodified mirrors — GitHub's own "forked from" banner and the
untouched `LICENSE` are the whole of what an unmodified fork needs, and adding a notice would make a
clean mirror unclean for no benefit.

**`web-app` is not forked.** It is the legacy frontend, which `web-next` exists to replace, so
nothing of ours will ever change in it — forking it would mean maintaining a copy of something we
intend to delete. It is pinned by commit straight to upstream, which gives the same reproducibility
without the copy. `pull-repos.sh` carries it as its one source exception.

**Licences differ, and `isolate` is the odd one.** Everything above is MIT (© 2016 ReCodEx Team)
except `isolate`, which is **GPL-2.0-or-later** (© Martin Mareš, Bernard Blackham; upstream
`ioi/isolate`). Running a service on it is not distribution and triggers no obligation; handing the
binary or a container image to anybody outside the university does, and then our changes have to be
offered as source. Keeping the fork public satisfies that by itself.

---

## Patched at build time, and belongs upstream instead

`services/api/patch-compatibility.php` rewrites three things in `repos/api` during the image build.
All three are faults against *current* upstream, not local misconfiguration, so all three are
candidates to send to ReCodEx — and until then they belong as commits on `upcode-api`'s `upcode`
branch rather than as a patch script:

1. ~104 pre-2022 migrations call `getDatabasePlatform()->getName()`, which `doctrine/dbal` 4
   (pinned by upstream's own `composer.lock`) removed. Rewritten to an
   `instanceof AbstractMySQLPlatform` check.
2. Several of those migrations mix DDL with an explicit `beginTransaction()`/`commit()` pair.
   MySQL/MariaDB commits implicitly on DDL, which desynchronises Doctrine's savepoint bookkeeping
   and crashes with `SAVEPOINT ... does not exist`. Fixed by `isTransactional(): false`.
3. `RuntimeImport` declares its own `--silent`, which now collides with one `symfony/console`
   registers globally — `LogicException` before the command runs.

Beyond those, a **fresh** database is built with `orm:schema-tool:create` from the current entity
mappings and the migration history is marked as applied, because a clean replay of eight years of
migrations hits `ALTER TABLE ... CHANGE` on foreign-key columns that current MariaDB refuses even
with `FOREIGN_KEY_CHECKS=0`. An **existing** database still runs `migrations:migrate` normally.

---

## Known not working, with the path out

### The sandbox works, and so does evaluation

**Fixed 2026-09-11: the sandbox runs.** Isolate is **2.7** now (plan 001), the worker delegates
itself a cgroup v2 subtree at start-up, and all of this is verified on Docker Desktop for macOS:

```
== cgroup v2 subtree ready at /sys/fs/cgroup/isolate (controllers: cpuset cpu memory) ==
Checking for cgroup support for memory.max ... PASS       (was CAUTION / "cannot be used")
Using cgroup root: /sys/fs/cgroup/isolate
```

Python runs inside it and the limits are real, checked one at a time by hand:

| Case | Result |
| ---- | ------ |
| read stdin, print a sum | `exitcode:0`, correct output, meta carries all seven keys the worker parses |
| infinite loop, `--wall-time=2` | `status:TO`, "Time limit exceeded (wall clock)", killed at 2.002 s |
| allocate 400 MB, `--cg-mem=64MB` | `cg-mem:65536`, `cg-oom-killed:1`, `exitsig:9`, `status:SG` |
| `sys.exit(3)` | `status:RE`, "Exited with error status 3" |

Memory limits *are* enforced despite `isolate-check-environment`'s swap CAUTION — it now reads
"although accounted for", where before it was a FAIL saying accounting was absent.

**Fixed 2026-09-11, later the same day: evaluation is verified end to end.** What the cgroup
failure had been hiding was a separate, older set of bugs in how the *exercise* was configured —
three of them, all in `repos/web-next`, none in core-api, and none specific to macOS or cgroups.
The compiled job read `python3 <runner> ${EVAL_DIR}/` with no file to run, and copied the solution
to a file named literally `*.py`, because the environment's `source-files` wildcard was written as
a one-element array (core-api only expands a scalar) and the test was missing the pass-through
compilation pipeline that binds the submitted files at all. Fixing those made the entry point a
*submit-time* variable, which the new frontend had never sent. Full account in
**`docs/plans/002`**; the work itself is `web-next`'s **PF-016**.

**Verified through the real submit path**, not by reading configuration:

| Seeded solution | Result |
| ---- | ------ |
| `[seed] correct` | **10/10**, `Test 1` OK |
| `[seed] wrong` | **0/10**, `Test 1` FAILED |
| `[seed] multi-file` (`main.py` + `greeting.py`) | **10/10**, `Test 1` OK |

and the compiled job now reads `cp ${SOURCE_DIR}/solution.py …` and
`python3 <runner> ${EVAL_DIR}/solution.py`.

**One consequence worth knowing before it surprises somebody:** a solution submitted as a single
ZIP archive cannot be graded by an exercise whose `source-files` is `*.py`. core-api matches the
wildcard against the *uploaded* file name (`solution.zip`), not the entries inside it, so such a
submission is refused. That is upstream behaviour, not something this deployment introduced.

**One real bug was found and fixed on the way**, also previously masked: the worker gave sandboxes
`PATH=/usr/bin:/bin`, and this image builds Python 3.13 from source into `/usr/local` (Debian 12
ships 3.11), so `/usr/bin/python3` does not exist and every Python submission would have died with
"Exited with error status 127". `services/worker/config.yml.template` now puts `/usr/local/bin`
first.

### Mail: not configured

`SMTP_HOST` is still `smtp.example.com` and `SMTP_USER`/`SMTP_PASSWORD` are empty. Password reset,
email verification, invitations by mail and every notification therefore go nowhere. The frontend
builds and tests the request side against core-api regardless; nothing arrives.

### Language runtimes: C# and Java are in the code, but not in the running stack

**The deployment code has six**: `bash`, `c-gcc-linux`, `cxx-gcc-linux`, `python3`,
`cs-dotnet-core` and `java`, added on 2026-08-21 and verified then in rebuilt images — dotnet
8.0.424, javac 17.0.20, both runtime packages imported, the API advertising all six.

**The containers running today have four.** Verified 2026-09-11: `recodex-api` was built
2026-08-17 and `recodex-worker` 2026-07-30, both *before* that change, so `dotnet` and `javac` are
absent from the worker image and `/v1/runtime-environments` answers `bash`, `c-gcc-linux`,
`cxx-gcc-linux`, `python3`. Nothing is wrong with the code; the images are simply older than it.

**And rebuilding is necessary but not sufficient** — this is the part that will waste an afternoon
if it is not written down. `services/api/docker-entrypoint.sh` gates both `db:fill init` and the
`runtimes:import` loop on `[ ! -f storage/.seeded ]`, and `storage/` is the `api_storage` volume.
That marker was created by the wipe on 2026-09-11, so on the next boot the import is **skipped** and
a freshly built api image will still not register `cs-dotnet-core` with core-api. Two ways round it:

```bash
# Rebuild, then import the new packages by hand -- keeps the database.
docker compose build api worker && docker compose up -d
docker compose exec api php bin/console runtimes:import --yes     /opt/recodex-runtimes/cs-dotnet-core-2024-12-15.zip
docker compose exec api php bin/console runtimes:import --yes     /opt/recodex-runtimes/java-2024-12-15.zip
```

or wipe `mysql_data` + `api_storage` again and let first boot do it, which also costs the seeded
fixtures. The first is what you want unless you were going to wipe anyway.

**The .NET version is not free to choose.** `cs-dotnet-core`'s own `Program.runtimeconfig.json`
targets `netcoreapp8.0` with no `rollForward` key, so a worker carrying .NET 9 or 10 looks
correctly provisioned and fails every C# submission at run time. The package *description* still
claims v6; the config shipped beside it says 8, and the config is what gets loaded. Hence the pin
in `services/worker/Dockerfile`, and see README's "Language toolchains" for the full reasoning.

### The new frontend is not what `/` serves

`services/proxy/nginx.conf.template` has `location / { proxy_pass http://web-app:8080; }` — the
**legacy** frontend. `web-next` is published only on its own port (`WEB_NEXT_PORT`, default 3001).
Switching it over is one entry in that template, and it is deliberately not done yet: the legacy UI
is a useful reference while the pipelines and runtimes are still being worked on. When it is
switched, the `web-app` service and `repos.lock`'s exception for it go together.
