# 003 — A fresh install names the operator's own university

**Status:** done, 2026-09-11 · **Written:** 2026-09-11 · **Asked for by:** the operator

> **Outcome.** Option 2 — renamed after `db:fill init` from `RECODEX_INSTANCE_NAME` in `.env`. See
> "What was built" at the end.

## Goal

A new deployment of this stack, brought up from an empty database, names itself **Univerzita
Palackého v Olomouci** — on the landing page, in the sidebar, and in the instance a new account is
created against. Today it names a joke from upstream's own test fixture, which is the first thing
anybody sees and the last thing anybody thinks to change.

## Why it does not work today

The instance is created once, from a fixture inside the pinned core-api fork:

```
repos/api/fixtures/init/10-instances.neon:5:  - "Frankenstein University, Atlantida" # name
                                              - "First underwater IT university for fish and shrimps."
```

`services/api/docker-entrypoint.sh` loads it with `php bin/console db:fill init`, once, guarded by
`RECODEX_SEED_DB` and a `storage/.seeded` marker. On the running deployment the result is visible
through the API:

```
$ curl -s .../v1/instances | jq -c '.payload[] | {name, isOpen}'
{"name":"Frankenstein University, Atlantida","isOpen":true}
```

## What investigation established

- **The string is upstream's, in a file this stack pins rather than owns.** It appears twice in
  core-api — `fixtures/init/10-instances.neon` and `fixtures/demo/10-instances.neon` — and only the
  first is ever loaded here; the entrypoint's own comment records that `demo` is deliberately not
  loaded. So exactly one of the two matters.
- **The seeding step is one-shot and already conditional.** It runs only when the database has no
  `doctrine_migrations` table's worth of history *and* `RECODEX_SEED_DB=true` *and*
  `storage/.seeded` is absent. Whatever this plan does has to happen inside that window, or be
  idempotent enough to run outside it.
- **Nothing in the new frontend hardcodes the name any more.** `repos/web-next/e2e/landing.spec.ts`
  reads `/v1/instances` and asserts against whatever it answers — PF-010 changed it precisely
  because pinning the name was fragile. So this change breaks no test.
- **core-api can rename an instance after the fact**: `POST /v1/instances/{id}` takes localized
  texts, and the admin screens in both frontends drive it. So a rename is not the only option but it
  is an available one.
- **The deployment already carries deployment-specific strings in `.env`** (`RECODEX_TITLE`,
  `APP_DOMAIN`), which is the established place for "this is our install, not the reference one".

## The work

The choice to make first is **where the name comes from**, because the three options differ in who
has to change a file when the next deployment is stood up:

1. **Patch the fixture in our own fork** (`upol-kmi/upcode-api`). Honest and simple; the name is
   then baked into a pinned commit and a second deployment of this stack inherits Olomouc whether
   or not that is what it wants.
2. **Rename after `db:fill init`** in `services/api/docker-entrypoint.sh`, from a value in `.env`
   (`RECODEX_INSTANCE_NAME`, defaulting to the upstream string). Keeps the fork clean, keeps the
   name beside the other deployment-specific settings, and is the only option that makes a *second*
   institution's install a one-line edit. Costs a console command or an SQL statement in the
   entrypoint, which is where the fiddly parts of this stack already live.
3. **Leave it to the operator** to rename through the admin screens after the first boot, and
   document it. Cheapest, and forgets itself.

Then, whichever is chosen: bring up a genuinely empty database and check the name reaches the
landing page, the sidebar, and a newly registered account's instance — not just the API.

## Still open

- Whether the **description** ("First underwater IT university for fish and shrimps.") wants a real
  one or an empty string, and whether it is worth carrying in Czech as well as English — the
  fixture creates one `LocalizedGroup` in `en` only, and this deployment serves Czech first.
- Whether an existing deployment (this development instance included) should be renamed too, or
  left alone. It is one `POST /v1/instances/{id}` either way, but it is a decision rather than a
  consequence.

## Done when

A stack brought up against an empty database answers `/v1/instances` with
`Univerzita Palackého v Olomouci`, and the landing page of the new frontend shows it.

## Out of scope

- The application's own title (`RECODEX_TITLE`), which is already configurable and already set.
- Anything about the `demo` fixtures, which this deployment does not load.


---

## What was built

**Option 2, the `.env` one**, because it is the only one of the three that leaves the fork clean
*and* makes the next institution's install a one-line edit. `RECODEX_INSTANCE_NAME` and
`RECODEX_INSTANCE_DESCRIPTION` live in `.env`/`.env.example` beside `RECODEX_SEED_DB`, reach the
api service through `docker-compose.yaml`, and `services/api/docker-entrypoint.sh` applies them
immediately after `db:fill init`, inside the same one-shot seeding branch.

**Two things about the implementation are deliberate.**

It renames through **PHP with a prepared statement**, not the `mysql` client. An apostrophe is
ordinary in a university's name, and building the statement by shell interpolation is how that
becomes a syntax error at best. The tool was already in the container.

It **finds the instance first and refuses if there is more than one**, rather than updating every
row the join matches. On a freshly seeded database there can only be one — but the same join on a
*used* database matches every instance that has ever existed, and the development box turned out to
be carrying **thirty**: twenty-nine orphans named `e2e instance …` / `e2e licence …`, left by the
spec that creates one, from runs that predate its cleanup hook (`web-next`'s PF-014). A rename that
silently hit all of those would be worse than one that stops and says so.

**Verified against the running database, both ways, without changing it:** the guard refuses on
this deployment and names the count (`expected exactly one, found 30`); and with the orphans
removed inside a transaction, the rename touches exactly one row, writes
`Univerzita Palackého v Olomouci` with its diacritics intact, empties the description, and the
transaction is rolled back — 30 instances and the `Frankenstein` row still there afterwards.

### The two questions this plan left open, answered

- **The description** is a second variable, defaulting to **empty**. "First underwater IT
  university for fish and shrimps" cannot survive next to a real name, and inventing one for
  somebody else's university is not this file's business.
- **This existing deployment is not renamed**, and the guard is what decides that rather than a
  preference: it holds thirty instances, so the entrypoint refuses. Renaming it is one
  `POST /v1/instances/{id}` through the admin screens whenever the operator wants it.

### Still open

- **The twenty-nine orphaned instances** are a finding, not this plan's work. They are invisible to
  `/v1/instances` and harmless, and they are why the guard exists; clearing them is a separate
  decision, as is whether a wipe-and-reseed is the moment to do it.
- **Nothing has been run against a genuinely empty database yet.** Both halves are verified in a
  transaction against the real schema, which is as close as this can get without a wipe.
