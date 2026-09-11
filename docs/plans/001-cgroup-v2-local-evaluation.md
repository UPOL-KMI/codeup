# 001 — Evaluation works locally on macOS (cgroup v2)

**Status:** planned, not started · **Written:** 2026-09-11

## Goal

Submit a Python solution through the new frontend on a Mac running Docker Desktop and get a **real
verdict** — a correct solution passes, a wrong one fails, and the time and memory limits are
actually enforced. Today every submission resolves to an infrastructure error instead, which means
the one thing ReCodEx exists to do cannot be tested locally at all.

## Why it does not work today

The worker runs submitted code inside `isolate`, and the vendored `isolate` is **1.8.1**, which
understands only cgroup **v1**. Docker Desktop's Linux VM provides cgroup **v2** exclusively. From
the running worker:

```
Checking for cgroup support for memory ... CAUTION
WARNING: the memory is not present. isolate --cg cannot be used.
Checking for cgroup support for cpuacct ... CAUTION
Checking for cgroup support for cpuset ... CAUTION
Checking for swap ... FAIL
```

`README.md` currently answers this with "boot the production kernel with
`systemd.unified_cgroup_hierarchy=0`", which is correct for a real server and unavailable on Docker
Desktop. So the local answer has to be the other one: **move to `isolate` 2.x, which requires
cgroup v2** — the mirror image of 1.8.1's requirement, not a superset of it.

## What investigation established

Eight things, each checked rather than assumed. Together they are why this is a small plan and not
a large one.

**1. cgroup v2 delegation works inside the worker container, with no systemd.** Run live against
the container as it is today:

```
mkdir /sys/fs/cgroup/isolate.test                       → OK
echo "+memory +cpu +cpuset" > .../cgroup.subtree_control → OK  (reads back: cpuset cpu memory)
mkdir .../isolate.test/box0                             → OK  (controllers: cpuset cpu memory)
echo 268435456 > .../box0/memory.max                    → OK
```

The container runs `privileged: true` with `cgroup: host`, so it sees the host hierarchy, whose
root already has `memory cpu cpuset` in `cgroup.subtree_control`. This is the load-bearing finding:
without it the whole plan would need a VM instead.

**2. `cg_root` may be an explicit cgroupfs path, so `isolate-cg-keeper` and systemd are not
needed.** `default.cf.in` in v2.7 offers either a path or `auto:<file>`; `cg.c:181` only reads the
file in the `auto:` case. The systemd units exist for hosts that have systemd, which a container
does not.

**3. Exactly one option the worker passes was removed.** Diffing the man pages of 1.8.1 and v2.7:
removed is `--cg-timing` and nothing else; ten options were added. The worker passes
`--cg --cg-timing --box-id --cg-mem --time --wall-time --extra-time --stack --fsize --stdin
--stdout --stderr --stderr-to-stdout --chdir --processes --share-net --env --dir --meta --run`, so
the patch is the deletion of one line in `isolate_sandbox.cpp`.

**4. The meta-file format is unchanged.** Both versions document the same twelve keys, and the
seven the worker parses — `cg-mem`, `csw-voluntary`, `exitcode`, `max-rss`, `status`, `time`,
`time-wall` — are all in v2.7. No parser change.

**5. Every patch in the ReCodEx fork of isolate is either upstream in 2.7 or irrelevant.** This was
the biggest risk and it evaporated:

| Fork patch | In v2.7? |
| ---------- | -------- |
| Bring up the loopback interface (their own, citing `ioi/isolate` issue #106) | **Yes, natively** — `isolate.c:727` sets up `lo`, and the man page says the namespace "contains no network devices except for a per-namespace loopback" |
| `--tty-hack` | Yes, and the worker does not use it anyway |
| Open-file limit raised to 4096 | v2.7 defaults to 1024 with an `--open-files` option; see "Still open" |
| `-fPIC` for GCC 14.3, compile fix for el10 | Moot — we build on `debian:12` (GCC 12), and v2.7 already hardens with `-fPIE -pie` |
| RPM `.spec` file | Irrelevant to a Docker build |
| execve failure attribution | Present in both |

So this is "take v2.7 from `ioi`", not "port a pile of patches onto it".

**6. v2.x behavioural changes worth knowing before they surprise somebody.** `--init` now resets an
existing sandbox and reserves it until `--cleanup`, and two `--run`s on one box in parallel are
refused (2.0); cgroup memory limits no longer survive between runs on the same sandbox (2.7 — the
worker re-passes `--cg-mem` every run, so this is fine); `/dev/shm` is a fresh tmpfs per sandbox
rather than shared (2.6); the syscall filter rejects `io_uring` by default (2.6). 2.5 fixed several
privilege-boundary vulnerabilities, which is a reason to move regardless of cgroups.

**7. New build dependencies.** v2.7 links `-lcap -lseccomp`; the builder stage has `libcap-dev` but
**not** `libseccomp-dev`, and the runtime stage will need `libseccomp2`. `make install` also builds
`isolate-cg-keeper`, which needs `libsystemd-dev` — either install it in the builder, or install the
two binaries we want by hand.

**8. The current isolate config is close to what 2.7 wants.** In the image today:

```
box_root = /var/local/lib/isolate
cg_root = /sys/fs/cgroup
first_uid = 60000
first_gid = 60000
num_boxes = 1000
```

`first_uid`/`first_gid`/`num_boxes` are still supported in 2.7. What changes is `cg_root` (must be
our delegated subtree, not the hierarchy root) and a new `lock_root`.

## The work

In dependency order. Three repositories, and the deploy repository does most of it.

### Step 1 — `upcode-isolate`: bring in v2.7

On the `upcode` branch, take `ioi` v2.7. The `ioi` remote is already configured in
`repos/isolate`. Because every fork patch is either upstream or moot (finding 5), the honest shape
is **reset onto the tag** rather than a merge that pretends to carry history forward — a merge here
would produce conflicts in files whose fork-side changes we have just established we do not want.
Record in the commit message which fork patches were dropped and why, with finding 5's table.

Keep `master` as the untouched mirror of `ReCodEx/isolate`. Pin `repos.lock` to the new commit.

### Step 2 — `upcode-worker`: drop `--cg-timing`

One line in `src/sandbox/isolate_sandbox.cpp` (~323). Nothing else: the option set and the
meta-file format are otherwise identical (findings 3 and 4).

### Step 3 — `upcode-deploy`: build isolate 2.7

`services/worker/Dockerfile`: add `libseccomp-dev` (and `libsystemd-dev`, unless the two binaries
are installed by hand) to the builder, `libseccomp2` to the runtime stage. The existing comment
about `DESTDIR` being baked into `config.o` still applies and must survive the edit — it is a real
trap, not decoration.

### Step 4 — `upcode-deploy`: delegate a cgroup subtree at container start

`services/worker/docker-entrypoint.sh`, before the worker starts:

- `mkdir -p /sys/fs/cgroup/isolate`
- `echo "+memory +cpu +cpuset" > /sys/fs/cgroup/isolate/cgroup.subtree_control`
- `mkdir -p /run/isolate/locks`
- fail loudly if any of it does not work, rather than starting a worker that will fail every job

It has to happen on every start, because the subtree does not survive the container. Note that it
is created in the **host's** root cgroup rather than under the container's own: cgroup v2 forbids a
non-root cgroup from holding processes while enabling controllers for children, and the container's
own cgroup holds the worker. The root is exempt from that rule, which is why finding 1 works.

Update the isolate config (finding 8): `cg_root = /sys/fs/cgroup/isolate`,
`lock_root = /run/isolate/locks`.

### Step 5 — `upcode-deploy`: stop saying cgroup v1

`docker-compose.yaml`'s worker comment, `docker-entrypoint.sh`'s check banner ("not compatible with
isolate 1.8"), the README's "⚠️ Before going to production" section and `COMPATIBILITY.md`'s
"Known not working" entry all currently document the opposite of what will be true. The production
advice inverts too: with isolate 2.x a **v2 host is the requirement**, which is what modern servers
already default to — so this removes a production prerequisite rather than adding one.

### Step 6 — verify, and verify the right thing

`isolate-check-environment` passing is not the goal; a verdict is.

1. `docker compose build worker && docker compose up -d`, then the environment check in the log.
2. `isolate --cg --box-id=0 --init` / `--run` / `--cleanup` by hand inside the container, on a
   trivial program, reading the meta file.
3. Through the new frontend as a seeded student: submit the **correct** Python solution to
   `[seed] Echo Greeting` and get points; submit the **wrong** one and get zero.
4. Limits are real: a solution that loops forever must be killed on wall-time, and one that
   allocates beyond `--cg-mem` must be killed on memory — not merely reported as an infrastructure
   failure.
5. Re-run the frontend's e2e suite. Several specs assert the infrastructure-failure state that this
   change removes (`reference-solutions.spec.ts` asserts "Isolate init error" in so many words),
   so **expect some to fail and to need updating** — that is the change working, not breaking.

Then re-seed, so the seeded solutions carry genuine verdicts instead of infrastructure errors, and
update `COMPATIBILITY.md` with what was verified.

## Still open

- **Open-file limit.** The fork raised it to 4096; v2.7 defaults to 1024 and offers `--open-files`.
  The worker does not pass it. 1024 is almost certainly fine for student submissions — but it is a
  silent behaviour change, so it belongs in the commit message, and if anything hits it the fix is
  one argument in `isolate_run_args`.
- **Swap accounting.** The current check says "swap is enabled, but swap accounting is not. isolate
  will not be able to enforce memory limits." Whether Docker Desktop's VM gives us
  `memory.swap.max` is unchecked; step 6.4 is what would reveal it. If limits turn out
  unenforceable, memory-limit test cases are untestable locally even after this plan — worth
  knowing early.
- **Concurrency.** v2.0's locking refuses two parallel `--run`s on one box id. The worker allocates
  a box per concurrent job and should be fine, but the local worker runs with a small number of
  threads and this has not been exercised.
- **Production shape.** On a systemd host the shipped `isolate.service`/`isolate.slice` delegation
  is the proper mechanism, and the entrypoint's manual `mkdir` is the container-shaped substitute.
  Both can coexist — `cg_root` is configuration — but production deployment should prefer the units.

## Done when

A seeded student submits Python through the new frontend and the solution page shows points and a
per-test verdict, a wrong solution shows zero, and the worker log shows no isolate environment
warnings. `COMPATIBILITY.md` says evaluation is verified, with the date.

## Out of scope

- **C# and Java.** Already committed (`1a4d20b`) and absent only from the running images.
  `COMPATIBILITY.md` has the rebuild-and-import recipe, including the `storage/.seeded` trap that
  makes a rebuild alone insufficient. Worth doing in the same rebuild, but it is not this plan.
- **Switching the proxy to the new frontend.** `location /` still serves the legacy `web-app`, and
  keeping it is deliberate while runtimes are being worked on.
- **Production kernel or host configuration.** This plan is about making a Mac usable for testing.
