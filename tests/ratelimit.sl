// `rateLimit(options)` -- a fixed window per key, and `429` over it.
//
// **The clock is driven and not waited on.** A limiter is a thing about time, and a suite that
// proved a window resets by sleeping through one would be slow, flaky and no more convincing --
// `now` is an option for exactly this, and a program in production leaves it alone.

import { api, rateLimit, rateStore, request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

// An api limiting one endpoint against a clock the test moves.
made(clock, options: object) -> object
    val app = api()
    var settings = { limit: 2, window: 1000, now: clock, key: (req) -> "one" }

    for [k, v] in entries(options)
        settings[k] = v

    app.get("/notes", rateLimit(settings, (req) -> "the notes"))

    app

@test
async A_CLIENT_UNDER_THE_LIMIT_REACHES_THE_HANDLER()
    var at = 0
    val app = made(() -> at, {})

    val one = await app.handle(request("GET", "/notes"))
    val two = await app.handle(request("GET", "/notes"))

    assertEq(response(one).body, "the notes")
    assertEq(response(two).body, "the notes")

@test
async THE_ANSWER_SAYS_WHAT_IS_LEFT_OF_THE_ALLOWANCE()
    // **A client that cannot see its own allowance can only find the edge by falling off it.**
    var at = 0
    val app = made(() -> at, {})

    val one = await app.handle(request("GET", "/notes"))

    assertEq(header(one, "X-RateLimit-Limit"), "2")
    assertEq(header(one, "X-RateLimit-Remaining"), "1")
    assertEq(header(one, "X-RateLimit-Reset"), "1")

    val two = await app.handle(request("GET", "/notes"))

    assertEq(header(two, "X-RateLimit-Remaining"), "0")

@test
async ONE_OVER_THE_LIMIT_IS_A_429_WITH_A_Retry_After()
    var at = 0
    val app = made(() -> at, {})

    await app.handle(request("GET", "/notes"))
    await app.handle(request("GET", "/notes"))

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 429)
    assertEq(doc(r).title, "Too Many Requests")
    assertEq(doc(r).instance, "/notes")
    assertEq(header(r, "Retry-After"), "1")
    assertEq(header(r, "X-RateLimit-Remaining"), "0")

@test
async THE_HANDLER_DOES_NOT_RUN_FOR_A_REQUEST_THAT_IS_REFUSED()
    // **Not calling the handler IS the refusal**, this package having no `next` to decline to call.
    var ran = 0
    var at = 0
    val app = api()

    counted(req)
        ran = ran + 1

        "the notes"

    app.get("/notes", rateLimit({ limit: 1, window: 1000, now: () -> at, key: (req) -> "one" }, counted))

    await app.handle(request("GET", "/notes"))
    await app.handle(request("GET", "/notes"))

    assertEq(ran, 1)

@test
async Retry_After_IS_THE_TIME_LEFT_IN_THE_WINDOW_AND_NEVER_ZERO()
    // **Exact rather than guessed**, which is what a fixed window buys and why it is pleasant to be
    // on the wrong side of -- and never `0`, which would be a client told to try again at once.
    var at = 0
    val app = made(() -> at, { window: 10000 })

    await app.handle(request("GET", "/notes"))
    await app.handle(request("GET", "/notes"))

    at = 2500

    assertEq(header(await app.handle(request("GET", "/notes")), "Retry-After"), "8")

    at = 9999

    assertEq(header(await app.handle(request("GET", "/notes")), "Retry-After"), "1")

@test
async THE_WINDOW_RESETS_AND_THE_ALLOWANCE_COMES_BACK()
    var at = 0
    val app = made(() -> at, {})

    await app.handle(request("GET", "/notes"))
    await app.handle(request("GET", "/notes"))

    assertEq(status(await app.handle(request("GET", "/notes"))), 429)

    at = 1000

    assertEq(response(await app.handle(request("GET", "/notes"))).body, "the notes")
    assertEq(response(await app.handle(request("GET", "/notes"))).body, "the notes")
    assertEq(status(await app.handle(request("GET", "/notes"))), 429)

@test
async THE_OLD_WINDOWS_COUNT_IS_NOT_CARRIED_INTO_THE_NEW_ONE()
    // A window is a new counter and not a reset one, which is what naming a bucket for its window
    // buys -- and the control that says the reset above is real rather than an off-by-one.
    var at = 0
    val app = made(() -> at, {})

    await app.handle(request("GET", "/notes"))

    at = 1000

    assertEq(header(await app.handle(request("GET", "/notes")), "X-RateLimit-Remaining"), "1")

@test
async A_KEY_OF_THE_PROGRAMS_OWN_COUNTS_CLIENTS_APART()
    // The option every real deployment uses: an account, an api key, a tenant -- something the
    // program knows and a header does not.
    var at = 0
    val app = api()

    app.get("/notes", rateLimit({ limit: 1, window: 1000, now: () -> at,
        key: (req) -> req.headers["x-account"] ?? "none" }, (req) -> "the notes"))

    val ada = { headers: { "X-Account": "ada" } }
    val bob = { headers: { "X-Account": "bob" } }

    assertEq(status(await app.handle(request("GET", "/notes", ada))), 200)
    assertEq(status(await app.handle(request("GET", "/notes", bob))), 200)
    assertEq(status(await app.handle(request("GET", "/notes", ada))), 429)
    assertEq(status(await app.handle(request("GET", "/notes", bob))), 429)

@test
async THE_DEFAULT_KEY_IS_WHAT_A_PROXY_SAID()
    // **slate:http does not tell a handler who connected**, so what the default can reach is the
    // address a proxy wrote down -- and a server with nothing in front of it counts every direct
    // client under one name, which is said in the README rather than discovered.
    var at = 0
    val app = api()

    app.get("/notes", rateLimit({ limit: 1, window: 1000, now: () -> at }, (req) -> "the notes"))

    val one = { headers: { "X-Forwarded-For": "203.0.113.7, 70.41.3.18" } }
    val two = { headers: { "X-Real-IP": "203.0.113.9" } }

    assertEq(status(await app.handle(request("GET", "/notes", one))), 200)
    assertEq(status(await app.handle(request("GET", "/notes", two))), 200)
    assertEq(status(await app.handle(request("GET", "/notes", one))), 429)

    // Two clients with nothing in front of them are one bucket, which is the cost of the gap.
    assertEq(status(await app.handle(request("GET", "/notes"))), 200)
    assertEq(status(await app.handle(request("GET", "/notes"))), 429)

@test
async THE_GUARD_PRINTS_UNDER_ITS_OWN_NAME()
    var at = 0
    val app = made(() -> at, {})

    assertEq(app.routes()[0].guards, ["rateLimit"])

// -- the store ---------------------------------------------------------------------------------------

@test
async THE_STORES_WHOLE_INTERFACE_IS_A_HIT_ANSWERING_THE_COUNT()
    // **The shape is the one a shared store can implement**: against redis this is `INCR` and an
    // expiry, which is two commands, no read, and no race between two servers.
    var at = 0
    val store = rateStore({ now: () -> at })

    assertEq(store.hit("one@0", 1000), 1)
    assertEq(store.hit("one@0", 1000), 2)
    assertEq(store.hit("two@0", 1000), 1)

@test
async A_STORE_A_PROGRAM_SUPPLIED_IS_THE_ONE_THAT_IS_COUNTED_IN()
    // Which is what says the option is wired through rather than merely accepted.
    var seen = []
    var at = 0

    watched(bucket: string, ttl: integer) -> integer
        push(seen, bucket)

        len(seen)

    val app = made(() -> at, { store: { hit: watched } })

    await app.handle(request("GET", "/notes"))
    await app.handle(request("GET", "/notes"))

    assertEq(seen, ["one@0", "one@0"])

@test
async A_SWEEP_FORGETS_THE_BUCKETS_WHOSE_WINDOWS_HAVE_GONE()
    // **Swept rather than expired on read**, a sweep being a walk of every key: a server holding a
    // thousand clients would otherwise do a thousand comparisons to count one request.
    var at = 0
    val store = rateStore({ now: () -> at, sweep: 3 })

    store.hit("a@0", 1000)
    store.hit("b@0", 1000)

    assertEq(store.size(), 2)

    at = 2000

    store.hit("c@2000", 1000)

    assertEq(store.size(), 1, "the two from the window that has gone were forgotten")

@test
async A_BUCKET_STILL_INSIDE_ITS_WINDOW_SURVIVES_A_SWEEP()
    // The control. Without it the sweep above could be right for having forgotten everything.
    var at = 0
    val store = rateStore({ now: () -> at, sweep: 3 })

    store.hit("a@0", 1000)
    store.hit("b@0", 1000)

    at = 500

    store.hit("c@0", 1000)

    assertEq(store.size(), 3)
