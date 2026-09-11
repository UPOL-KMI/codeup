# ReCodEx — Docker deployment

This directory packages the [ReCodEx](https://github.com/ReCodEx) programming-assignment
evaluation system (Charles University) as a self-contained Docker Compose stack. ReCodEx
itself ships **no official Docker support** — the upstream deployment method is RPM
packages on Fedora/RHEL. Everything here (Dockerfiles, entrypoints, config templates,
compose file) was written from scratch against the upstream source and tested end-to-end
against a running stack.

## Layout

```
.
├── docker-compose.yaml       # the whole stack
├── .env.example               # copy to .env and fill in secrets
├── pull-repos.sh              # fetches source into ./repos, at the revisions in repos.lock
├── repos.lock                 # the source revisions this stack is pinned to
├── COMPATIBILITY.md           # what was verified about them, and what is known not to work
├── docs/plans/                # work spanning more than one repo is planned here
├── repos/                     # source trees (gitignored, populated by pull-repos.sh)
│   ├── api/  worker/  isolate/                     # our forks, we commit into these
│   ├── broker/  monitor/  cleaner/                 # our forks, unmodified mirrors
│   ├── web-app/                                    # upstream ReCodEx, not forked
│   └── web-next/                                   # our own frontend, see below
└── services/                  # our deployment code, one folder per component
    ├── api/                   # core REST API (PHP/Nette) + nginx
    ├── web-app/                # legacy React frontend (Node/Express SSR)
    ├── broker/                 # job scheduler (C++)
    ├── worker/                 # sandboxed code executor (C++, bundles `isolate`)
    ├── monitor/                 # WebSocket relay for live evaluation progress (Python)
    └── proxy/                   # nginx reverse proxy (single public entrypoint)
```

`repos/` is not committed — run `./pull-repos.sh` to fetch it (see below). Everything under
`services/` and `docker-compose.yaml` **is** meant to be committed and is what you transfer
to the production server.

### Sources are pinned, and most of them are ours

The ReCodEx components are fetched from **our forks** in the
[`upol-kmi`](https://github.com/upol-kmi) organisation, named `upcode-<component>`, at the exact
commits listed in **`repos.lock`**. That file exists because fetching each repository's default
branch is a moving target: a stack that worked last week could stop working after a `git pull`
nobody thought of as a change, and there was nowhere to look up what had been working.
**`COMPATIBILITY.md`** is where what-was-verified lives, including the things that are known not to
work yet and the path out of each.

In every fork, `master` is an untouched mirror of upstream and our work lives on `upcode`. Only
`api`, `worker` and `isolate` have that branch; `broker`, `monitor` and `cleaner` are unmodified
mirrors. `web-app` is the one component **not** forked — it is the legacy frontend that `web-next`
replaces, so nothing of ours will ever change in it, and pinning it by commit to upstream gives the
same reproducibility without maintaining a copy of something we intend to delete.

Overrides, highest precedence first:

```bash
./pull-repos.sh                      # the verified revisions, from repos.lock
ISOLATE_REF=upcode ./pull-repos.sh   # one repo from a branch, for working on a fork
REF=master ./pull-repos.sh           # everything from one ref
NO_LOCK=1 ./pull-repos.sh            # ignore the lock, take default branches
```

`repos/web-next` is **not** a ReCodEx repo at all — it's our own from-scratch Next.js
replacement for `web-app`, developed in its own separate git repository
(`upol-kmi/upcode-web-ui`). `pull-repos.sh` fetches it into the same gitignored
`repos/` tree as the upstream repos, purely for convenience — one script still brings the whole
stack together. It builds and runs as its own `web-next` service (see `docker-compose.yaml`),
side by side with the legacy `web-app`, on its own port (`WEB_NEXT_PORT`, see below) rather than
behind the `proxy` service — this is deliberate while the new frontend is still pre-parity with
the legacy one; see that repo's own `docs/DECISIONS.md` for the reasoning.

`repos/web-next` is meant to be developed in directly, and so now are `repos/api`,
`repos/worker` and `repos/isolate` — they are our forks, and a push from a shallow clone is refused
outright, which is why those three are cloned in full rather than shallow. Re-running
`./pull-repos.sh` only moves them if there are no uncommitted changes and no local commits missing
from the remote; otherwise it leaves the working tree untouched and tells you so, rather than
discarding in-progress work. The remaining four (`web-app`, `broker`, `monitor`, `cleaner`) are pure
build inputs: shallow, and always forced to the pinned revision.

## Architecture

```
                         ┌─────────┐
   browser  ───────────▶ │  proxy  │  (nginx, ports 80/443 — the only published ports)
                         └────┬────┘
                 ┌────────────┼─────────────┐
                 ▼            ▼              ▼
           ┌──────────┐ ┌──────────┐  ┌────────────┐
           │ web-app  │ │   api    │  │  monitor   │
           │ (Node)   │ │(PHP-fpm  │  │ (WebSocket │
           │          │ │ +nginx)  │  │  ⇄ ZeroMQ) │
           └──────────┘ └─┬──┬─────┘  └─────┬──────┘
                           │  │              │
                    ┌──────┘  └─────┐        │
                    ▼                ▼        │
              ┌──────────┐    ┌────────────┐  │
              │  mysql   │    │ api-worker │  │
              │(MariaDB) │    │(async jobs)│  │
              └──────────┘    └────────────┘  │
                                               │
                    ┌──────────┐   ZeroMQ      │
                    │  broker  │◀──────────────┘
                    └────┬─────┘
                         │ ZeroMQ
                         ▼
                    ┌──────────┐
                    │  worker  │  privileged: executes untrusted submitted code
                    │ (isolate)│  inside the `isolate` sandbox
                    └──────────┘

   browser  ───────────▶  web-next  (Next.js, its own published port — NOT behind `proxy` yet,
                                      talks to `api` directly over the internal network; see
                                      "Layout" above)
```

`api`, `broker`, and `worker` all embed the public domain into URLs they generate for each
other (e.g. workers download submissions via the public `/api/v1/worker-files/...` URL, the
same way they would if workers ran on entirely separate physical machines in a bigger
deployment). Inside `docker-compose.yaml` the `proxy` service is given a network alias equal
to `APP_DOMAIN`, so this resolves correctly over the internal Docker network without needing
real DNS to be live yet — useful for testing before you've pointed a domain at the server.

## Quick start

```bash
./pull-repos.sh              # fetch the pinned sources (see repos.lock) into ./repos
cp .env.example .env         # then edit .env: passwords, JWT_SECRET, APP_DOMAIN, SMTP...
docker compose build         # ~5-10 min the first time (compiles worker/broker/isolate from source)
docker compose up -d
docker compose logs -f api   # watch first-boot migrations/seed
```

For local testing, add `127.0.0.1  recodex.local` (or whatever you set `APP_DOMAIN` to) to
your `/etc/hosts`, then open `http://recodex.local/` for the legacy `web-app`, or
`http://recodex.local:${WEB_NEXT_PORT}/` (see `.env`, defaults to `3001`) for the new
`web-next` frontend.

First boot seeds an admin account (`admin@admin.com` / `admin`, controlled by
`RECODEX_SEED_DB=true` in `.env`) — **log in and change that password immediately**, or set
`RECODEX_SEED_DB=false` before first boot and create your own admin via `db:fill` manually.

## ⚠️ Before going to production, read this: `worker` needs cgroup v1

The `worker` container runs submitted code inside [`isolate`](https://github.com/ioi/isolate)
(the same sandbox IOI/CMS use), which needs direct access to the kernel's cgroup and
namespace facilities and runs `privileged: true` with `cgroup: host` in the compose file for
that reason. **This specific isolate version (1.8.1, vendored by ReCodEx) only supports
cgroup v1** (legacy/hybrid hierarchy) — it does not understand cgroup v2's unified
hierarchy, which is the default on current Debian/Ubuntu/RHEL and on Docker Desktop.

On the production server, either:

- **Boot the kernel with cgroup v1 (hybrid) mode.** On systemd-based distros, add
  `systemd.unified_cgroup_hierarchy=0` to the kernel command line (edit
  `/etc/default/grub`'s `GRUB_CMDLINE_LINUX`, run `update-grub`, reboot), or
- Use a distro/kernel that still defaults to cgroup v1 hybrid mode.

You can check the current mode with `mount | grep cgroup` — cgroup v2-only systems show a
single `cgroup2` mount at `/sys/fs/cgroup`; hybrid/legacy systems show multiple `cgroup`
(v1) mounts per-controller (`memory`, `cpu`, `cpuset`, ...).

Verify with:
```bash
docker compose logs worker | grep -A2 "cgroup support"
```
`OK` for memory/cpuacct/cpuset means the sandbox will work; `CAUTION`/`WARNING` (what you'll
see on a cgroup-v2-only host, and what this stack showed in local testing on macOS/Docker
Desktop) means submitted code will fail to evaluate until the host is switched to cgroup v1.
Every other service in this stack is architecture/host-agnostic; this is the one genuine
production-environment prerequisite.

## Language toolchains

`services/worker/Dockerfile` installs `gcc`, `g++`, `python3`, the **.NET 8 SDK** (C#) and a
**JDK** (Java) by default, and `services/worker/config.yml.template`'s `headers.env` advertises
the matching environments: `bash`, `c-gcc-linux`, `cxx-gcc-linux`, `python3`, `cs-dotnet-core`,
`java`. ReCodEx itself supports more (Rust, Go, Haskell, Node, Kotlin, Prolog, Free Pascal,
Groovy, Scala...) — see [ReCodEx/runtimes](https://github.com/ReCodEx/runtimes) for the full
catalogue and "To add a language" below.

### ⚠️ C#: the .NET version is not free to choose

`cs-dotnet-core-2024-12-15.zip`'s own `Program.runtimeconfig.json` pins
`"tfm": "netcoreapp8.0"` / `"version": "8.0.0"` and sets **no** `rollForward` key, so the host's
default policy (`Minor`) will start on any 8.0.x runtime but will **not** cross to .NET 9 or 10.
Installing "the latest .NET" therefore produces a worker that looks correctly provisioned and
fails every C# submission at run time. (Confusingly, the package's own *description* text still
says "currently v6" — the config file shipped in the same zip is what actually gets loaded, and
it says 8.) The pin lives in `services/worker/Dockerfile`'s `DOTNET_CHANNEL` build arg; change it
only together with the runtime package.

The same pipeline compiles with Roslyn's `csc.dll` through the `dotnet` CLI and requires
`/opt/dotnet` plus *relative* symlinks named `latest` under `sdk/` and
`shared/Microsoft.NETCore.App/` — the Dockerfile creates both. `.NET` first-run/telemetry writes
are steered away from the wiped-per-submission sandbox `$HOME` by the `DOTNET_*` variables in
`services/worker/config.yml.template`.

**`python3` is 3.13, not Debian 12's stock 3.11.** Bookworm's own `python3` package is 3.11,
which rejects syntax students routinely write when developing against a newer interpreter
(e.g. PEP 701 same-quote-character nested f-strings, valid since 3.12) — that would fail
every submission using it with a bare `SyntaxError`, regardless of whether the logic is
correct. `python:3.13-slim` is built on Debian *13* (trixie); copying its binaries into this
bookworm-based image risks a glibc mismatch, so the worker Dockerfile instead compiles
CPython 3.13 from source in the builder stage (skipping `--enable-optimizations`, a 30+
minute PGO build that isn't worth it for grading short student submissions) and symlinks it
over `/usr/local/bin/python3` (which precedes `/usr/bin` on Debian's default `PATH`). `pytest`
and `pytest-console-scripts` are installed for this interpreter via pip (not the
`python3-pytest` apt package, which targets 3.11) — see the "Python 3.13" block in
`services/worker/Dockerfile` if you need to bump the version later.

**A "runtime environment" in the UI needs two things to actually work**: the worker image
must have the toolchain installed, *and* the core-api database needs a matching
`RuntimeEnvironment` + pipeline pair (the pipeline is what actually defines the
compile/run/judge steps — without one, the environment shows up in the exercise-config
dropdown but grading has nothing to execute). `db:fill`'s fixtures only ever provide the
former half (bare rows, no pipelines) for a fixed list that doesn't match what's installed
anyway, so this deployment does not use them; instead `services/api/Dockerfile` bakes in a
curated set of [ReCodEx/runtimes](https://github.com/ReCodEx/runtimes) packages (bash,
c-gcc-linux, cxx-gcc-linux, python3 — matching the worker's default toolchains exactly), and
`docker-entrypoint.sh` imports them (`runtimes:import`) alongside the `init` fixtures on
first boot.

To add a language: install its toolchain in `services/worker/Dockerfile`, add the matching
environment name to `headers.env` in `services/worker/config.yml.template`, download the
matching package from the [generic/](https://github.com/ReCodEx/runtimes/tree/main/generic)
folder into the `curl` loop in `services/api/Dockerfile`, then `docker compose build` and
(on an already-seeded instance) run `docker compose exec api php bin/console runtimes:import
--yes /opt/recodex-runtimes/<new-package>.zip` once by hand — the entrypoint only auto-runs
imports on a brand new (unseeded) database.

## Scaling workers

Add more worker instances by copying the `worker` service block in `docker-compose.yaml`
under a new name (e.g. `worker2`) with a distinct `WORKER_ID`. Each needs its own
`worker_cache` volume. Workers can also run on entirely separate physical machines pointed
at the same broker (`BROKER_URI: tcp://<broker-host>:9657`) and API
(`API_ADDRESS: https://<your-domain>/api`) — that's the deployment ReCodEx was actually
designed for.

## TLS / HTTPS

`services/proxy/nginx.conf.template` listens on plain HTTP by default. To enable HTTPS:

1. Get a certificate (e.g. via `certbot`) for `APP_DOMAIN`.
2. Mount it into the proxy container (uncomment the certs volume line in
   `docker-compose.yaml`) and uncomment the `listen 443 ssl` block in the nginx template.
3. In `.env`, set `PROTOCOL=https`, `MONITOR_PROTOCOL=wss`, `NOTIFIER_PORT=443`,
   `HTTPS_PORT=443` and rebuild `api`/`broker`/`worker` (they bake these into generated
   config at container start, no rebuild needed — just `docker compose up -d` again).

## Known upstream compatibility fixes applied

The `api` image build (`services/api/patch-compatibility.php`) patches a few things in
`repos/api` at build time, all against current `master` rather than any deliberate
misconfiguration on our side:

1. ~104 pre-2022 auto-generated migrations call `getDatabasePlatform()->getName()`, a method
   `doctrine/dbal` 4.x (pinned by upstream's current `composer.lock`) removed entirely —
   rewritten to the DBAL-4-recommended `instanceof AbstractMySQLPlatform` check.
2. Some of those same migrations mix DDL (`ALTER TABLE`) with an explicit
   `beginTransaction()`/`commit()` pair in a `postUp()`/`postDown()` hook — MySQL/MariaDB's
   implicit commit on DDL desyncs Doctrine's transaction-nesting bookkeeping from this,
   crashing with `SAVEPOINT ... does not exist`. Fixed by disabling the transactional wrapper
   (`isTransactional(): false`) and dropping the now-redundant explicit begin/commit calls,
   per Doctrine's own documented escape hatch.
3. `app/commands/runtimes/RuntimeImport.php` (the `runtimes:import` CLI command, see
   "Language toolchains" above) declares its own `-s`/`--silent` option, which collides with
   a `--silent` option the console `Application` itself already registers globally on the
   current `symfony/console` version — `LogicException: An option named "silent" already
   exists.`, thrown before the command ever runs. Fixed by dropping the redundant local
   declaration; the command's own `$input->getOption('silent')` still resolves against the
   global one.

On top of that, a handful of the historical migrations issue `ALTER TABLE ... CHANGE` on
columns that are part of a foreign key, which current MariaDB refuses even with
`FOREIGN_KEY_CHECKS=0` (this one doesn't have a clean per-statement fix). Rather than
patching around 8 years of schema evolution one incompatibility at a time, a **fresh**
database is bootstrapped by generating the schema directly from the current Doctrine entity
mappings (`orm:schema-tool:create`) and marking the full migration history as already
applied — see the `serve` branch of `services/api/docker-entrypoint.sh`. An **existing**
database (anything with a `doctrine_migrations` table already) instead runs the normal
`migrations:migrate`, so upgrades of an already-running install are unaffected by any of
this. `mysql` is also pinned to `mariadb:10.11` (LTS) rather than the floating `mariadb:11`
tag for the same reason (issue #1 above reproduces on every MariaDB version tested, 10.11
through 11.7+, since it's a dbal-version issue, not a MariaDB-version one — 10.11 was picked
as a conservative, long-supported baseline, not because newer MariaDB doesn't work).

## Updating

```bash
./pull-repos.sh               # bump repos.lock first, and COMPATIBILITY.md after verifying
docker compose build
docker compose up -d
```
The `api` container runs `migrations:migrate` on every boot (a no-op if nothing's new), so
schema updates that ship in a future upstream release apply automatically.

## Backups

Two volumes hold everything that matters: `mysql_data` (the database) and `api_storage`
(uploaded exercise/solution files, `storage/local` + `storage/hash`). Back these up; every
other volume (`*_log`, `worker_cache`) is disposable/regeneratable.
