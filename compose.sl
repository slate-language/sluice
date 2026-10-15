// Guards composed around a handler: `stack`, and the two compositions under it.
//
// **A file of its own because two others build on it** -- `api.sl`, which recomposes a route's list
// around the failure mapping, and `routing.sl`, whose groups and resources put guards outside a
// handler the same way a stack does.

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
    var i = guards.length - 1

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

// `h` with `guards` outside it, or `h` itself where there are none.
//
// **This is `stack(guards)(h)` and nothing else**, so a route a group or a resource added prints in
// `api.routes()` exactly as the same route spelled with a stack does -- and `api.add` recomposes it
// with the failure mapping between every layer, the group's guards included.
export within(guards: array, h) = if guards.length == 0 then h else stack(guards)(h)

// The guards a group or a resource was given, as a list. **A list or a `stack(…)` and nothing else**:
// a stack is the same list with its labels kept, so both spell one thing.
export guardList(given, what: string) -> array
    if given is array then return given

    if given is object && has(given, "wrappers") && given.wrappers is array then return given.wrappers

    throw what + " takes its guards as a list or a `stack(…)`, and this is neither"
