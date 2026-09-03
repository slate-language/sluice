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
3. **A failure is a value a handler RETURNS.** `api.failures(Shape, fn)` registers the shape and the
   mapping, and because `fn` is annotated `(f: Failure) -> …`, slate's exhaustiveness rule proves
   before the program runs that every failure the application can produce has an HTTP answer.
   Nothing in express or axum can check that.
4. **RFC 9457 problem details by default** — `application/problem+json` with `type`, `title`,
   `status`, `detail` and `instance`. 404, 405, 400, 401 and 500 all go out as problem documents.
5. **`await api.handle(request)` answers a response with no socket in it.** The whole suite of this
   package is written that way: no port, no client, no watchdog, and nothing that can flake under
   load.

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

## The guards

| | |
|---|---|
| `body(Shape, handler)` | parses JSON, checks it against `Shape`, hands it on under `body` with the text on `raw`; a `400` problem carrying every mismatch otherwise |
| `query(Shape, handler)` | the same check over `req.query`, which is already an object of strings |
| `bearer(verify, handler)` | the token out of `Authorization`, `req with { user }`; a `401` problem with `WWW-Authenticate` otherwise |
| `cors(options, handler)` | the headers a browser needs, and a preflight answered without the handler running |
| `logger(sink, handler)` | `sink({ method, path, status, ms })` once the answer is known |

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

**The mapping runs under the guards, not over them**, which matters more than it looks: a `logger`
above an unmapped failure would report `200` for what a client received as `409`, and a `cors` above
one would wrap the failure in an envelope and send it out as a `200`.

## A defect is still a defect

**A handler that faults answers a `500` problem, and the fault is put back on the loop afterwards** —
which is what `slate:http` does for its own handlers. The client is told, and the program stops
rather than swallowing a defect into a log nobody reads. `api({ onFault: fn })` is how a program
that has somewhere to send a defect says so, and how a test watches it happen without ending the
run. What the client is told and what the program is told are different things on purpose: the 500's
`detail` never quotes the fault.

## Running the suite and the examples

```
slate test tests
slate examples/notes.sl
```

`check/` holds the two hand-run drivers — the exhaustiveness refusal above, and a defect stopping the
program — and they are not under `tests/` because passing would mean ending the run.

**It needs slate 0.0.24 or later.** Shape values with `test`/`mismatch`/`name` are what make a
declaration the validator and `?` optional keys are what let a request body have one, both from
0.0.7; 0.0.23 gave `slate:http` the `percentDecode` a path parameter is read with and the manifest
the `devDependencies` section below; 0.0.24 made a `data` name one of those shape values, which is
what `api.failures(Failure, …)` on this page is.

**[logger](https://github.com/slate-language/logger) 0.1.0 is a DEV dependency**, used by the example
and one test. Installing `sluice` does not install it: a package's own `devDependencies` are resolved
only when that package is the project being built.

**`slate test --js` does not run this suite yet**: `monotonic`, which `logger` times a request with,
is one of the builtins the JavaScript back end still owes.
