// The guards a server needs to stay up, as against the ones an endpoint needs to be correct.
//
// **What is here is about the SERVER and what is in `guards.sl` is about the REQUEST.** `body` and
// `bearer` decide whether one request is acceptable; a request id, a deadline and a rate limit are
// about a server answering thousands of them -- being able to follow one through a log, refusing to
// wait for a handler that will not finish, and refusing to be the only thing a client is doing.
//
// **Every one of these has a seam where it would otherwise touch the host**: the clock a limiter
// reads, the randomness an id is made of, the function a shutdown calls to close a socket. That is
// what lets this package's suite bind no port and start no real clock, and it is the same reason
// `bearer` takes the application's verifier rather than knowing what a token is.

import { monotonic } from slate:time
import { randomBytes } from slate:crypto
import { base64urlEncode } from slate:url

import { guard, headerOf } from "./guards.sl"
import { problemResponse, jsonResponse, withHeaders } from "./response.sl"

// -- the request id --------------------------------------------------------------------------------

// `requestId(options)` -- one name for this request, on the request and on the answer.
//
// **A request id is what makes a log searchable rather than merely long.** A client that reports a
// failure quotes the id it was given, and every line the request produced carries it -- which is why
// this guard writes `req.id`, echoes the header, and why `logger` puts `id` in its record wherever a
// request has one.
//
// **An id a client sent is taken rather than replaced**, which is what makes it a TRACE id: a
// gateway, a load balancer or a caller further up has already named this request, and a server that
// renamed it would break the one join a person is trying to make.
//
// **What arrives from a client is checked before it is echoed, and that is not fussiness.** The value
// goes back out in a response header, so text carrying a carriage return would be a client writing
// headers of its own -- and an id of unbounded length is a log line of unbounded length. Anything
// that fails the check is replaced by a generated id rather than refused: this is not an
// authentication and a client with a strange id still deserves an answer.
//
// | option | |
// |---|---|
// | `header` | the name, read without case and echoed as written. `"X-Request-Id"` |
// | `generate` | a function answering a new id. 16 random bytes in base64url by default |
export requestIdGuard(options: object) -> object =
    guard("requestId", (h) -> identified(options, h))

identified(options, h)
    val name = options.header ?? "X-Request-Id"
    val wanted = name.lower()
    val generate = options.generate ?? newId

    async inner(req)
        val given = headerOf(req, wanted)
        val id = if given != null && usable(given) then given else generate()
        var echo = {}

        echo[name] = id

        withHeaders(await h(req with { id: id }), echo)

    inner

// The characters an id may be made of, and the length one may be.
//
// **The set is the one a trace header actually carries** -- hex, a UUID's dashes, a base64url token,
// a `traceparent`'s dots and colons -- and it excludes every character that means something to a
// header line: a space, a comma, a carriage return, a line feed.
val IdCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=:@"

val IdLimit = 200

usable(id: string) -> boolean
    if len(id) == 0 || len(id) > IdLimit then return false

    var i = 0

    while i < len(id)
        if indexOf(IdCharacters, id[i..<(i + 1)]) == null then return false

        i = i + 1

    true

// A new id: 16 bytes from the operating system, in base64url.
//
// **Random rather than counted**, because a counter is one server's and an id has to be unique across
// however many of them are behind the load balancer -- and because a sequential id tells whoever
// holds one how much traffic the service took.
//
// **base64url and not hex**, which is `slate:url`'s from slate 0.0.29: the same 128 bits in 22
// characters rather than 32, on a value that is written into a header on every response and into
// every log line the request produces. The alphabet is a subset of `IdCharacters` above, so an id
// this generated is one this would accept from a client.
newId() -> string = base64urlEncode(randomBytes(16))

// -- the deadline ----------------------------------------------------------------------------------

// `timeout(ms, options)` -- answer without the handler where the handler is taking too long.
//
// **503 AND NOT 504, AND RFC 9110 IS WHY.** 504 is defined for a server "acting as a gateway or
// proxy" that "did not receive a timely response from an upstream server" (RFC 9110 s15.6.5); the
// handler this wraps is not an upstream server, it is this server. What the origin has to say is
// that it is "currently unable to handle the request" (s15.6.4), which is 503 -- and 503 is the
// status the specification lets carry a `Retry-After`. **`status` is the option for the case where
// the handler really is a proxy**, and a program calling out to something else says so itself.
//
// **A late answer is DROPPED rather than sent**, which is the half that is easy to leave out: the
// response has gone, so a handler that finishes afterwards is writing into a socket that is already
// answered. Nothing here can stop the handler running -- slate has no way to cancel a promise, and
// what a handler is doing may be a database write that is going to happen whatever this guard
// thinks -- so the honest statement is that the ANSWER is dropped and the work is not.
//
// **`onLate` is what keeps that from being a silence.** A handler that regularly finishes after its
// deadline is a service in trouble, and this package counts drops rather than swallowing them
// wherever it drops anything -- the event hub's bound does the same.
//
// **IT IS GIVEN A RESULT AND NOT AN ANSWER, BECAUSE A HANDLER THAT FAULTS LATE IS THE CASE THAT
// WOULD OTHERWISE VANISH.** The request has been answered, so there is nothing left to raise the
// fault from -- `handle`'s `500` and its `onFault` both belong to a response that has gone. Putting
// it back on the loop instead would stop the server over a defect the timeout itself probably
// caused. So it comes here, as `{ ok: false, error: fault }` beside the `{ ok: true, value: answer }`
// of one that merely finished late, which is the same result channel `bearer`'s verifier answers in.
//
// | option | |
// |---|---|
// | `status` | `503`, or `504` where the handler is really calling something upstream |
// | `onLate` | given `{ ok, value }` or `{ ok, error }` for work that finished after the deadline |
export timeoutGuard(ms: integer, options: object) -> object =
    guard("timeout(" + string(ms) + "ms)", (h) -> bounded(ms, options, h))

bounded(ms, options, h)
    val status = options.status ?? 503
    val onLate = options.onLate ?? null

    async inner(req)
        // **One cell both sides write to**, the timer and the handler being two things racing to
        // answer one request. `done` is what makes the loser silent.
        val cell = { gate: pending(), done: false, timer: null }

        cell.timer = setTimeout(() -> expired(cell, req, status, ms), ms)

        // **Not awaited, and deliberately not given to anybody.** What this function awaits is the
        // gate, so that the timer can answer it instead; `running` catches everything a handler can
        // do, so this call has no failure of its own for nobody-awaited-it to report.
        running(h, req, cell, onLate)

        val outcome = await cell.gate

        if outcome.ok then return outcome.value

        // **A fault the handler raised is raised again here**, so that a handler which faults inside
        // its deadline is the ordinary 500 `handle` already makes of one rather than something this
        // guard invented.
        raise(outcome.value)

    inner

// The handler, run to whatever end it comes to, with the answer put through the gate.
//
// **It catches everything on purpose.** A fault carried to the gate is raised again on the other
// side, where the request still has a statement to raise it from; a fault let out of here would have
// nowhere to go, this call being awaited by nothing.
async running(h, req, cell, onLate)
    var answer = null
    var ok = true

    try
        answer = await h(req)
    catch e
        ok = false
        answer = e

    if cell.done
        if onLate != null
            onLate(if ok then { ok: true, value: answer } else { ok: false, error: answer })

        return null

    cell.done = true

    clearTimeout(cell.timer)
    settle(cell.gate, { ok: ok, value: answer })

    null

// The deadline, reached.
expired(cell, req, status: integer, ms: integer)
    if cell.done then return null

    cell.done = true

    settle(cell.gate, { ok: true, value: problemResponse(status, titleOf(status),
        "this request took longer than " + string(ms) + "ms to answer",
        { instance: req.path }) })

    null

titleOf(status: integer) -> string =
    if status == 504 then "Gateway Timeout" else "Service Unavailable"

// **A named function because `throw` is a statement**, which is `api.sl`'s `rethrow` for the same
// reason: a lambda's one-line body is an expression.
raise(e)
    throw e

// -- the rate limit --------------------------------------------------------------------------------

// `rateLimit(options)` -- a fixed window per key, and `429` with a `Retry-After` over it.
//
// **A FIXED WINDOW AND NOT A TOKEN BUCKET, AND THE REASON IS THE STORE.** A bucket has to read a
// count and a timestamp, work out a refill, and write both back -- which is a read-modify-write, and
// two servers sharing one store race on it unless the store can run a script. A fixed window is
// `INCR` and an expiry: two commands with no read, atomic in anything that has a counter, and the
// same three lines against redis as against the object below.
//
// **What that costs is a burst at the boundary**, and it is written down rather than discovered: a
// client may spend its whole allowance at the end of one window and the whole of the next at the
// start of the following one, so a limit of 60 a minute permits 120 across two seconds once. Where
// that matters the answer is a shorter window, and 60 in 10 seconds is a limit this takes.
//
// **`Retry-After` is exact rather than guessed**, being the time left in the window the client just
// filled -- which is the one number a well-behaved client wants and the reason a fixed window is
// pleasant to be on the wrong side of.
//
// **THE KEY IS WHO CONNECTED, AND A HEADER IS NOT AN IDENTITY UNTIL SOMETHING OVERWRITES IT.**
// `req.address` is the peer of this request's socket, which is slate 0.0.30's and is the one thing
// about a client the client cannot choose. `x-forwarded-for` and `x-real-ip` are text anybody may
// write, so a server exposed directly that read them would be a rate limit with a bypass header --
// one line in `curl` and every request is a new client. They are therefore read only where
// `trustProxy` says a proxy in front of this server writes them, and there they are read FIRST,
// because there the address is the proxy's and every client shares it.
//
// | option | |
// |---|---|
// | `limit` | how many requests one key may make in a window. `60` |
// | `window` | how long a window is, in milliseconds. `60000` |
// | `key` | a function of the request answering the name to count under |
// | `trustProxy` | whether `x-forwarded-for` names the client. `false` |
// | `now` | a function answering milliseconds; the monotonic clock by default |
// | `store` | where counts are kept. `rateStore()` |
export rateLimitGuard(options: object) -> object =
    guard("rateLimit", (h) -> limited(options, h))

limited(options, h)
    val limit = options.limit ?? 60
    val window = options.window ?? 60000
    val proxied = options.trustProxy ?? false
    val key = options.key ?? ((req) -> clientKey(req, proxied))
    val clock = options.now ?? elapsed
    val store = options.store ?? rateStore({ now: clock })

    async inner(req)
        val at = clock()
        val opened = at - (at % window)
        val closes = opened + window
        val left = closes - at
        val count = store.hit(string(key(req)) + "@" + string(opened), left)
        var heads = {}

        // **The three `X-RateLimit-` headers are a convention and not a standard**, which is why they
        // are spelled with the `X-` every implementation of them uses rather than in the shape of the
        // draft that may one day replace them. A client that cannot see its own allowance can only
        // find the edge by falling off it.
        //
        // **`Reset` IS SECONDS FROM NOW AND NOT A TIMESTAMP**, which is where the convention
        // disagrees with itself -- GitHub sends an epoch second and the IETF draft sends a delta.
        // The delta is the one this can send: the clock a window is measured against is MONOTONIC,
        // and it names no point in time to convert. It is also the one that survives a client whose
        // clock is wrong.
        heads["X-RateLimit-Limit"] = string(limit)
        heads["X-RateLimit-Remaining"] = string(max(0, limit - count))
        heads["X-RateLimit-Reset"] = string(seconds(left))

        if count > limit
            val r = problemResponse(429, "Too Many Requests",
                "this client has made " + string(limit) + " requests in the time this endpoint allows them",
                { instance: req.path })

            r.headers["Retry-After"] = string(seconds(left))

            return withHeaders(r, heads)

        withHeaders(await h(req), heads)

    inner

// The key a request is counted under when the program did not say.
//
// **`req.address` IS THE DEFAULT AND A HEADER IS NOT**, which is the whole of this function's
// argument. The address is the peer of the socket this request came in on -- slate 0.0.30 puts it on
// the request, and `slate:http` normalises it, so an IPv4 client of a dual-stack server reads as
// `127.0.0.1` and not as `::ffff:127.0.0.1` and two spellings of one client are not two buckets.
// **It is the one fact about a client the client did not choose.**
//
// **`x-forwarded-for` IS A CLIENT'S TEXT UNTIL A PROXY OVERWRITES IT.** Trusting it by default would
// make every limiter here bypassable with a header, which is a limiter that stops only the clients
// that were not trying -- so it is read only under `trustProxy`, where the operator has said
// something in front of this server sets it. There it is read FIRST and the address second: behind a
// proxy the address is the proxy's, and every client in the world shares it.
//
// **The LEFTMOST entry is the client**, a proxy appending the peer it saw to whatever it was given.
// That is also why the header is worth nothing untrusted: the left of the list is exactly the part
// the client wrote.
//
// **`"unknown"` is what is left where there is no address and no trusted header**, and it is one
// bucket for everybody -- a global limit rather than a per-client one. A server whose clients are
// accounts or api keys wants its own `key`, which is the option every real deployment uses.
//
// **A header that is there and EMPTY is a header that is not there**, which is not fussiness: a proxy
// that writes the name and nothing after it would otherwise put every client it forwards into one
// bucket named by the empty string, and that bucket would be the whole internet.
clientKey(req, trustProxy: boolean) -> string
    if trustProxy
        val forwarded = leftmost(headerOf(req, "x-forwarded-for"))

        if forwarded != null then return forwarded

        val real = leftmost(headerOf(req, "x-real-ip"))

        if real != null then return real

    if has(req, "address") && req.address != null then return string(req.address)

    "unknown"

// The leftmost entry of a comma-separated header that has anything in it, or `null`.
leftmost(value) -> string | null
    if value == null then return null

    for one in split(value, ",")
        if trim(one) != "" then return trim(one)

    null

// Milliseconds as whole seconds, rounded up, and never less than one. **A `Retry-After: 0` is a
// client told to try again immediately**, which is the one answer a limiter must not give.
seconds(ms: integer) -> integer = max(1, (ms + 999) / 1000)

// The monotonic clock in milliseconds. **Monotonic and not the wall clock**: a window measured
// against a clock that can be set backwards is a window that can be reopened by an operator running
// `ntpdate`.
elapsed() -> integer = monotonic().millis()

// `rateStore()` -- counts in this process, which is what one server needs and no more.
//
// **THE SHAPE IS THE ONE A SHARED STORE CAN IMPLEMENT, AND THAT IS THE WHOLE POINT OF NAMING IT.**
// `hit(bucket, ttl)` counts one request and answers what the count is now; against redis it is
// `INCR bucket` and `PEXPIRE bucket ttl`, which is two commands, no read, and no race between
// servers. Anything richer here -- a count and a timestamp read back and written -- would be a shape
// only this object could implement.
//
// **A bucket carries the window it belongs to in its name**, so a new window is a new counter and an
// old one is never reset, only forgotten.
//
// | option | |
// |---|---|
// | `now` | a function answering milliseconds |
// | `sweep` | how many hits between sweeps of what has expired. `1000` |
export rateStore(options: object = {}) -> object
    val clock = options.now ?? elapsed
    val sweep = options.sweep ?? 1000
    var held = {}
    var since = 0

    // Count one request against a bucket, and say what the count is now.
    hit(bucket: string, ttl: integer) -> integer
        val at = clock()

        since = since + 1

        // **Swept every so often rather than on every hit**, a sweep being a walk of every key: a
        // server holding a thousand clients would otherwise do a thousand comparisons to count one
        // request. Nothing is lost by being late -- an expired bucket is never read, its window
        // having gone.
        if since >= sweep
            since = 0
            held = kept(held, at)

        val slot = held[bucket] ?? null

        if slot == null
            held[bucket] = { count: 1, ends: at + ttl }

            return 1

        slot.count = slot.count + 1

        slot.count

    // How many keys are being held, which is what says a sweep happened.
    size() -> integer = len(keys(held))

    { hit: hit, size: size }

// Everything not yet expired. **A SWEEP REBUILDS RATHER THAN CALLING `without` PER KEY**, and that is
// a choice about bulk and not about the language any more -- slate 0.0.30 can take a key out of an
// object, and doing it for each of a thousand expired buckets would be a thousand copies of the table
// where one walk answers it.
kept(held: object, at: integer) -> object
    var out = {}

    for [k, v] in entries(held)
        if v.ends > at then out[k] = v

    out

// -- health ----------------------------------------------------------------------------------------

// The handler behind `api.health(path, check)`.
//
// **`{ "status": "ok" }` and not an empty 200**, because the thing reading this is usually a load
// balancer with a body matcher and a person with `curl`, and neither is served by a blank page.
//
// **A CHECK ANSWERS THE REASONS IT IS NOT WELL, AND AN EMPTY ANSWER MEANS IT IS.** A boolean would
// make a failing health check a page nobody can act on -- the operator is looking at this because
// something is wrong and wants to be told which of the four things it is. `null` and `[]` are both
// "nothing to report", one string is one reason, and an array is as many as there are.
//
// **It is asked nothing about the request**, taking no arguments: a health check is about the
// service, and one that read the request would be an endpoint rather than a check.
//
// **The refusal is a problem document like every other refusal here**, so a client that already
// knows how to read this server's failures needs nothing new for this one.
export healthHandler(check) -> function
    async inner(req)
        if check == null then return jsonResponse({ status: "ok" }, 200)

        val reasons = asReasons(await check())

        if len(reasons) == 0 then return jsonResponse({ status: "ok" }, 200)

        problemResponse(503, "Service Unavailable", "this service is not well",
            { instance: req.path, reasons: reasons })

    inner

// What a check said, as the list of reasons it is.
asReasons(said) -> array
    if said == null then return []
    if said is string then return [said]
    if said is array then return said

    throw "a `health` check answers the reasons it is unwell -- a string, an array of them, or null"
