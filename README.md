# sluice — an API server for slate

**A request is a value, a handler is a function of it, and everything else is composition.** No
`next`, no mutable response, no ambient context, no `app.use()`.

```
slate add github.com/slate-language/sluice
```

```slate
import { api, stack, body, bearer, logger, problem, json } from sluice
import { serve } from slate:http

type NewNote = { title: string, text: string, pinned?: boolean }

data Failure
    NoSuchNote(id)
    Taken(title)

val app = api()

app.failures(Failure, (f: Failure) -> f match
    NoSuchNote(id) -> problem(404, "Not Found", "there is no note " + id)
    Taken(title) -> problem(409, "Conflict", "that title is taken", { taken: title }))

app.get("/notes/:id", (req) -> find(req.params.id))
app.post("/notes", stack([logger(print), bearer(check), body(NewNote)])(create))

serve(8080, app)
```

**`api()` is an object with a `handle`, so `serve(port, app)` works unchanged.** `slate:http` asks a
server object for its `handle` and calls that; nothing in the server had to learn what this package
is, and everything it already does — keep-alive, compression, TLS, `serveStream` — is untouched.

## The five decisions

1. **A guard wraps a handler**, and `stack([a, b])(h)` is `a(b(h))`, composed once when the route is
   added rather than walked per request. A stack keeps the list it was built from, so
   `api.routes()` can print what each route actually runs — the one thing an interceptor chain buys
   over plain composition, and it costs a field.
2. **A guard adds to the request with `with`, never by mutation.** `bearer` hands on
   `req with { user }`; `body(Shape, h)` replaces `req.body` with the parsed value and keeps the
   text on `req.raw`. The request you handed to `handle` is still the value it was.
3. **A failure is a value a handler RETURNS** — or a guard. `api.failures(Shape, fn)` registers the
   shape and the mapping, and because `fn` is annotated `(f: Failure) -> …`, slate's exhaustiveness
   rule proves before the program runs that every failure the application can produce has an HTTP
   answer. Nothing in express or axum can check that.
4. **RFC 9457 problem details by default** — `application/problem+json` with `type`, `title`,
   `status`, `detail` and `instance`. 404, 405, 400, 401 and 500 all go out as problem documents.
5. **`await api.handle(request)` answers a response with no socket in it.** Every test of this
   package but one is written that way: no port, no client, no watchdog, and nothing that can flake
   under load. The exception is a browser that hangs up mid-stream, which is the one thing a handler
   driven directly cannot show.

## Testing a handler without a port

```slate
import { api, request, response } from sluice

@test
async A_MISSING_NOTE_IS_A_404()
    val app = api()

    app.get("/notes/:id", (req) -> { status: 404 })

    assertEq(response(await app.handle(request("GET", "/notes/9"))).status, 404)
```

`request(method, path, options)` builds what a server would have delivered — `headers` lowercased,
`query` rendered into `search`, a non-string `body` encoded as JSON — and the value it answers `is`
`slate:http`'s own `Request`.

**`body` and `bytes` fill each other in, because `serve` puts both on a request**, and `address`
defaults to `"127.0.0.1"` as a loopback client reads. A test that means to send something that is not
text writes `bytes` and gets the empty `body` the server would have made of it:

```slate
request("POST", "/avatars", { headers: sending(boundary), bytes: png })
request("GET", "/notes", { address: "203.0.113.7" })
```

## The guards

| | |
|---|---|
| `body(Shape, handler)` | parses JSON, checks it against `Shape`, hands it on under `body` with the text on `raw`; a `400` problem carrying every mismatch otherwise |
| `query(Shape, handler)` | the same check over `req.query`, which is already an object of strings |
| `bearer(verify, handler)` | the token out of `Authorization`, `req with { user }`; a `401` problem with `WWW-Authenticate` otherwise |
| `cors(options, handler)` | the headers a browser needs, and a preflight answered without the handler running |
| `logger(sink, handler, options)` | `sink({ method, path, status, ms, address })` once the answer is known |
| `session(secret, options, handler)` | a signed cookie carrying the session itself — or, with a `store`, a signed id into one — on `req.session` |
| `csrf(options, handler)` | the double-submit token, and a `403` problem without it |
| `requestId(options, handler)` | one name for this request, on `req.id` and on the answer |
| `timeout(ms, options, handler)` | a `503` problem where the handler is taking too long |
| `rateLimit(options, handler)` | a fixed window per key, and `429` with a `Retry-After` over it |
| `multipart(options, handler)` | a `multipart/form-data` body as `req.form` |

`hub(options)`, `sse(source, options)` and `lastEventId(req)` are not guards but belong beside them —
see **Events** below.

**`logger`'s sink is a function of a record, which is exactly what
[logger](https://github.com/slate-language/logger) takes**, so the two fit with nothing between
them — no adapter, no line of text built in the wrong place:

```slate
import { api, logger } from sluice
import { info, setLevel, setSink, json } from logger

setLevel("info")
setSink((r) -> print(json(r)))

app.get("/notes", logger((r) -> info("request", r), handler))
```

```
{"time":"2026-09-03T18:25:57Z","level":"info","message":"request","method":"GET","path":"/notes","status":200,"ms":0}
```

**Each takes the handler last, and each may be given none** — in which case it answers the guard
itself, which is what goes in a `stack`. The two spellings differ in how they read and in nothing
else:

```slate
app.post("/notes", logger(print, bearer(check, body(NewNote, create))))
app.post("/notes", stack([logger(print), bearer(check), body(NewNote)])(create))
```

`guardOf(label, wrap)` makes one of your own, with the name `api.routes()` will print for it.

**`bearer`'s `verify` is the application's and answers a result** — `{ ok: true, value: user }` or
`{ ok: false, error: text }`, which is the channel `slate:jwt`'s own `verify` uses. It may answer a
promise, so a verifier that asks a database is an ordinary one. This package holds no opinion about
what a token is.

## Staying up

**Four guards that are about the server rather than about one request.** `body` and `bearer` decide
whether a request is acceptable; these are what a service running under a load balancer needs in
order to be followed in a log, to refuse to wait forever, and not to be the only thing one client is
doing.

```slate
import { api, stack, requestId, timeout, rateLimit, logger } from sluice

app.post("/notes", stack([requestId({}),
                          logger(said),
                          timeout(2000, {}),
                          rateLimit({ limit: 100, window: 60000 })])(create))
```

**They go outside the guards about the endpoint**, which is what reading in request order means: a
request is named, then bounded, then counted, and only then is its body anybody's business.

### `requestId`

**One name for this request, on `req.id` and echoed on the answer.** An id a client sent under
`X-Request-Id` is taken rather than replaced — a gateway or a caller has already written it in a log
of its own, and renaming it breaks the one join a person is trying to make. Where there was none, 16
random bytes in base64url — 22 characters carrying what 32 of hex carried, on a value that goes into
a header on every answer and into every log line the request writes.

**`logger`'s record carries `id` wherever this guard ran**, which is what turns a log into something
a person can follow one request through, and carries `address` — the peer of the socket, or the
first hop of `X-Forwarded-For` where `options.trustProxy` says a proxy in front of this server wrote
it, exactly as `rateLimit` reads it:

```
2026-09-05T12:07:51Z INFO  request method=POST path=/notes status=201 ms=0 address=203.0.113.7 id=Qwc4shTADrdTa1jXzR0Vpw
```

**What a client sent is checked before it is echoed.** The value goes back out in a response header,
so an id carrying a carriage return would be a client writing headers of its own; one longer than 200
characters is a log line of unbounded length on every line the request writes. Either is replaced by
a generated id rather than refused — this is not an authentication, and a client with a strange id
still deserves an answer. `options` takes `header` and `generate`.

### `timeout(ms)`

**A `503` problem where the handler has not answered in `ms`.** 503 and not 504: RFC 9110 gives 504 to
a server *"acting as a gateway or proxy"* that did not hear from an upstream one, and the handler this
wraps is not upstream of anything — it is this server, *"currently unable to handle the request"*.
`{ status: 504 }` is for a handler that really is calling something else.

**A late answer is dropped rather than sent, and the work is not stopped.** slate has no way to
cancel a promise, and what a handler is doing may be a write that is going to happen whatever this
guard thinks — so the honest statement is that the *answer* is dropped. `options.onLate` is given
`{ ok: true, value }` for one that arrived late, and `{ ok: false, error }` for a handler that
faulted late, which would otherwise be the one thing that vanished: the request has been answered, so
there is no `500` left to make of it and nothing to raise it from.

### `rateLimit`

**A fixed window per key, and `429` with an exact `Retry-After` over it.**

```slate
app.post("/notes", rateLimit({ limit: 100, window: 60000, key: (req) -> req.user.account }, create))
```

**A fixed window and not a token bucket, and the reason is the store.** A bucket reads a count and a
timestamp, works out a refill and writes both back — a read-modify-write two servers sharing one
store race on. A window is an increment and an expiry: two commands, no read, and the same three lines
against redis as against the object in this package. **What it costs is a burst at the boundary**, and
it is written down rather than discovered: a limit of 60 a minute permits 120 across two seconds once.
Where that matters, use a shorter window.

**`store` is an option and its whole interface is `hit(bucket, ttl)` answering the count.** That is
the shape a shared store can implement, and `rateStore()` is the one you get when you say nothing.

**The default key is `req.address` — who connected — and a forwarded header is not an identity.**
The address is the peer of this request's socket, normalised by `slate:http` so that an IPv4 client of
a dual-stack server is `127.0.0.1` and not `::ffff:127.0.0.1`, and it is the one fact about a client
the client did not choose. `x-forwarded-for` and `x-real-ip` are **text anybody may write**: a limiter
that read them by default would hand a fresh allowance to every request that made one up, which is a
limit that stops only the clients who were not trying.

```slate
app.get("/notes", rateLimit({ trustProxy: true }, handler))
```

**`trustProxy` is where you say something in front of this server overwrites them**, and there they
are read *first* — behind a proxy the address is the proxy's and every client in the world shares it.
The leftmost entry of `x-forwarded-for` is taken, a proxy appending the peer it saw to whatever it was
given; `x-real-ip` is the fallback, and the address is the fallback after that. Turn it on only where
a proxy really is in front, and only where that proxy *replaces* the header rather than appending to
one a client sent.

Where the socket cannot say who connected, the key is `"unknown"` — a global limit rather than a
per-client one. A deployment whose clients are accounts, tenants or api keys wants a `key` of its own,
which is the option every real one uses.

**Every answer carries `X-RateLimit-Limit`, `-Remaining` and `-Reset`.** `Reset` is seconds from now
and not an epoch second — the clock a window is measured against is monotonic and names no point in
time, and a delta survives a client whose clock is wrong.

## Uploads

**`multipart` parses a `multipart/form-data` body into `req.form`**, which is `{ fields, files }`.

```slate
app.post("/notes", multipart({ maxBytes: 65536 }, (req) -> save(req.form.files[0])))
```

`fields` is an object read by name, where a repeated name keeps the last — the rule `slate:http`
already applies to a repeated name in a query string. `files` is an array, because two files may be
sent under one name, and each is `{ field, filename, type, bytes, text }`. **`type` is what the
client claimed** and is worth exactly that.

**A FIELD IS TEXT AND A FILE IS BYTES, AND NEITHER IS SOMETIMES THE OTHER.** A form field comes from
a control a person typed into, so `fields` is name to string; a file is whatever was chosen from a
disk, so `bytes` is exactly what arrived and `text()` answers it decoded or `null` where it is not
text:

```slate
for f in req.form.files
    print(f.filename, f.bytes.length, f.text() ?? "(not text)")
```

**`text` is a function and `bytes` is never sometimes a string**, which is the decision `slate:http`
made about a repeated query name read again: a member whose *type* depends on what a client sent is a
program that works until somebody uploads a PNG. The decode is asked for rather than done to every
upload.

**`accept` is where an endpoint says what it will take**, given each file after the body is parsed:

```slate
png(f) = f.bytes[0] == 0x89 && f.bytes[1] == 0x50

app.post("/avatars", multipart({ accept: png }, (req) -> store(req.form.files[0])))
```

It is a predicate and not a list of media types, because `type` is what the client *claimed* — a
predicate is given the bytes and can look at them.

`415` where the body is not multipart or `accept` refuses a file, `400` where it will not parse,
carrying the reason it did not, and `413` over `maxBytes` — counted in **bytes**, a limit being about
what the socket carried. The default is a megabyte, which is what `slate:http` reads whole.

A file `accept` turned down names the part it turned down, in a document whose own `type` is
`about:blank` — the media type the client claimed is `mediaType`, RFC 9457 having already given
`type` to the kind of problem:

```json
{ "type": "about:blank", "title": "Unsupported Media Type", "status": 415,
  "detail": "this endpoint does not take this upload", "instance": "/avatars",
  "field": "photo", "filename": "innocent.png", "mediaType": "image/png" }
```

**A LARGE UPLOAD STILL WANTS `serveStream`.** `serve` holds the entire body in memory before a
handler sees any of it, and finding the delimiters is a scan of every byte of it, so `maxBytes` is
where that stops. `slate:http` parses no multipart body and says the parsing is the program's; this is
that parsing, for the uploads a whole-body read is the right shape for.

## Health, and stopping

**`app.health(path, check)` is a route convention rather than a guard**, and it has to be: the thing
asking is a load balancer and not a client of this API. It has no token, is not to be logged with the
traffic and is not to be counted against a rate limit, so it is added on its own and runs under
nothing.

```slate
app.health()                        // 200 { "status": "ok" } at /health
app.health("/-/ready", ready)

ready() = if store.reachable() then [] else ["the note store is not answering"]
```

**A check answers the reasons it is unwell, and an empty answer means it is well.** A boolean would
make a failing health check a page nobody can act on — the operator is looking at it because
something is wrong and wants to be told which of the four things it is. The reasons go out in a `503`
problem document, like every other refusal here. A check may answer a promise, and is asked nothing
about the request.

```slate
import { onShutdown } from sluice
import { serve } from slate:http

val server = serve(8080, app)

onShutdown(() -> app.drain(server, { grace: 10000 }))
```

**A drain is three things in one order**: stop taking requests, let what is in hand finish, then let
go of the socket. Doing them in any other order lets a request in. `app.drain` answers
`{ cut, waited, ended }` — `cut` being how many requests were still running when the grace ran out,
because a shutdown that regularly cuts requests off is a grace that is too short or a handler that is
too slow, and neither is visible unless the number is.

**An event stream is not a request in flight, and a drain that waited for one would wait for ever.**
`handle` is done with an SSE route the moment it answers the response, so nothing is counted while
the stream is open — and `close` then holds the socket for that unfinished response until the
connection times out. So a program with hubs names them, and their streams are ended as soon as new
work is refused, with a last event where the program has one to send:

```slate
onShutdown(() -> app.drain(server, { grace: 10000, hubs: [feed],
    farewell: { event: "shutdown", data: "back shortly" } }))
```

`ended` is how many streams there were, and the grace bounds the wait for them exactly as it bounds
the wait for a request: a client that never comes back for the end of its stream does not hold the
socket for ever.

**A draining server answers `503` rather than closing the connection**, which is the load balancer's
cue to send the next request elsewhere — a client that is told retries somewhere useful and one that
is cut off retries here. **Its own health check fails too**, which falls out of that rather than being
arranged, and is the order a rolling deployment needs.

**`api.handle` is what counts requests in flight**, because nothing in `slate:http` does: a server
knows about connections, and a keep-alive connection with nothing on it is not work. `app.inflight()`
is the number, and `drain(server, options)` on its own takes an `inflight` of your own for a program
serving something that is not an api.

**It is built on `slate:http`'s own `close`**, which stops accepting, closes idle connections at once,
and lets a connection with a request in flight finish that response — node's rule since v19 and
slate's since **0.0.26**. What `close` does not do is *wait*, and it has no bound; the waiting and the
bound are what this adds.

**`onShutdown` watches `SIGTERM` and `SIGINT`** — a container stopping and Ctrl-C — and answers a
function that stops watching. `signals` says which, and `on` and `off` are there for a program that
watches them itself.

## Sessions

**With no store the session IS the data, signed.** The value travels in the cookie, an HMAC over it
says nobody changed it, and the server holds nothing at all — no backing thing to run and no I/O to
read one. **With a store the cookie carries only a signed id**, which is what buys revocation and a
session bigger than a cookie; it is the same guard and one more option, and it is below.

```slate
import { api, session, csrf, json } from sluice

val app = api()

app.post("/login", session(Secret, {}, (req) -> logIn(req)))
app.get("/me", session(Secret, {}, (req) -> json({ who: req.session.value })))

logIn(req)
    req.session.set({ user: "ada" })

    json({ ok: true })
```

**`req.session` is `{ value, set, destroy }`.** `value` is what the cookie said, or `null` where there was no
cookie, where it had been tampered with, or where it had expired — which are one thing to a handler:
there is nobody logged in. Telling them apart would hand a client the difference between "no cookie"
and "a bad signature", which is a thing to know only if you are forging one.

**The cookie is written only where `set` was called**, so an ordinary request that reads a session
and answers carries no `Set-Cookie` at all. `set(null)` clears it, and `destroy()` is that with a
name.

**What it costs is written down rather than discovered.** A cookie is about 4 KB, so a session is a
handful of fields and not a shopping basket — and with no store **there is no revocation**: a signed
cookie is good until it expires, so `maxAge` is the only way to end one early and a password change
does not log anybody out. Both of those are what a store buys.

**The defaults are the safe ones and every one is overridable** — `httpOnly`, `sameSite: "Lax"`,
`path: "/"`, and `secure` where the request arrived over https, which follows `x-forwarded-proto`
rather than being on always, or a session would not work over `http://localhost`. `options` also
takes `name` (`"session"`), `store`, `maxAge` in seconds, and anything else `slate:http`'s
`setCookie` takes.

### A session in a store

**With a store the cookie carries only a signed, opaque id and the value lives on the server**, which
is what buys revocation and a session bigger than a cookie:

```slate
import { api, session, json, memoryStore } from sluice

val sessions = memoryStore()

app.post("/login", session(Secret, { store: sessions, maxAge: 86400 }, (req) -> logIn(req)))
app.post("/logout", session(Secret, { store: sessions }, (req) -> loggedOut(req)))

loggedOut(req)
    req.session.destroy()

    json({ ok: true })
```

**Nothing written against `req.session` changes.** It is the same guard, the same cookie and the same
`{ value, set, destroy }` — a program that outgrows a signed cookie adds one option.

**A store is three functions and a plain object**, so one over redis, a database or a file is
something a program writes in a dozen lines and this package knows nothing about:

```slate
{ get: (id) -> value or null, set: (id, value, ttl) -> …, delete: (id) -> … }
```

Each may answer a promise, which is what lets a store be a database — the guard awaits all three, and
`await` of a plain value answers it, so a store whose functions are ordinary works too. `ttl` is in
**milliseconds**, or `null`, and it is what `maxAge` becomes. `get` answers `null` for an id that was
never there, one that expired and one that was revoked, which are one thing to a handler: there is
nobody logged in.

**`memoryStore(options)` is the reference implementation**, and it is what a single server, a
development machine and a test suite want; a fleet wants redis or a table. `options` takes `ttl`, a
default lifetime for an entry set without one, and `now`, a clock answering milliseconds since the
epoch — which is what makes expiry testable without a sleep in a test.

**`destroy()` revokes rather than merely forgetting**: the entry is deleted from the store and the
cookie is cleared, so a logged-out session is gone from the server too. Revoking somebody else's is
`store.delete(id)`, which is the thing a signed cookie cannot do at all.

**A session that is written is written under a new id, and the old id is deleted.** That closes
session fixation — an id planted in somebody's browser before they log in is not the id they are
logged in under — and it costs one delete beside the set. Only `set` and `destroy` write; a request
that reads a session touches the store once.

**The two modes cannot read each other's cookies.** The payload names what it carries, so a cookie
from a store-mode server is nobody to a signed-cookie one and the other way about, however well
signed: moving a program from one to the other logs everybody out, and does not hand a handler
somebody's opaque id as their session.

**A store that faults answers `500`.** A database that is down is not a client who is nobody, and a
guard that quietly handed the handler `null` would log every user out on a blip while answering
`200`.

## CSRF

**A random token in a cookie a script can read, required back in a header on every unsafe method.**
A form posted from another site carries the cookie — browsers send those — and cannot read it to put
in a header, because reading it needs script running on this origin.

```slate
app.post("/notes", csrf({}, session(Secret, {}, create)))
```

**`SameSite=Lax` on the session cookie is the first line and the token is depth.** A browser that
honours it does not send the session with a cross-site `POST` at all; the token covers the browsers
and the cases that do not.

`POST`, `PUT`, `PATCH` and `DELETE` need the header; `GET`, `HEAD` and the rest do not, and a client
with no token is issued one on its first safe request. A missing or mismatched token is a `403`
problem. The comparison is `slate:crypto`'s `timingSafeEqual`. `options` takes `name` (`"csrf"`) and
`header` (`"x-csrf-token"`).

**This is the one cookie deliberately not `HttpOnly`**, and the whole double-submit argument rests on
it: a page has to be able to read the token to send it back.

## Upgrading from 0.4.1

**The floor is slate 0.0.35**, which removed the global `len(x)` and the `.len()` method alias in
favour of the `.length` property. This package had no call sites of either; the bump moves the
`logger` and `pg` dev dependencies to their own 0.0.35-floor releases, 0.2.0 and 0.5.0.

## Upgrading from 0.4.0

**The media type in `multipart`'s `415` moved from `type` to `mediaType`, and that is a fix rather
than a rename.** RFC 9457 gives `type` to the *problem's* type — a URI naming the kind of failure,
`about:blank` where there is none — and an extension member is merged at the top level of the same
document, so the file's media type under that name did not sit beside the document's own `type`, it
replaced it. A refusal came back saying `"type": "image/png"`, which reads to anything following the
specification as a problem type of `image/png`: not a URI, and not what the refusal was about.

**A client reading `doc.type` to find out what was refused reads `doc.mediaType`.** `field`,
`filename`, `status`, `title` and `detail` are all unchanged, and `type` now says `about:blank` as it
does for every other refusal this package makes. Nothing else in the package moved and no behaviour
but that member's name changed.

## Upgrading from 0.3.0

**The floor is slate 0.0.30**, and it is two things on the request: `req.bytes`, which is what
`multipart` now reads, and `req.address`, which is what `rateLimit` now keys on.

**`multipart` takes binary parts, and a file's `content` is gone.** A file is
`{ field, filename, type, bytes, text }` — `bytes` is what arrived and `text()` answers it decoded or
`null`. A handler that read `f.content` reads `f.text()`, and one that was only ever going to see
text will find that it still gets it. `fields` is unchanged, except that a field whose bytes are not
text is now a `400` rather than an empty string.

**`multipart`'s `limit` is now `maxBytes`.** The old name is not read; a route passing `limit` gets
the default megabyte with no warning, so grep for it. It also now counts the bytes that *arrived*
rather than the bytes of the text they decoded to — which is a hole shut as well as a rename, a binary
body having measured `0` and passed every ceiling.

**`multipart` no longer writes `req.raw`.** `req.bytes` is what it was for and the server puts it on
every request. (`body`'s `raw` is untouched: that guard replaces `req.body` with the parsed value, so
the text it took has nowhere else to be.)

**`rateLimit` keys on `req.address` and ignores `x-forwarded-for` unless `trustProxy` is set.** A
server behind nginx, a load balancer or a CDN wants `rateLimit({ trustProxy: true }, …)`; one exposed
directly wants the new default, which is not bypassable with a header. A deployment that passed its
own `key` is unaffected. See **Rate limiting** for why the old default was the wrong way round.

**`memoryStore` deletes with `without`**, which is behaviour-for-behaviour what the mark-and-rebuild
it replaces did. Nothing to change; it is noted because a delete is now linear in the sessions held
rather than amortised constant, and a service with enough sessions for that to matter wanted redis
long before this release.

## Upgrading from 0.2.0

**Every session cookie written by 0.2.0 reads as nobody, and every logged-in user is logged out
once.** The signature and the stored session id were hex and are now base64url — `slate:url`'s, from
slate 0.0.29 — so the digest a browser is holding is not the digest this version makes of the same
payload. That is the ordinary way of being nobody: `req.session.value` is `null`, the handler is told
there is nobody logged in, and the next login writes a cookie in the new spelling. Nothing faults and
nothing is refused.

**Deploy it the way you would a change of secret**, which is what it amounts to for one release: at
a quiet hour, or behind a login page people can go through again. There is no dual-reading mode and
that is deliberate — a reader that accepted both spellings would accept two encodings of one value
for the life of the package, which is the shape of hole a token compared as text is walked through.

**A CSRF token is unaffected** — it is compared against itself and never decoded, so a client holding
one issued by 0.2.0 keeps passing with it. So is a request id, which lives for one request.

## Events

**A hub, and the server-sent stream a subscriber reads it through.**

```slate
import { api, hub, sse } from sluice

val app = api()
val feed = hub()

app.get("/events", (req) -> sse(feed.subscribe("notes")))
app.post("/notes", (req) -> made(feed, req))

made(feed, req)
    feed.publish("notes", { event: "made", data: { id: 7 } })

    json({ ok: true }, 201)
```

**`subscribe` answers a source** — `{ next }` answering `{ done, value }` — which is exactly what
`sse` takes, so sluice adds no shape of its own and a test pulls events out of a handler's answer
with no port anywhere.

**It is SSE and not a WebSocket, and that is the design rather than a stage.** A hub is one-way. A
server-sent stream is a plain `GET`, so every guard here already applies to it — including `session`
and `csrf` — and a browser reconnects on its own. A program that genuinely needs two-way traffic
wants `slate:ws` directly.

**A subscriber that falls behind loses the oldest events, and the drops are counted.** The bound is
`options.bound`, 256 by default. A live feed stays live: a client that cannot keep up wants the
newest state and not a backlog, and the alternative to dropping is a queue one slow client can grow
until the server runs out of memory. `source.dropped()` says how many went, so a client falling
behind is a number rather than a silence.

**A subscriber whose reader has gone is let go of, and nothing in your program has to notice.** From
slate 0.0.29 a streamed response that ends with its source unexhausted — a tab closed, a socket cut
off, a peer that reset the stream — calls `close` on the source, and `sse` forwards that to the
source it was given. So a browser that goes away takes its subscription with it: `feed.count(topic)`
falls, and no handler was told anything.

**`source.close()` is still yours to call for a subscription you are ending yourself** — a stream
your program stops, a subscriber a test is done with — and it is idempotent, so it costs nothing to
call one the writer has already closed. `feed.count(topic)` is how either is seen, and it is what
`tests/hangup.sl` — the one test in this package that binds a port — asserts against a real client
that hangs up mid-stream.

**`feed.endAll(options)` ends every open stream on every topic, and a shutdown is what calls it.** An
event stream is a response that never finishes, so a server with one subscriber attached holds its
socket until the stream ends — `app.drain(server, { hubs: [feed] })` is where a program says which
hubs are feeding them, and the drain then closes promptly instead of waiting its grace out. SSE has
no goodbye of its own, so a last event is yours to name: `endAll({ event: … })` sends it before the
end, `endAll()` says nothing, and either way `endAll` answers how many streams there were. A browser
reconnects on its own to whichever instance is taking traffic by then.

**A stream ends when its reader takes the end, and `feed.open()` is how many have not yet** — every
topic together, which is what a drain waits on. Closing the socket in between would throw away the
very event that was worth sending.

### Replay, for a client that reconnects

**A hub asked for it keeps the last N events of every topic**, and a client that reconnects saying
where it left off is handed what it missed before anything live:

```slate
import { api, hub, sse, lastEventId } from sluice

val feed = hub({ replay: 64 })

app.get("/events", (req) -> sse(feed.subscribe("notes", { lastEventId: lastEventId(req) })))
```

**`replay` is `0` by default and `0` means off**, which is what most feeds want — a browser
reconnects, asks for the current state and carries on. A hub that remembers nothing also sends no
ids, because an id is a promise to be able to replay from it.

**With `replay` on, every event carries one.** An object published to a topic is given an `id`
member and anything else is wrapped as its `data`, which is `slate:http`'s own shape for a piece of
an event stream — so `publish("notes", "hello")` goes out as `id: 1` and `data: hello`, and
`publish("notes", { event: "made", data: { id: 7 } })` keeps its event name and gains the id. **The
ids are the topic's**, counted from 1: a client reconnects to the stream it was reading, and an id
from another topic would place it somewhere arbitrary in this one.

**`lastEventId(req)` reads the request and `subscribe` takes the id**, which is what keeps the hub
one-way: a hub knows about topics and not about requests, and `sse` takes a source and not a
request. It reads the `Last-Event-ID` header a browser sends on its own, and the `lastEventId` query
parameter for a client that cannot put a header on an `EventSource`.

**An id older than the buffer is handed everything still held, and the client is told nothing.**
That is what a browser expects: `EventSource` has no way of being told it missed something and no
way of asking again, so a hole arrives as a gap in the ids — a client that must not have one checks
them, and one that only wants the current state carries on. **An id this hub did not write replays
nothing and goes live**, a position that cannot be read being no position at all.

**The replay goes through the same bounded queue the live events go through**, so a backlog longer
than `bound` drops its oldest and `source.dropped()` counts them, exactly as a burst would. One rule
about falling behind rather than two.

## The failure type is passed by its own name

`api.failures` takes the type itself: a `data` name is a shape value, so `Failure.test` is how
`handle` tells a returned failure from a response. The annotation on the mapping is `(f: Failure)`,
which is what the exhaustiveness check reads — one name doing both jobs.

**It was `type Fail = Failure` until slate 0.0.24.** A `data` name bound a plain object with no shape
near it, so every application declared an alias of a name that was already a type to get past an
annotation. That was reported from here and fixed in the compiler rather than worked around.

## What a failure costs, and what it buys

`check/exhaustive.sl` is a program that leaves one variant unanswered. **It does not compile**, and
that refusal is the whole argument for returning failures rather than throwing them:

```
error: this match does not cover every Failure -- `Taken` is unmatched. Add an arm for it, or `_` for whatever is left
```

**The mapping is applied at every level of a route's composition** — around the handler, and again
around each guard — which matters more than it looks. Under the guards, because a `logger` above an
untranslated failure would report `200` for what a client received as `409`, and a `cors` above one
would wrap the failure in an envelope and send it out as a `200`. Between them, because **a guard may
return a failure too**:

```slate
val needsSession = guardOf("needsSession", (h) -> (req) -> ifSomebody(h, req))

ifSomebody(h, req) = if req.session.value == null then NotSignedIn else h(req)
```

**So a guard refuses exactly the way a handler does**, and everything above it — another guard, or
the server — sees the HTTP response that failure became. A guard answering a `problem(…)` document
directly is still an ordinary thing to write, and `bearer`'s own `401` is one; what changed in 0.3.0
is that it is no longer the only thing that works. Where an application registered no mapping, a
guard's failure goes out exactly as a handler's does: the value itself.

## A defect is still a defect

**A handler that faults answers a `500` problem, and the fault is put back on the loop afterwards** —
which is what `slate:http` does for its own handlers. The client is told, and the program stops
rather than swallowing a defect into a log nobody reads. `api({ onFault: fn })` is how a program
that has somewhere to send a defect says so, and how a test watches it happen without ending the
run. What the client is told and what the program is told are different things on purpose: the 500's
`detail` never quotes the fault.

## An application over PostgreSQL

**`examples/tasks/` is a task list backed by a real database**, and it is the whole of this page in
one place: a session login over `memoryStore`, a body checked against a declared type, a `data
Failure` whose mapping is proved complete before the program runs, `requestId`, `logger`, `timeout`,
`rateLimit`, a health check that asks the database, and `drain` on the way out.

```
PG_URL=postgres://ada:secret@127.0.0.1:5432/tasks slate examples/tasks/main.sl
```

With no `PG_URL` it connects wherever `psql` would — [pg](https://github.com/slate-language/pg) reads
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` when it is given nothing. It makes its
table if there is none, binds a port the kernel chose, runs a client through every route, and takes
its own rows away again, so running it twice does what running it once did.

**It is three files because of one seam, and the seam is worth copying.** `tasks.sl` is the
application and holds no SQL: it is written against a STORE — `list`, `add`, `done`, `remove` and
`ping`, each answering `{ ok: true, value }` or `{ ok: false, error, code }`, and each of which may
answer a promise. `postgres.sl` is those five over `pg` and is the only file that knows a statement.
`main.sl` is the wiring.

```slate
app.post("/tasks", guarded(body(NewTask, (req) -> made(store, req))))

async made(store, req)
    val r = await store.add(req.body.title)

    if r.ok then return json(r.value, 201)
    if r.code == "23505" then return Taken(req.body.title)

    Unavailable(r.error)
```

**A unique index is what makes a duplicate title one round trip**, and `23505` is the database saying
the one thing this application already has a word for. Every other code it has nothing to say about,
so it answers `503` — and a database that is down is an answer rather than a defect, because `pg`
answers a result for anything that reaches the network.

**Every query is a promise on the loop that is answering HTTP**, which is what `pg` speaking the wire
protocol in slate buys: a handler waiting for PostgreSQL is the only thing waiting.

The seam is also what makes the example testable. `tests/tasks.sl` writes the same five functions
over an array and drives every route with no database and no socket, under both hosts;
`tests/postgres.sl` runs the real store over a real socket against a PostgreSQL server written in
slate (`tests/pgserver.sl`) and reads what it actually sent. That file needs `slate:net`, which the
JavaScript back end has not got, so each of its tests asks whether it can bind a socket and says so
rather than failing.

## Running the suite and the examples

```
slate test tests
slate test --js tests
slate examples/notes.sl
slate examples/tasks/main.sl
```

`check/` holds the two hand-run drivers — the exhaustiveness refusal above, and a defect stopping the
program — and they are not under `tests/` because passing would mean ending the run.

**It needs slate 0.0.30 or later.** Shape values with `test`/`mismatch`/`name` are what make a
declaration the validator and `?` optional keys are what let a request body have one, both from
0.0.7; 0.0.23 gave `slate:http` the `percentDecode` a path parameter is read with and the manifest
the `devDependencies` section below; 0.0.24 made a `data` name one of those shape values, which is
what `api.failures(Failure, …)` on this page is; 0.0.27 let `slate:http` take an array for a header
that repeats, which is how a login writes two cookies; 0.0.29 gave `slate:url` the
`base64urlEncode`/`base64urlDecode` every signature and session id on this page is written in, and a
streamed response the ability to tell its source that its reader has gone, which is what stops an
event stream leaking a subscriber per browser tab. 0.0.30 raised the floor for two members
of the request: `req.bytes`, which is what lets `multipart` read an upload that is not text, and
`req.address`, which is who `rateLimit` counts. `without` is in here too — `memoryStore` deletes with
it — but that one is a simplification and not a floor.

**[logger](https://github.com/slate-language/logger) 0.2.0 and
[pg](https://github.com/slate-language/pg) 0.5.0 are DEV dependencies**, used by the examples and by
four test files. Installing `sluice` installs neither: a package's own `devDependencies` are resolved
only when that package is the project being built, so nothing this framework puts on a machine
carries a logger or a database client it did not ask for.

**The suite runs under node as well**, which is what `slate test --js tests` above is: `monotonic`,
which a request is timed with, is on the JavaScript back end from **slate 0.0.25**. That is this
package's floor on a JavaScript host; 0.0.24 still runs it under the interpreter.
