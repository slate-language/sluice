// The api object: the route table, the composition, and the one function that answers a request.

import { segments, fit } from "./route.sl"
import { problemResponse } from "./response.sl"
import { labelOf } from "./guards.sl"

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

    val onFault = if has(options, "onFault") then options.onFault else null

    add(method: string, path: string, h)
        push(routes, { method: method,
                       path: path,
                       parts: segments(path),
                       run: composed(h),
                       guards: labelsOf(h),
                       handler: deepestOf(h) })

    // A route's handler, with the failure mapping put UNDER its guards rather than over them.
    //
    // **This is the one thing about the order that is not obvious, and it is load-bearing.** A
    // failure is what the handler answered; every guard above it must see the HTTP response, not
    // the failure value -- a `logger` over an unmapped failure would report `200` for what went out
    // as `409`, and a `cors` over one would wrap the failure in an envelope, which would stop it
    // being recognisable as a failure at all and send it out as a `200`.
    //
    // **The guards are composed here, once, when the route is added.** They were composed once
    // already by `stack`, whose answer is a working handler in its own right; this puts the same
    // list back together around a different innermost function, and nothing is worked out per
    // request either way.
    composed(h)
        if !(h is function) && !(h is object && has(h, "new"))
            throw "a route needs a function to call, and this is not one"

        val wrappers = if h is object && has(h, "wrappers") then h.wrappers else []

        compose(wrappers, mapped(deepestOf(h)))

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

    async handle(req: object)
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

    { get: (p, h) -> add("GET", p, h),
      post: (p, h) -> add("POST", p, h),
      put: (p, h) -> add("PUT", p, h),
      patch: (p, h) -> add("PATCH", p, h),
      delete: (p, h) -> add("DELETE", p, h),
      head: (p, h) -> add("HEAD", p, h),
      options: (p, h) -> add("OPTIONS", p, h),
      any: (p, h) -> add("", p, h),
      notFound: setFallback,
      failures: setFailures,
      routes: listing,
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
