# 004 — The new frontend is what the deployment serves

**Status:** done, 2026-09-11 · **Written:** 2026-09-11 · **Asked for by:** the operator

> **Outcome.** The deployment serves the new frontend, every legacy URL has somewhere to go, and
> the legacy app is still running on a port of its own. See "What was built" at the end.

## Goal

Somebody who opens the deployment's address gets the **new** frontend, and a link they bookmarked
against the legacy one still lands them where that link meant — not on a 404.

## Why it does not work today

`services/proxy/nginx.conf.template` sends the root at the legacy app:

```nginx
location / {
    proxy_pass http://web-app:8080;
}
```

`web-next` is reachable only on its own host port (`WEB_NEXT_PORT`, 3001). The two never compete
for a URL, which is why nothing about old links has had to be decided yet.

## What investigation established

- **COMPATIBILITY.md's "switching it over is one entry in that template" is not the whole job**,
  and `repos/web-next/docs/ROUTES.md` says so in as many words: the redirect table at the bottom of
  that file "is what has to exist **before** this app takes over `/`". Without it every bookmark,
  every link in an old email and every `/app/...` URL a teacher has written down answers 404.
- **Every route moved, and not only by renaming.** Three shapes of change: a **locale prefix** on
  everything (`/dashboard` does not exist; `/en/dashboard` and `/cs/dashboard` do), six group
  screens **collapsed into tabs** (`?tab=`), and solutions **dropping their assignment context**
  (`/app/assignment/:a/solution/:s` → `/solutions/:s`).
- **The redirect table is already written**, as a `redirects()` block for `next.config.ts`, with the
  locale problem solved the right way round: redirects run *before* `proxy.ts`, so they send to the
  unprefixed path and let the next hop negotiate the language rather than hardcoding one.
- **Two of its rules are stale in our favour.** It records `/app/assignment/:a/solution/:s/diff/:o`
  and `/app/shadow-assignment/:id/edit` as having nowhere to go, "until those are built". **Both
  are built** — G-005 shipped `/solutions/[id]/diff/[otherId]` and G-009 shipped
  `/shadow-assignments/[shadowId]/edit` — so the table gains two rules rather than two gaps.
- **`next.config.ts` has no `redirects()` at all today**, and `proxy.ts` rewrites nothing but the
  locale, so there is nothing to unpick first.
- **The legacy app is still useful and this does not have to remove it.** COMPATIBILITY.md pairs
  the cutover with retiring the `web-app` service and `repos.lock`'s exception for it; those can
  follow once the new one has been the front door for a while. Keeping it on a port costs nothing.

## The work

1. **Add `redirects()` to `next.config.ts`** from ROUTES.md's table, plus the two rules its "nowhere
   to send them" note can now lose. This is `web-next`'s code, not the deployment's.
2. **Check them against the built app**, which means `next build` and real requests: a redirect that
   points at a route that does not exist is worse than no redirect, and the table was written by
   reading rather than by trying.
3. **Point `location /` at `web-next:3000`** in `services/proxy/nginx.conf.template`. Keep
   `/api/` and `/ws` exactly as they are — the new app calls core-api through the public URL and the
   monitor socket through `/ws`, and both already work.
4. **Decide what the legacy app is for afterwards.** Leaving `web-app` on its own port is the
   smallest step and keeps the reference; removing the service is a separate call with `repos.lock`
   attached to it.
5. **Re-run the e2e suite**, which drives the app through its own base URL rather than the proxy, so
   it should be unaffected — and that is worth confirming rather than assuming.

## Still open

- **Whether `web-app` keeps a port at all.** Not decided here; step 4 is deliberately a decision.
- **What `/api/` should answer once the legacy app is gone.** Nothing changes now, but the legacy
  app is the only thing that needs the `/api/` alias to look exactly as it does; the new one could
  in principle talk to core-api by another name.
- **Whether a redirect should be permanent.** The table says `permanent: true`, which browsers cache
  hard. That is right for a rename that will never be undone and unkind if the cutover has to be
  rolled back within the day.

## Done when

The deployment's address serves the new frontend, and `/app`, `/app/group/<id>/students`,
`/registration` and a legacy solution URL each land on the right new screen rather than a 404.

## Out of scope

- Removing the `web-app` service, and `repos.lock`'s exception for it.
- Anything about TLS, which the template still leaves commented out for an operator to fill in.


---

## What was built

**The redirects went into `repos/web-next/next.config.ts`**, not into nginx, because the mapping is
a property of the app's routes rather than of this deployment: the same table has to hold wherever
the app is served from. ROUTES.md's block was taken as written, with the locale reasoning intact --
nothing carries a locale, so `proxy.ts` negotiates one on the next hop.

**Two rules were gaps in that table and are rules now.** It recorded
`/app/assignment/:a/solution/:s/diff/:other` and `/app/shadow-assignment/:id/edit` as having
nowhere to send anybody "until those are built". G-005 and G-009 built them, so both redirect
properly instead of being dropped. The second had to go **above** the bare
`/app/shadow-assignment/:id` rule, since Next takes the first match.

**One rule from the table is deliberately not in the code, and it is the one that mattered.**
`/login/:redirect*` matched bare `/login` and sent it to `/login`: a permanent self-redirect on the
one route an unauthenticated visitor must reach, and exactly where this app's own logout lands
(F-017 303s to the locale-neutral `/login` so `proxy.ts` can pick the language). Two specs caught
it. What it would have bought is a URL nobody bookmarks — the legacy app carried the redirect
target in a path segment and the table already threw that target away — so `/login/<target>` is
left to 404 and `/login` works.

**The diagnosis went wrong first, and that is the part worth carrying forward.** Removing the rule
appeared not to fix the loop, which nearly sent this somewhere else entirely. The fault was the
harness: those probes ran against `pnpm start`, which Next itself warns does not work with
`output: standalone`. Through the **container** the answer was unambiguous — without the rule
`/login` answers `307 /en/login`, with it a `308` loop. **Verify redirects through the container**;
a local `next start` is not this app's runtime.

**Checked by asking, not by reading.** Every rule was driven against a real build: 24 legacy paths,
each answering `308` to the destination the table promises. The two-hop chain a visitor actually
makes was confirmed end to end -- `/app` → `/dashboard` (the redirect) → `/en/dashboard` (the
locale) -- and so was the reason for it: with `Accept-Language: cs` the same path lands on
`/cs/dashboard`. Hardcoding a locale would have sent half this deployment's users to the wrong one.

**One thing the plan had wrong, found by looking rather than by assuming.** Step 4 called leaving
`web-app` "on its own port" the smallest step; it did not have one. `WEB_APP_PORT` is the port the
app listens on *inside* the container, and the service published nothing -- this proxy was the only
way anybody reached it. So the cutover as first written would have made the legacy app unreachable
rather than merely no longer the front door. It publishes `${WEB_APP_PORT}` now.

### Verified

Through the deployment's own address: `/` serves the new frontend (`307` to the negotiated locale),
`/app`, `/app/group/<a real id>/students`, `/registration` and a legacy solution URL each land on
the right new screen, `/api/` and `/ws` are untouched, and the legacy app answers on its own port.

### Still open

- **Retiring `web-app`** -- the service, its build, and `repos.lock`'s exception for the one
  unforked repo -- is deliberately not done. It is worth keeping while the pipelines and runtimes
  are still moving, and it now costs one published port rather than the front door.
- **The redirects are `permanent: true`**, which browsers cache hard. That is right for renames
  nobody intends to undo, and it is the thing to remember if the cutover is ever rolled back: a
  visitor who has followed one will keep following it from cache.
