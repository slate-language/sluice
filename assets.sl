// `asset(body, type)` -- a handler answering one fixed body that lives at a content-hashed address.
//
// **What it is for is a file whose PATH changes whenever its content does** -- `app.<hash>.css`,
// `bundle.<hash>.js` -- because that is the one kind of response a browser may keep for a year without
// asking again: a new version is a new address, so nothing stale can ever be served from the cache.
// `lath`'s `serveAppSheet()` answers exactly such a file, and the glue is one route:
//
//     val sheet = serveAppSheet()
//
//     app.get(sheet.path, asset(sheet.css, sheet.type))
//
// **This package never learns what the asset is**, which is why it takes text and a media type and
// not a stylesheet: sluice depends on nothing a front end uses, and the program that has both is the
// one that joins them.
//
// **The work is done once, when the route is added.** The digest is taken here and not per request,
// the body never changing, so a request costs one header comparison.

import { sha256 } from slate:crypto
import { base64urlEncode } from slate:url

// A year, which is what RFC 9111 treats as "never expires" and every CDN reads the same way.
// **`immutable` is what makes a RELOAD not ask either** (RFC 8246): without it a browser revalidates
// every subresource of a page the reader reloaded, and that is a round trip per asset for nothing.
val Forever = "public, max-age=31536000, immutable"

export assetHandler(body: string, type: string) -> function
    // **A WEAK validator, deliberately.** `slate:http` compresses a response on the way out with
    // whichever of zstd and brotli the client takes, so the bytes on the wire are not one sequence and
    // RFC 9110 reserves a strong tag for exactly that. `If-None-Match` compares weakly in any case, so
    // a client that sends this back is answered `304` whichever encoding it was given.
    val tag = "W/\"" + base64urlEncode(sha256(body)) + "\""

    inner(req)
        if fresh(req.headers["if-none-match"] ?? null, tag)
            return { status: 304, headers: { "Cache-Control": Forever, ETag: tag }, body: "" }

        // **A new headers object every time**, because a guard above this one writes into the
        // response it is handed -- `rateLimit` adds `Retry-After` that way -- and one shared object
        // would carry the first request's headers into every later one.
        { status: 200, headers: { "Content-Type": type, "Cache-Control": Forever, ETag: tag }, body: body }

    inner

// Whether `If-None-Match` names this tag: `*`, or any entry of the list equal to it under the WEAK
// comparison RFC 9110 gives this header -- the `W/` ignored on both sides.
fresh(said, tag: string) -> boolean
    if !(said is string) then return false

    val ours = opaque(tag)

    for entry in said.split(",")
        val one = entry.trim()

        if one == "*" || opaque(one) == ours then return true

    false

opaque(tag: string) -> string = if tag.startsWith("W/") then tag[2..] else tag
