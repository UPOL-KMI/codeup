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
| `web-next` | `upol-kmi/upcode-web-ui`     | `78da4b1`  | 2026-09-11 |

**How it was verified.** The database and file storage were wiped and rebuilt from the api
entrypoint's fresh-database path, then seeded (`pnpm seed`). Against that instance, the new
frontend's full suite was run twice: **313 end-to-end tests, 0 failures**, with `retries` at 0, plus
287 unit tests and five static checks (`typecheck`, `lint`, `format:check`, `build`, `test`). After
both runs the seeded fixtures were **unchanged** — four solutions on the primary assignment, one on
the second-deadline one, none on the deliberately-empty one, the review request still standing —
which is the part that says the suite does not quietly consume its own fixtures.

**What was not verified: evaluation itself.** See "cgroup v2" below. Submitted code does not run on
this host, so every pass/fail state in the seeded data is an infrastructure failure rather than a
verdict. Everything *around* evaluation — submitting, storing, listing, reviewing, scoring by hand
— is verified.

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

### Evaluation: `isolate` needs cgroup v1, this host has v2

The single thing that stops this being usable. Verified on the running stack:

```
Checking for cgroup support for memory ... CAUTION
WARNING: the memory is not present. isolate --cg cannot be used.
Checking for swap ... FAIL
```

The vendored Isolate is **1.8.1**, which understands only cgroup v1 (legacy/hybrid hierarchy).
Current Debian/Ubuntu/RHEL and Docker Desktop default to v2's unified hierarchy. Submitted code
therefore resolves to an infrastructure failure, never to pass or fail.

Two ways out, and they are genuinely different in size:

- **Boot the host kernel in cgroup v1 mode** — `systemd.unified_cgroup_hierarchy=0` on the kernel
  command line. No code changes at all. This is what the README recommends for production and is
  the only option that needs nothing from us. Not available on Docker Desktop for macOS.
- **Move to Isolate v2** — `ioi/isolate` has tags up to **`v2.7`**, already fetchable as the `ioi`
  remote in `repos/isolate`. Note that it is not a superset: *"This version of Isolate requires v2"*
  — it is the mirror image of 1.8.1, so this is a version change, not a patch. It also expects an
  `isolate.scope` cgroup subtree delegated by systemd plus an `isolate-cg-keeper` daemon; in a
  container without systemd that means pointing Isolate's config at the mounted cgroup filesystem by
  hand. And `worker` drives Isolate over a command line that changed between 1.x and 2.x, so
  `upcode-worker` is the other half of the work.

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
