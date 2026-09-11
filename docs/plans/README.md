# Plans

Work that spans more than one repository gets planned here, in `upcode-deploy`, because this is the
repository that holds the stack together — a plan that lives in one component's fork cannot say
what the other components have to do.

One file per piece of work, numbered, named after the outcome rather than the technique. A plan is
written **before** the work and is expected to be wrong in places; what it is for is to make the
unknowns explicit before anybody starts, and to record what investigation established so the next
person does not repeat it.

| Plan | Status |
| ---- | ------ |
| [001 — Evaluation works locally on macOS (cgroup v2)](001-cgroup-v2-local-evaluation.md) | done — sandbox works; uncovered 002 |
| [002 — A submission is actually graded](002-exercise-config-source-files.md) | done — a seeded solution scores 10/10 |
| [003 — A fresh install names the operator's own university](003-instance-name-on-a-fresh-install.md) | planned |

**Sections a plan should have**, because each of them has earned its place:

- **Goal** — in terms of something a person can do afterwards, not a change to be made.
- **Why it does not work today** — with the actual output, not a description of it.
- **What investigation established** — the facts, each with how it was checked. This is the part
  worth the most later; it is also the part that stops a plan being a guess.
- **The work** — in dependency order, saying which repository each step touches.
- **Still open** — what was not established, and what would settle it.
- **Done when** — an observable outcome.
- **Out of scope** — the things a reader will otherwise assume are included.
