// The guards this package ships.
//
// **A guard is `(handler) -> handler`** and it adds to the request with `with`, never by mutation:
// the request a guard was given is still the value it was, and the one it hands on is a new one
// carrying a field more. That is what makes a stack readable from the outside and a handler
// testable on its own.
//
// **A guard that refuses answers a problem document and does not call what it wraps.** There is no
// `next` to decline to call: not calling the handler *is* the refusal.

import { monotonic } from slate:time

import { problemResponse, asResponse, withHeaders } from "./response.sl"

// A guard as a value: something callable that also says what it is.
//
// **It is an object with a `new` rather than a bare function**, because `api.routes()` has to print
// what a route runs and a slate function knows no name of its own. Calling an object calls its
// `new`, so `body(NewNote)(handler)` is the same thing a plain function would have been.
export guard(label: string, wrap: function) -> object = { new: wrap, label: label }

// The name a guard prints under, for a guard that never said.
export labelOf(g) -> string = if g is object && has(g, "label") then g.label else "guard"

// -- the request body ------------------------------------------------------------------------------

// `body(Shape)` -- parse the body as JSON, check it against `Shape`, and hand it on under `body`.
//
// **The declaration is the validator.** `Shape.mismatch` walks the value collecting every reason it
// does not fit rather than stopping at the first, so a client filling in a form is told about all
// of it at once -- and the shape is a `type` the application already wrote down for its own reading.
//
// **The text stays on `raw`**, which is what a handler needs that wants to hash the body, log it, or
// check a signature over exactly the bytes that arrived.
export bodyGuard(shape: shape) -> object =
    guard("body(" + shape.name() + ")", (h) -> bodied(shape, h))

bodied(shape, h)
    inner(req)
        val raw = if has(req, "body") then req.body else ""
        val parsed = parseJSON(raw)

        // **A body that will not parse is a 400 and not a fault**, which is slate's own division:
        // text from a socket is a condition every server was always going to handle.
        if !parsed.ok
            return problemResponse(400, "Bad Request", "the request body is not JSON",
                { instance: req.path, parse: parsed.error })

        val bad = shape.mismatch(parsed.value)

        if len(bad) != 0
            return problemResponse(400, "Bad Request",
                "the request body does not fit " + shape.name(),
                { instance: req.path, mismatch: bad })

        h(req with { body: parsed.value, raw: raw })

    inner

// -- the query string ------------------------------------------------------------------------------

// `query(Shape)` -- check `req.query` against `Shape`.
//
// **Nothing is replaced here, and that is the difference from `body`.** A query string is already an
// object of strings by the time a handler sees it, so there is nothing to parse -- which also means
// a shape asking for an `integer` will never fit one. Ask for `string` and convert, or take the
// conversion up with the shape you declared.
export queryGuard(shape: shape) -> object =
    guard("query(" + shape.name() + ")", (h) -> queried(shape, h))

queried(shape, h)
    inner(req)
        val q = if has(req, "query") then req.query else {}
        val bad = shape.mismatch(q)

        if len(bad) != 0
            return problemResponse(400, "Bad Request",
                "the query string does not fit " + shape.name(),
                { instance: req.path, mismatch: bad })

        h(req)

    inner

// -- the bearer token ------------------------------------------------------------------------------

// `bearer(verify)` -- take the token out of `Authorization`, hand what `verify` made of it on under
// `user`, and answer `401` otherwise.
//
// **`verify` is the application's**, and it answers a **result** -- `{ ok: true, value: user }` or
// `{ ok: false, error: text }` -- which is the channel `slate:jwt`'s own `verify` uses and for the
// same reason: a bad token is a thing a server says `401` about and carries on. It may answer a
// promise, so a verifier that asks a database is an ordinary one.
//
// **This package holds no opinion about what a token is.** Signing, expiry, audiences and key
// rotation all belong to the application, and a framework that guessed at them would be guessing.
export bearerGuard(verify: function) -> object =
    guard("bearer", (h) -> bearing(verify, h))

bearing(verify, h)
    async inner(req)
        val head = headerOf(req, "authorization")

        if head == null
            return unauthorized(req, "this endpoint needs a bearer token")

        if !startsWith(lower(head), "bearer ")
            return unauthorized(req, "the Authorization header is not a bearer token")

        val token = trim(head[7..<len(head)])

        if token == ""
            return unauthorized(req, "the bearer token is empty")

        val checked = await verify(token)

        // **A verifier that does not answer a result is the program's own mistake**, so it faults
        // rather than becoming a `401` -- a refusal here would turn a defect into every client
        // being told its token was bad.
        if !(checked is object) || !has(checked, "ok")
            throw "a `bearer` verifier answers a result -- { ok: true, value: user } or { ok: false, error: text }"

        if !checked.ok
            return unauthorized(req, if has(checked, "error") then string(checked.error) else "that token was refused")

        await h(req with { user: checked.value })

    inner

// **`WWW-Authenticate` is what makes a 401 a 401.** Without it a client is told it is unauthorised
// and not told what would authorise it, which is the header the status is defined in terms of.
unauthorized(req, detail: string) -> object
    val r = problemResponse(401, "Unauthorized", detail, { instance: req.path })

    r.headers["WWW-Authenticate"] = "Bearer"

    r

// One header by name, whatever case it arrived in. `slate:http` lowercases what it parses; a request
// built by hand in a test need not have.
//
// **Exported for the other guard files and not for a consumer**, which is what `export` means in
// every file here but `sluice.sl`: a name is public because it was declared there, not because it
// was exported from where it was written.
export headerOf(req, name: string) -> string | null
    if !has(req, "headers") then return null

    for [k, v] in entries(req.headers)
        if lower(k) == name then return string(v)

    null

// -- CORS ------------------------------------------------------------------------------------------

// `cors(options)` -- the headers a browser needs before it will let a page read this answer.
//
// | option | |
// |---|---|
// | `origin` | `"*"`, one origin, or an array of them. `"*"` by default |
// | `methods` | what a preflight is told is allowed |
// | `headers` | what a preflight is told may be sent; the request's own list by default |
// | `expose` | what a page may read off the response |
// | `credentials` | whether a cookie may be sent |
// | `maxAge` | how long a preflight may be cached, in seconds |
//
// **A preflight is answered here and the handler never runs.** `OPTIONS` carrying
// `Access-Control-Request-Method` is a question about the endpoint rather than a request of it, and
// a handler asked to answer one would be answering a question it was not written for.
//
// **`Vary: Origin` goes on wherever the answer depends on the origin**, which is every case but
// `"*"`. Without it a cache hands one site's answer to another.
export corsGuard(options: object) -> object =
    guard("cors", (h) -> corsed(options, h))

corsed(options, h)
    async inner(req)
        val heads = corsHeaders(options, req)

        if req.method == "OPTIONS" && headerOf(req, "access-control-request-method") != null
            return { status: 204, headers: preflight(options, req, heads), body: "" }

        withHeaders(await h(req), heads)

    inner

// The headers every CORS answer carries, preflight or not.
corsHeaders(options: object, req) -> object
    val want = if has(options, "origin") then options.origin else "*"
    val from = headerOf(req, "origin")
    var out = {}

    if want == "*"
        out["Access-Control-Allow-Origin"] = "*"
    else
        // **`Vary: Origin` goes on whether or not this origin was allowed.** What a cache must not
        // do is hand one site's answer to another, and it cannot know that unless every answer that
        // consulted the header says so.
        out["Vary"] = "Origin"

        if from != null
            if allows(want, from) then out["Access-Control-Allow-Origin"] = from

    if has(options, "credentials") && options.credentials
        out["Access-Control-Allow-Credentials"] = "true"

    if has(options, "expose")
        out["Access-Control-Expose-Headers"] = listed(options.expose)

    out

// The three a preflight adds to those.
preflight(options: object, req, heads: object) -> object
    var out = {}

    for [k, v] in entries(heads)
        out[k] = v

    val asked = headerOf(req, "access-control-request-headers")

    out["Access-Control-Allow-Methods"] =
        if has(options, "methods") then listed(options.methods)
        else "GET, HEAD, PUT, PATCH, POST, DELETE, OPTIONS"

    if has(options, "headers")
        out["Access-Control-Allow-Headers"] = listed(options.headers)
    elif asked != null
        out["Access-Control-Allow-Headers"] = asked

    if has(options, "maxAge")
        out["Access-Control-Max-Age"] = string(options.maxAge)

    out

// Whether a configured origin covers the one that asked.
allows(want, from: string) -> boolean =
    if want is array then contains(want, from) else want == from

// A header value from either an array or the text somebody already wrote.
listed(v) -> string = if v is array then join(v, ", ") else string(v)

// -- logging -----------------------------------------------------------------------------------------

// `logger(sink)` -- call `sink` with what happened, once the answer is known.
//
// **The sink is given a record and not a line of text**, so a program can print it, count it, or
// send it somewhere structured without this package deciding which. `{ method, path, status, ms }`.
//
// **`id` is on the record wherever the request has one**, which is what `requestId` puts there --
// and it is the member that turns a log into something a person can follow one request through. It
// is absent rather than `null` where nothing set it: a record whose fields depend on which guards
// ran is one a reader can take at face value, and slate will not store an absence anyway.
//
// **A handler that faults is not logged here**, and that is deliberate rather than an oversight: the
// fault carries on up to `handle`, which answers the `500` and puts the fault back. A guard that
// swallowed it to log it would be deciding on the program's behalf that a defect is a log line.
export loggerGuard(sink: function) -> object =
    guard("logger", (h) -> logged(sink, h))

logged(sink, h)
    async inner(req)
        val started = monotonic()
        val reply = await h(req)

        var record = { method: req.method,
                       path: req.path,
                       status: asResponse(reply).status,
                       ms: (monotonic() - started).millis() }

        if has(req, "id") then record["id"] = req.id

        sink(record)

        reply

    inner
