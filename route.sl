// Matching a request's path against a route's, and what a `:name` binds to.
//
// **This is `slate:http`'s `router()` written again, and the three reasons are worth stating** —
// reusing it was the first thing tried:
//
// 1. **`router()` keeps its route table private and answers nothing about it.** `api.routes()` has
//    to say what each route actually runs, which is the one thing composition gives up against an
//    interceptor chain and the reason a stack remembers the list it was built from. A table nobody
//    can read cannot be printed.
// 2. **`router()` writes `req.params` onto the request it was given.** A request here is a value
//    and every guard adds to it with `with`; a matcher that mutates its argument would make the
//    same request answer differently the second time it is handled, which is exactly what the
//    port-free suite does.
// 3. **Its `404` and `405` are plain text.** Every refusal this framework makes is a problem
//    document, and telling `router()`'s own `405` from a handler that answered `405` would mean
//    reading a response to guess where it came from.
//
// What is kept is its behaviour, deliberately: `:name` and `*rest`, routes tried in the order they
// were added, and a path that is there under another method answered `405` with an `Allow`.
//
// **Percent-decoding is `slate:http`'s**, and this file kept a copy of it only while the server did
// not export one. `percentDecode(s, plusIsSpace)` is the same walk over bytes, `+` left alone in a
// path, and a `%` not followed by two hexadecimal digits kept as a `%` -- which is what a browser
// does with one, and refusing would let any peer stop a program over a character somebody typed.
import { percentDecode } from slate:http

// The parts of a path, with the leading and trailing slashes gone. `/` is no parts at all, which is
// what makes it match a route written `/` and nothing else.
export segments(path: string) -> array of string
    var p = path
    val q = indexOf(p, "?")

    if q != null then p = p[0..<q]

    while startsWith(p, "/")
        p = p[1..<p.length]

    while endsWith(p, "/") && p != ""
        p = p[0..<(p.length - 1)]

    if p == "" then [] else split(p, "/")

// Whether a route's parts fit a request's, and what its parameters bind to. `null` where they do
// not, which is a search that found nothing rather than a mistake.
//
// **A `*name` takes the whole of the rest, slashes included**, which is the one pattern that may
// match a different number of parts than it has.
export fit(parts: array of string, want: array of string) -> object | null
    var out = {}
    var i = 0

    while i < parts.length
        val p = parts[i]

        if startsWith(p, "*")
            val rest = p[1..<p.length]

            if rest != "" then out[rest] = join(want[i..<want.length], "/")

            return out

        if i >= want.length then return null

        if startsWith(p, ":")
            out[p[1..<p.length]] = percentDecode(want[i], false)
        elif p != want[i]
            return null

        i = i + 1

    if want.length != parts.length then null else out
