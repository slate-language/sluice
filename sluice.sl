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

import { makeApi, stack as makeStack, lazy } from "./api.sl"
import { problemResponse, jsonResponse, asResponse } from "./response.sl"
import { bodyGuard, queryGuard, bearerGuard, corsGuard, loggerGuard, guard, labelOf } from "./guards.sl"
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
