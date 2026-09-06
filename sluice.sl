// sluice -- an API-server framework for slate.
//
// **A request is a value, a handler is a function of it, and everything else is composition.** There
// is no `next`, no mutable response, no ambient context and no `app.use()`: a guard is a function
// from a handler to a handler, a stack is those functions composed once at startup, and a refusal is
// a value somebody returned.
//
//     import { api, stack, body, bearer, problem } from sluice
//     import { serve } from slate:http
//
//     type NewNote = { title: string, pinned?: boolean }
//
//     val app = api()
//
//     app.get("/notes/:id", (req) -> find(req.params.id))
//     app.post("/notes", body(NewNote, (req) -> create(req.body)))
//
//     serve(8080, app)
//
// **`api()` is an object with a `handle`, so `serve(port, app)` works unchanged** -- `slate:http`
// asks a server object for its `handle` and calls that, and nothing in it knows what this package
// is. The server stays the server; this is a layer over it and not a replacement for it.
//
// This file is the whole public surface. The working parts are behind it -- `route.sl` matches a
// path, `response.sl` builds a problem document, `guards.sl` holds the guards, `api.sl` holds the
// route table, `testing.sl` builds a request -- and every name a consumer can reach is DECLARED
// here, slate's `export` being a prefix on a declaration with no re-export form. That is what keeps
// the annotations: an annotation is the only check a consumer's call gets.

import { sse as eventStream } from slate:http

import { makeApi, stack as makeStack, lazy } from "./api.sl"
import { problemResponse, jsonResponse, asResponse } from "./response.sl"
import { bodyGuard, queryGuard, bearerGuard, corsGuard, loggerGuard, guard, labelOf } from "./guards.sl"
import { sessionGuard, csrfGuard } from "./sessions.sl"
import { requestIdGuard, timeoutGuard, rateLimitGuard, rateStore as makeStore } from "./operations.sl"
import { multipartGuard } from "./multipart.sl"
import { drainServer, onShutdown as watchSignals } from "./lifecycle.sl"
import { makeMemoryStore } from "./store.sl"
import { makeHub, lastSeenId } from "./events.sl"
import { request as makeRequest } from "./testing.sl"

// -- the api -----------------------------------------------------------------------------------------

// `api(options)` -- a router that composes, refuses in RFC 9457, and answers a response value.
//
// `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `any` and `notFound` take a path and a
// handler; `failures` takes the shape of what a handler may return instead of a response, and the
// mapping from it to HTTP; `routes` says what each route runs; `handle` answers a request.
//
// **`onFault` is the one option**: a handler that faults answers `500` and the fault is put back on
// the loop afterwards, which stops the program the way any other defect does. A test that wants to
// watch that happen without ending the run passes a sink instead.
export api(options: object = {}) -> object = makeApi(options)

// `stack([a, b])` -- `a(b(handler))`, composed once here rather than walked per request, keeping the
// list it was built from so `api.routes()` can print it.
export stack(guards: array) -> object = makeStack(guards)

// -- the guards --------------------------------------------------------------------------------------
//
// **Each takes the handler last and answers a handler, and each may be given no handler at all** --
// in which case it answers the guard itself, which is what goes in a `stack`:
//
//     app.post("/notes", body(NewNote, create))
//     app.post("/notes", stack([logger(print), bearer(check), body(NewNote)])(create))

// `body(Shape, handler)` -- parse the body as JSON, check it against `Shape`, hand it on under
// `body` with the text kept on `raw`, and answer a `400` problem carrying every mismatch otherwise.
export body(shape: shape, handler = null) = applied(bodyGuard(shape), handler)

// `query(Shape, handler)` -- check `req.query` against `Shape`, and answer a `400` problem carrying
// every mismatch otherwise. Nothing is replaced: a query string is already an object of strings.
export query(shape: shape, handler = null) = applied(queryGuard(shape), handler)

// `bearer(verify, handler)` -- take the token out of `Authorization`, hand what `verify` made of it
// on under `user`, and answer a `401` problem otherwise. `verify(token)` answers a result and may
// answer a promise.
export bearer(verify: function, handler = null) = applied(bearerGuard(verify), handler)

// `cors(options, handler)` -- the headers a browser needs, and a preflight answered without the
// handler running.
export cors(options: object, handler = null) = applied(corsGuard(options), handler)

// `logger(sink, handler)` -- `sink({ method, path, status, ms })` once the answer is known.
export logger(sink: function, handler = null) = applied(loggerGuard(sink), handler)

// `session(secret, options, handler)` -- a signed cookie carrying the session, or a signed id into a
// store.
//
// A handler is given `req.session`, which is `{ value, set, destroy }`: `value` is what the session
// said, or `null` where there was none, where the cookie had been tampered with, where it had
// expired, or where a store no longer has it; `set` writes a new one, `set(null)` clears it, and
// `destroy()` is that with a name. **The cookie is written only where `set` or `destroy` was
// called.**
//
// **`store` is what buys revocation and a session bigger than a cookie.** With one, the cookie
// carries only a signed opaque id and the value lives in the store; a session that is written is
// written under a new id, and `destroy()` deletes the entry rather than merely forgetting it.
//
// `options` takes `name` (`"session"`), `store`, `maxAge` in seconds, and anything `setCookie` takes
// -- the defaults being `httpOnly`, `sameSite: "Lax"`, `path: "/"`, and `secure` where the request
// arrived over https.
export session(secret: string, options: object = {}, handler = null) =
    applied(sessionGuard(secret, options), handler)

// `requestId(options, handler)` -- one name for this request, on `req.id` and on the answer.
//
// An id a client sent under `X-Request-Id` is taken so that a trace already begun is not broken; one
// that is too long or carries anything a header line means something by is replaced. `logger`'s
// record carries `id` wherever this ran.
//
// `options` takes `header` (`"X-Request-Id"`) and `generate`.
export requestId(options: object = {}, handler = null) = applied(requestIdGuard(options), handler)

// `timeout(ms, options, handler)` -- answer without the handler where the handler is taking too long.
//
// A `503` problem, that being what an ORIGIN server says about not being able to answer -- `504` is
// for a gateway, and `options.status` is how a handler that really is calling something upstream
// says so. **A late answer is dropped**, and `options.onLate` is given it.
export timeout(ms: integer, options: object = {}, handler = null) =
    applied(timeoutGuard(ms, options), handler)

// `rateLimit(options, handler)` -- a fixed window per key, and `429` with a `Retry-After` over it.
//
// `options` takes `limit` (`60`), `window` in milliseconds (`60000`), `key`, `now` and `store`.
//
// **The default key is what a proxy said**, `slate:http` not telling a handler who connected -- so a
// server with nothing in front of it counts every direct client under one name, and one that is
// exposed directly should pass a `key` of its own rather than trust a header a client can write.
export rateLimit(options: object = {}, handler = null) = applied(rateLimitGuard(options), handler)

// `rateStore(options)` -- where `rateLimit` keeps its counts when nothing else was given.
//
// **`hit(bucket, ttl)` answering the count is the whole interface**, which is the shape a shared
// store can implement: against redis it is an `INCR` and an expiry, with no read and no race.
export rateStore(options: object = {}) -> object = makeStore(options)

// `multipart(options, handler)` -- a `multipart/form-data` body as `req.form`, `{ fields, files }`.
//
// A field is text and a file is `{ field, filename, type, bytes, text }` -- `bytes` exactly what
// arrived, `text()` that decoded or `null` where it is not text. `415` where the body is not
// multipart or `options.accept` refuses a file, `400` where it will not parse, and `413` over
// `options.maxBytes` (a megabyte by default).
//
// **It reads BINARY uploads as of 0.4.0**, over `req.bytes`: a `.png` used to arrive as nothing at
// all, `serve` having had only the UTF-8 reading of a body to hand over. **A LARGE upload still wants
// `serveStream`**, which is what `slate:http` says about multipart in the first place -- `serve`
// holds the whole body before a handler sees any of it.
export multipart(options: object = {}, handler = null) = applied(multipartGuard(options), handler)

// `drain(server, options)` -- stop taking requests, let what is in hand finish, then close.
//
// **`api.drain(server, options)` is the one to write**, an api being the only thing that can count
// what is in flight; this is for a program serving something else. It answers
// `{ cut, waited, ended }`.
//
// **A SERVER WITH AN EVENT STREAM OPEN DOES NOT CLOSE UNTIL THE STREAM ENDS**, a stream being a
// response that never finishes -- so `hubs` is where a program names the hubs feeding them and
// `farewell` is the last event they are sent before they end:
//
//     app.drain(server, { grace: 10000, hubs: [feed], farewell: { event: "shutdown" } })
//
// `options` takes `grace` in milliseconds (`10000`), `inflight`, `stop`, `close`, `poll`, `hubs` and
// `farewell`.
export drain(server, options: object = {}) = drainServer(server, options)

// `onShutdown(action, options)` -- run `action` on `SIGTERM` and `SIGINT`, and answer how to stop.
//
//     onShutdown(() -> app.drain(server, { grace: 10000 }))
//
// `options` takes `signals`, and `on` and `off` for a program that watches them itself.
export onShutdown(action: function, options: object = {}) -> function = watchSignals(action, options)

// `memoryStore(options)` -- somewhere for a session to live, in this process's memory.
//
// **A store is three functions**: `get(id)`, `set(id, value, ttl)` and `delete(id)`, each of which
// may answer a promise, so a store over redis or a database is a plain object a program writes
// itself and this one is the reference. `ttl` is in milliseconds.
//
// `options` takes `ttl`, a default lifetime for an entry set without one, and `now`, a clock
// answering milliseconds since the epoch -- which is what makes expiry testable without a sleep.
// The store also answers `size()`, which is not part of the interface a store has to meet.
export memoryStore(options: object = {}) -> object = makeMemoryStore(options)

// `csrf(options, handler)` -- the double-submit cookie.
//
// A random token in a cookie a script can read, required back in a header on `POST`, `PUT`, `PATCH`
// and `DELETE`, compared in constant time, and a `403` problem otherwise. A client with no token is
// issued one on its first safe request.
//
// `options` takes `name` (`"csrf"`) and `header` (`"x-csrf-token"`).
export csrf(options: object = {}, handler = null) = applied(csrfGuard(options), handler)

// `hub(options)` -- an event hub: `publish(topic, value)`, `subscribe(topic, options)`,
// `count(topic)`, `open()` and `endAll(options)`.
//
// `subscribe` answers a SOURCE, which is what `sse` takes, so a route is one line:
//
//     app.get("/events", (req) -> sse(feed.subscribe("notes")))
//
// **The writer closes that source when the reader has gone**, which is `slate:http`'s from slate
// 0.0.29: a response that ends with its source unexhausted tells the source so, and `sse` forwards
// it. `close()` is still there for a program ending a subscription itself, and calling it twice is
// the same as calling it once.
//
// **`endAll` IS WHAT A SHUTDOWN CALLS**, and it is what `drain`'s `hubs` option calls for a program:
// every open stream is sent the last event `endAll({ event: … })` was given, if any, and then ends.
// It answers how many there were. Without it a draining server holds its socket for every stream
// still attached to it. **A stream ends when its reader takes the end**, which is what `open()` --
// how many streams the hub is feeding, across every topic -- is for: `drain` waits on it, under the
// same grace as a request, rather than closing the socket over the last event it just sent.
//
// `options` takes `replay`, which is how many events of every topic the hub keeps for a client that
// reconnects -- `0`, keeping nothing, by default. `subscribe`'s options are `bound`, how far behind
// a subscriber may fall before the oldest of its events are dropped (256), and `lastEventId`, the id
// a returning client last saw.
export hub(options: object = {}) -> object = makeHub(options)

// `lastEventId(req)` -- the id a reconnecting client says it last saw, or `null`.
//
// **The route reads it and hands it to `subscribe`**, which is what keeps the hub one-way: a hub
// knows about topics and not about requests, and `sse` takes a source and not a request.
//
//     app.get("/events", (req) -> sse(feed.subscribe("notes", { lastEventId: lastEventId(req) })))
//
// The `Last-Event-ID` header is what a browser sends on its own; the `lastEventId` query parameter
// is read as well, for a client that cannot put a header on an `EventSource`.
export lastEventId(req: object) -> string | null = lastSeenId(req)

// `sse(source, options)` -- an event stream, re-exported from `slate:http` so that answering with
// one does not mean importing a second module beside this.
export sse(source, options: object = {}) -> object = eventStream(source, options)

// `guard(label, wrap)` -- a guard of your own, with the name `api.routes()` will print for it.
//
//     val timing = guard("timing", (h) -> timed(h))
export val guardOf = guard

// The name a guard prints under.
export val nameOf = labelOf

// A guard given a handler is that handler wrapped; a guard given none is the guard.
//
// **The wrapped handler remembers the guards it went through**, so `body(NewNote, create)` prints in
// `api.routes()` exactly as `stack([body(NewNote)])(create)` does -- the two spellings differ in how
// they read and in nothing else. A guard wrapping something already wrapped takes its list on.
applied(g, handler)
    if handler == null then return g

    val inner = if handler is object && has(handler, "guards") then handler.guards else []
    val under = if handler is object && has(handler, "wrappers") then handler.wrappers else []
    val deepest = if handler is object && has(handler, "handler") then handler.handler else handler

    { new: lazy([g], handler),
      guards: concat([labelOf(g)], inner),
      wrappers: concat([g], under),
      handler: deepest }

// -- answers -----------------------------------------------------------------------------------------

// `problem(status, title, detail, extra)` -- an RFC 9457 problem document as a response.
//
// **`application/problem+json` and not `application/json`**, which is the whole point of the
// registration: a client can tell an error document from the document it asked for without reading
// either. `type` is `about:blank` unless `extra` says otherwise, and a member with nothing in it is
// left out rather than written `null`.
export problem(status: integer, title: string, detail: string | null = null, extra: object = {}) -> object =
    problemResponse(status, title, detail, extra)

// `json(value, status)` -- a value as an `application/json` response.
//
// **A bare object answer is a response ENVELOPE to `slate:http` and not a document**, so an API
// answering data says which it means. This is the short way of saying it.
export json(value, status: integer = 200) -> object = jsonResponse(value, status)

// `response(v)` -- any answer as `{ status, headers, body }`, which is what a guard needs that means
// to read a status or add a header.
export response(v) -> object = asResponse(v)

// -- testing -----------------------------------------------------------------------------------------

// `request(method, path, options)` -- a request value, for handing straight to `api.handle`.
//
// **The suite of this package is written entirely this way and binds no port.** It is exported
// because a program using this package wants exactly the same thing for its own handlers.
export request(method: string, path: string, options: object = {}) -> object =
    makeRequest(method, path, options)
