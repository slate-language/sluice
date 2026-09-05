// The api object: the route table, the composition, and the one function that answers a request.

import { segments, fit } from "./route.sl"
import { problemResponse } from "./response.sl"
import { labelOf } from "./guards.sl"
import { healthHandler } from "./operations.sl"
import { drainServer } from "./lifecycle.sl"

// `stack([a, b])` -- the guards composed once, here, rather than a list walked per request.
//
// **`stack([a, b])(h)` is `a(b(h))`**: the first in the list is the outermost, so the list reads in
// the order a request passes through it.
//
// **A stack remembers the list it was built from**, which is the one thing an interceptor chain buys
// over plain composition -- what a route runs can be printed. It costs a field, and `api.routes()`
// is what spends it.
export stack(guards: array) -> object
    var labels = []

    for g in guards
        push(labels, labelOf(g))

    // **A named function, not a lambda**: a lambda's one-line body is an expression and this one
    // has statements in it.
    wrap(h)
        // **A stack applied to something already wrapped takes its guards on**, so a route's list
        // is what a request actually passes through however it was spelled.
        //
        // **The guards themselves are kept beside their names**, which is what lets `api.add` put
        // the failure mapping under them rather than over them -- see `mapped`.
        val inner = if h is object && has(h, "guards") then h.guards else []
        val under = if h is object && has(h, "wrappers") then h.wrappers else []
        val deepest = if h is object && has(h, "handler") then h.handler else h

        { new: lazy(guards, h),
          guards: concat(labels, inner),
          wrappers: concat(guards, under),
          handler: deepest }

    { new: wrap, guards: labels, wrappers: guards }

// The guards composed: `compose([a, b], h)` is `a(b(h))`.
export compose(guards: array, h)
    var composed = h
    var i = len(guards) - 1

    while i >= 0
        val g = guards[i]

        composed = g(composed)
        i = i - 1

    composed

// The same composition, put off until something actually calls it and done once.
//
// **A stack applied to a handler is a working handler in its own right** -- `serve(port,
// stack([…])(h))` is an ordinary thing to write -- but an `api` composes the list again around the
// failure mapping, and a guard whose construction costs anything should not pay for both. So the
// eager composition here would be work nobody asked for, and this is the version that is not done
// until it is wanted.
export lazy(guards: array, h) -> function
    var ready = null

    run(req)
        if ready == null then ready = compose(guards, h)

        ready(req)

    run

// `api()` -- a router that composes, refuses in RFC 9457, and answers a value.
//
// **It is an ordinary object with a `handle`**, which is the whole of what `slate:http` asks of a
// server: `serve(port, api)` works and nothing in `slate:http` had to learn what this package is.
//
// | option | |
// |---|---|
// | `onFault` | given a fault a handler raised, instead of it being put back on the loop |
//
// **A handler that faults answers `500` and the fault is put back afterwards**, which is what
// `slate:http` does for its own handlers: the client is told, and the defect still stops the
// program rather than being swallowed into a log nobody reads. `onFault` is how a test watches that
// happen without ending the run, and how a program that has somewhere to send a defect says so.
export makeApi(options: object) -> object
    var routes = []
    var fallback = null
    var failureShape = null
    var failureMap = null

    // **How many requests are in this api right now, and whether it is still taking them.** Both are
    // here rather than in a guard because `handle` is the one function every request goes through --
    // including the ones no route matched, which a guard would never see and which are exactly the
    // ones a client retries during a shutdown.
    var inFlight = 0
    var stopping = false

    val onFault = if has(options, "onFault") then options.onFault else null

    add(method: string, path: string, h)
        push(routes, { method: method,
                       path: path,
                       parts: segments(path),
                       run: composed(h),
                       guards: labelsOf(h),
                       handler: deepestOf(h) })

    // A route's handler, with the failure mapping applied AT EVERY LEVEL of the composition:
    // around the handler, and again around each guard.
    //
    // **This is the one thing about the order that is not obvious, and it is load-bearing.** A
    // failure is what a handler answered; every guard above it must see the HTTP response, not the
    // failure value -- a `logger` over an unmapped failure would report `200` for what went out as
    // `409`, and a `cors` over one would wrap the failure in an envelope, which would stop it being
    // recognisable as a failure at all and send it out as a `200`. That is why the innermost
    // mapping is under the guards and not over them.
    //
    // **But a GUARD may return a failure too**, and one mapping under all of them never sees it: a
    // `guardOf` of the application's own answering `NotSignedIn` met nothing that would translate
    // it and went out as a `200` carrying a rendered data value -- an empty object, for a variant
    // with no fields -- and nothing warned. So there is a mapping between every pair of guards as
    // well, which is the only arrangement that keeps both halves: whatever answered a failure, the
    // thing directly above it sees the HTTP response that failure became, whether that thing is a
    // guard or the server.
    //
    // **One mapping OVER the whole stack would not do it**, and that is worth saying because it is
    // the obvious repair: the outermost mapping would translate an inner guard's failure only after
    // every guard above that one had already read it as a data value, so a `logger` over a
    // refusing guard would report `200` for what the client received as `403`.
    //
    // **Applying it twice to one answer costs nothing**: a mapping only fires for a value
    // `failureShape.test` says is a failure, and what the mapping answers is a response. So a
    // handler's failure is translated once, at the innermost application, and passes through the
    // rest untouched. What it costs is one call per guard on the way out, on a path that already
    // awaits every one of them.
    //
    // **The guards are composed here, once, when the route is added.** They were composed once
    // already by `stack`, whose answer is a working handler in its own right; this puts the same
    // list back together around a different innermost function, and nothing is worked out per
    // request either way.
    composed(h)
        if !(h is function) && !(h is object && has(h, "new"))
            throw "a route needs a function to call, and this is not one"

        val wrappers = if h is object && has(h, "wrappers") then h.wrappers else []
        var out = mapped(deepestOf(h))
        var i = len(wrappers) - 1

        while i >= 0
            out = mapped(wrappers[i](out))
            i = i - 1

        out

    // The handler with the application's failure mapping around it.
    //
    // **`failureShape` is read when the request arrives and not when the route was added**, so
    // `failures` may be called after the routes are, which is how most programs will read.
    mapped(h)
        async inner(req)
            val reply = await h(req)

            if failureShape == null then return reply

            if !failureShape.test(reply) then return reply

            await failureMap(reply)

        inner

    labelsOf(h) -> array = if h is object && has(h, "guards") then h.guards else []

    deepestOf(h) = if h is object && has(h, "handler") then h.handler else h

    // **A named function and not a lambda**, for the same reason `stack`'s is: an assignment is a
    // statement.
    setFallback(h)
        fallback = composed(h)

    // `failures(Shape, fn)` -- the failure values this application's handlers may return, and what
    // each one is as HTTP.
    //
    // **The shape is taken as a VALUE so that `handle` can tell a failure from a response.** A
    // `Response` pattern is all-optional and would match any object, so the test has to run the
    // other way round: is this reply one of the things the application declared it could fail with?
    //
    // **`fn` annotated `(f: Failure) -> …` is what makes the check worth having.** A `match` over an
    // annotated subject must cover every variant, so a failure the application can produce and has
    // no HTTP answer for is refused before the program runs.
    setFailures(shape: shape, fn: function)
        failureShape = shape
        failureMap = fn

    // Which route takes this request, and what a path that is there under another method allows.
    pick(method: string, want: array of string) -> object
        var allowed = []
        var i = 0

        while i < len(routes)
            val r = routes[i]
            val bound = fit(r.parts, want)

            if bound != null
                // **`any` is the empty method** and matches whatever arrived, so it never
                // contributes to `Allow`.
                if r.method == "" || r.method == method
                    return { route: r, params: bound, allowed: allowed }

                if !contains(allowed, r.method) then push(allowed, r.method)

            i = i + 1

        { route: null, params: {}, allowed: allowed }

    // Everything a handler is entitled to read, whether or not a server filled it in.
    //
    // **The answer is a new request and the one given is untouched**, which is what lets a suite
    // hand the same request to two apis and get two answers rather than one and a surprise.
    prepare(req: object) -> object
        var r = req

        if !has(r, "headers") then r = r with { headers: {} }
        if !has(r, "query") then r = r with { query: {} }
        if !has(r, "cookies") then r = r with { cookies: {} }
        if !has(r, "search") then r = r with { search: "" }

        r

    // Run one handler and make an answer of whatever it did.
    async settled(req: object, run)
        var reply = null

        // **The failure mapping is inside `run`**, under the guards, so a mapping that faults is a
        // defect in the application exactly as a handler that faults is and gets the same `500`
        // rather than escaping into the server.
        try
            reply = await run(req)
        catch e
            return faulted(req, e)

        reply

    // A defect: the client is told, and the fault is put back.
    faulted(req: object, e) -> object
        if onFault != null
            onFault(e)
        else
            // **A timer, because there is no statement of this request left to throw from.** The
            // response has to be answered before the fault can be put back, so it goes back on the
            // loop -- where nothing awaits it and it stops the program, which is what a defect
            // should do and what `slate:http` already does for a handler of its own.
            setTimeout(() -> rethrow(e), 0)

        problemResponse(500, "Internal Server Error", "this request was not answered",
            { instance: req.path })

    // **Every request is counted in and counted out here**, which is what a shutdown reads to know
    // whether anybody is still being answered. It is two additions on a path that already awaits a
    // handler, and it is the only place in a program that can see the number at all -- `slate:http`
    // knows about connections and not about requests, and a keep-alive connection with nothing on it
    // is not work.
    //
    // **The decrement is written twice because slate has no `finally`.** A handler that faults still
    // has to be counted out, or a single defect would leave a shutdown waiting out its whole grace
    // for a request that ended minutes ago.
    async handle(req: object)
        if stopping then return unavailable(req)

        inFlight = inFlight + 1

        try
            val reply = await answered(req)

            inFlight = inFlight - 1

            return reply
        catch e
            inFlight = inFlight - 1

            rethrow(e)

    // A request that arrived after the server was asked to stop.
    //
    // **503 is the load balancer's cue to send the next one elsewhere**, which is the whole reason a
    // draining server answers at all rather than closing the connection: a client that is told is a
    // client that retries somewhere useful, and one that is cut off retries here.
    unavailable(req: object) -> object =
        problemResponse(503, "Service Unavailable", "this server is shutting down",
            { instance: req.path })

    async answered(req: object)
        val ready = prepare(req)
        val found = pick(ready.method, segments(ready.path))

        if found.route == null
            // **A path that is there under another method is `405` and not `404`**, and the
            // difference is what tells a client to change what it sent rather than give up.
            if len(found.allowed) != 0 then return refused(ready, found.allowed)

            if fallback != null then return await settled(ready, fallback)

            return problemResponse(404, "Not Found",
                "there is nothing at " + ready.path, { instance: ready.path })

        await settled(ready with { params: found.params }, found.route.run)

    refused(req: object, allowed: array) -> object
        val r = problemResponse(405, "Method Not Allowed",
            req.method + " is not a method this path takes", { instance: req.path })

        r.headers["Allow"] = join(sorted(allowed), ", ")

        r

    // What every route runs, in the order the routes were added.
    listing() -> array =
        map(routes, described)

    // `health(path, check)` -- the route a load balancer, a container runtime and a person with
    // `curl` all ask the same question through.
    //
    // **It is a route convention and not a guard**, which is what it has to be: the thing asking is
    // not a client of this API, has no token, and is not to be logged with the traffic or counted
    // against a rate limit. So it is added on its own, under no stack, and a program that wants one
    // wraps `health` itself.
    //
    // **A draining server fails its own health check**, which falls out of the counting above rather
    // than being arranged: `handle` refuses everything once a drain has started, and this is one of
    // the things it refuses. That is the order a rolling deployment needs -- stop being sent traffic,
    // then finish what you have.
    addHealth(path: string = "/health", check = null)
        add("GET", path, healthHandler(check))

    countInFlight() -> integer = inFlight

    isDraining() -> boolean = stopping

    // Stop taking requests. **Separate from `drain` so that a program with two servers on one api
    // can stop them together**, and so that what `drain` does first has a name.
    startDraining()
        stopping = true

        null

    // `drain(server, options)` -- stop taking requests, let what is in hand finish, then close.
    //
    // **The api fills in the two things only it knows**: how many requests are running, and how to
    // stop taking new ones. Everything else -- the grace, what closing means -- is the caller's, and
    // `drain` on its own is exported for a program serving something other than an api.
    drain(server, options: object = {}) =
        drainServer(server, options with { inflight: countInFlight, stop: startDraining })

    { get: (p, h) -> add("GET", p, h),
      post: (p, h) -> add("POST", p, h),
      put: (p, h) -> add("PUT", p, h),
      patch: (p, h) -> add("PATCH", p, h),
      delete: (p, h) -> add("DELETE", p, h),
      head: (p, h) -> add("HEAD", p, h),
      options: (p, h) -> add("OPTIONS", p, h),
      any: (p, h) -> add("", p, h),
      health: addHealth,
      notFound: setFallback,
      failures: setFailures,
      routes: listing,
      inflight: countInFlight,
      draining: isDraining,
      stop: startDraining,
      drain: drain,
      handle: handle }

// One row of `api.routes()`. **`handler` is the function itself** rather than a name, slate
// functions having none -- what is printable is the method, the path and the guards.
described(r) -> object =
    { method: if r.method == "" then "ANY" else r.method,
      path: r.path,
      guards: r.guards,
      handler: r.handler }

// **A named function because `throw` is a statement**, so a lambda cannot be one.
rethrow(e)
    throw e
