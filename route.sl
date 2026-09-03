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

// The parts of a path, with the leading and trailing slashes gone. `/` is no parts at all, which is
// what makes it match a route written `/` and nothing else.
export segments(path: string) -> array of string
    var p = path
    val q = indexOf(p, "?")

    if q != null then p = p[0..<q]

    while startsWith(p, "/")
        p = p[1..<len(p)]

    while endsWith(p, "/") && p != ""
        p = p[0..<(len(p) - 1)]

    if p == "" then [] else split(p, "/")

// Whether a route's parts fit a request's, and what its parameters bind to. `null` where they do
// not, which is a search that found nothing rather than a mistake.
//
// **A `*name` takes the whole of the rest, slashes included**, which is the one pattern that may
// match a different number of parts than it has.
export fit(parts: array of string, want: array of string) -> object | null
    var out = {}
    var i = 0

    while i < len(parts)
        val p = parts[i]

        if startsWith(p, "*")
            val rest = p[1..<len(p)]

            if rest != "" then out[rest] = join(want[i..<len(want)], "/")

            return out

        if i >= len(want) then return null

        if startsWith(p, ":")
            out[p[1..<len(p)]] = decodePercent(want[i])
        elif p != want[i]
            return null

        i = i + 1

    if len(want) != len(parts) then null else out

// Percent-decoding, **over bytes**: `%C3%A9` is two bytes that are one character, so decoding
// character by character would answer two characters that are not text.
//
// **Bytes that are not text answer the input unchanged**, which is `slate:http`'s rule and is not
// timidity: a path is something a peer wrote, and a fault there would let any peer stop a program.
export decodePercent(s: string) -> string
    if !contains(s, "%") then return s

    val bs = toBytes(s)
    var out = []
    var i = 0

    while i < len(bs)
        val b = bs[i]
        val hi = if b == 37 && i + 2 < len(bs) then hexDigit(bs[i + 1]) else null
        val lo = if hi == null then null else hexDigit(bs[i + 2])

        if lo == null
            push(out, b)
            i = i + 1
        else
            push(out, hi * 16 + lo)
            i = i + 3

    val text = fromBytes(out)

    if text.ok then text.value else s

// One hexadecimal digit as a number, `null` where the byte is not one.
hexDigit(b: integer) -> integer | null
    if b >= 48 && b <= 57 then return b - 48
    if b >= 65 && b <= 70 then return b - 55
    if b >= 97 && b <= 102 then return b - 87

    null
