# 002 — A submission is actually graded

**Status:** planned, not started · **Written:** 2026-09-11 · **Uncovered by:** plan 001

## Goal

A seeded student submits Python and the solution page shows points and a per-test verdict — the
correct solution passing, the wrong one failing. Plan 001 made the sandbox work; this is the step
between "the sandbox runs the wrong command successfully" and "the student gets a grade".

## Why it does not work today

The sandbox starts (`initFailed=False`, which is new) and the test fails inside it with
`Exited with error status 2`. The compiled job configuration says why. Its `run` task is:

```yaml
cmd:
  bin: /usr/bin/env
  args:
  - python3
  - cb83045aeb0c9d6a871c240f79b68507952a8308   # the runner, fetched by hash -- correct
  - ${EVAL_DIR}/                               # should be the student's file
```

The third argument is a **directory**, so the runner — which does `Path(sys.argv[0]).open('rb')` —
raises `IsADirectoryError`, and its own `except BaseException: sys.exit(2)` turns that into exit 2.
Python's runner script is not at fault; it is being handed nothing to run.

Two symptoms, and it is not yet established whether they are one bug or two:

1. **The entry point is empty.** `${EVAL_DIR}/` is what an empty file name renders as.
2. **The source-files pattern is not expanded.** In the same job the solution is copied with
   `cp ${SOURCE_DIR}/*.py ${SOURCE_DIR}/Test 1/*.py`, and the resulting file in the sandbox is named
   literally `*.py`. The 14 bytes in it are the right content, so the *file* arrives; only its name
   is the unexpanded glob.

This is not specific to macOS, to Docker or to cgroups. It would fail identically on a production
host; it was simply invisible while no submission reached the sandbox at all.

## What investigation established

- **The runner is fine.** `runner.py` is attached to the pipeline (10 rows in
  `pipeline_exercise_file`), fetched correctly by hash, and runs correctly under Python 3.13 when
  handed a real file — checked by hand in the container.
- **The command is assembled by `ScriptExecutionBox::compile`** (core-api,
  `app/Helpers/ExerciseConfig/Pipeline/Box/Boxes/ScriptExecutionBox.php:108`) as
  `runtime-args` + `entry-point` + `args`. For the Python pipeline that is
  `["python3"]` + the runner + `merged-run-args`, and `merged-run-args` is a `merge-strings` of
  `entry-point-array` and `run-args`. So the offending `${EVAL_DIR}/` arrives through
  `entry-point-array` ← `entry-point-str` ← a `file-name` box over the `entry-point` variable.
- **Setting `entry-point` does not help, which is the surprising part.** Writing `solution.py` into
  the exercise config's `entry-point` variable persists (a read-back confirms it) and the recompiled
  job still contains `${EVAL_DIR}/`. So either the compiler reads the entry point from somewhere
  else, or an empty-string sentinel is involved — `lib/exercise-config/simple-config.ts` in the
  frontend knows an `ENTRY_POINT_SENTINEL = "$entry-point"`, which suggests the value is a
  *reference* and overwriting it with a literal is the wrong move.
- **`source-files` exists only in the environment config**, as
  `{name: "source-files", type: "file[]", value: ["*.py"]}`. The seed's own comment says that table
  is what `POST /pre-submit` wildcard-matches submitted file names against — so the glob belongs
  there. What is unestablished is who is supposed to turn it into `solution.py` for the job, and
  whether an exercise configured through this app's own screens (T-009) comes out differently.

## The work

Ordered so that the cheap discriminator comes first.

1. **Configure the same exercise through the app's own screens and diff the two configs.** T-009's
   editor writes a configuration core-api accepts; the seed writes one by hand. If a
   screen-configured exercise compiles a correct job, the bug is in `scripts/seed.ts` and this is a
   seed fix. If it compiles the same broken job, the bug is in core-api or in the runtime package's
   pipeline, and the next step is different. **Do this before anything else** — it decides which
   repository the rest of the work lands in.
2. **Read the compiler, not the configuration.** `ExerciseConfigCompiler` and the `file-name` /
   `string-to-array` / `merge-strings` boxes decide what an empty or referenced variable renders
   as. The question to answer precisely: what must the exercise config contain for
   `entry-point-array` to come out as `["solution.py"]`?
3. **Fix it where step 1 says it belongs** — most likely `scripts/seed.ts` in `upcode-web-ui`,
   possibly `upcode-api`.
4. **Re-seed and re-verify.** The seeded solutions currently carry infrastructure failures from
   before plan 001; after this they should carry genuine verdicts, which is also what makes the
   fixtures honest.
5. **Update the e2e suite.** Several specs assert the old state in so many words —
   `reference-solutions.spec.ts` asserts "Isolate init error" — and will fail once evaluation
   works. That is the change working. Expect to touch the specs that assert points and verdicts.

## Still open

- Whether the `*.py` name and the empty entry point are one bug or two.
- Whether C# is affected the same way. Its pipeline is a different one (Roslyn), and the
  toolchains are not in the running images yet (see COMPATIBILITY.md), so this has not been looked
  at. Worth checking straight after Python works, before concluding anything about C#.
- Whether the ReCodEx demo fixtures (`db:fill demo`, which this deployment deliberately does not
  load) contain a correctly configured exercise that could be read as a reference.

## Done when

`[seed] correct` scores full points and `[seed] wrong` scores zero, through the frontend, and
`COMPATIBILITY.md` says evaluation is verified end to end with the date.

## Out of scope

- C# and Java. Their toolchains are committed but absent from the running images; rebuilding and
  importing them is a separate step with its own recipe in `COMPATIBILITY.md`.
- Anything about the sandbox. Plan 001 closed that; if a submission fails *inside* isolate with a
  real verdict, this plan has succeeded.
