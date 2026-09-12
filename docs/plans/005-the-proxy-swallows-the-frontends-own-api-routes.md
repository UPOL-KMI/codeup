# 005 — The proxy swallows the new frontend's own `/api/` routes

**Status:** done, 2026-09-12 · **Written:** 2026-09-12 · **Found by:** running the new frontend's
e2e suite against this deployment's address for the first time

> **Outcome.** `location /api/` is narrowed to `location /api/v1`, so core-api keeps the whole of
> its public surface and the new frontend's own Route Handlers reach the app. See "Verified".

## The defect

Plan 004 pointed `location /` at `web-next` and kept `/api/` and `/ws` "exactly as they are". For
`/ws` that was right. For `/api/` it was right about core-api and wrong about the app:

**The new frontend serves its own routes under `/api/`.** `app/api/auth/login`, the whole upload
and download surface, `/api/search`, `/api/auth/logout`, `/api/auth/effective-role` — the BFF layer
the brief's §5 requires, because the access token must never reach client JavaScript, which means
the browser talks to the app and the app talks to core-api. nginx matched those paths first and
proxied them to core-api, which answered its own 404:

```
POST /api/auth/login      -> 404, X-Powered-By: Nette Framework 3   (core-api answered)
POST /api/auth/login      -> 400                                     (the app, on its own port)
```

So **logging in through this deployment's address was impossible** from the moment of the cutover,
while the identical container on `WEB_NEXT_PORT` was fine.

## Why neither the plan nor the suite saw it

Plan 004's step 5 says the e2e suite "drives the app through its own base URL rather than the
proxy, so it should be unaffected — and that is worth confirming rather than assuming". It was
confirmed, and it is true. It is also the blind spot: a suite that never goes through the proxy
cannot see what the proxy does. The plan's own verification exercised redirects, which are the
app's, and `/api/` and `/ws`, which are core-api's and the monitor's — but nothing that is the
app's *under a prefix the proxy claims*.

## The fix

`services/proxy/nginx.conf.template`:

```diff
-    location /api/ {
-        proxy_pass http://api:80/;
+    location /api/v1 {
+        proxy_pass http://api:80/v1;
```

`/api/v1` is the whole of core-api's public surface and always has been — `services/web-app/env.json.template`
sets `API_BASE` to `${API_ADDRESS}/v1`, and the `web-next` service's `API_BASE_PUBLIC` is
`${PROTOCOL}://${APP_DOMAIN}/api/v1`. Nothing addresses core-api at `/api/` and something else.
Everything under `/api/` that is not `/api/v1` now falls through to `location /`, which is the app.

The prefix is written without a trailing slash on both sides so that `/api/v1` with no path of its
own matches too, and the rewrite is the same one as before for everything below it.

## Verified

Through the deployment's address, after `docker compose restart proxy`:

| Request | Before | After |
| --- | --- | --- |
| `POST /api/v1/login` (real credentials) | 200, core-api | 200, core-api — `success: true` |
| `POST /api/auth/login` (empty body) | 404, core-api | 400, the app |
| `GET /api/search?q=test` (no session) | 404, core-api | 401, the app |
| `GET /en/login` | 200 | 200 |

And the new frontend's full e2e suite, run against `http://localhost` rather than its own port.

## Still open

- **The legacy app still calls `/api/v1`** from its own port and is unaffected by this. Retiring
  `web-app` remains plan 004's open question, not this one's.
- **Nothing else in the deployment claims a prefix the app also serves.** `/ws` is the monitor's and
  the app has no route there. Worth re-checking if a service is ever added in front of the root.
