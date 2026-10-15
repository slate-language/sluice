// Flash messages, and redirecting back to where a form came from.
//
// **Both are for a page with forms on it**, where a refused post is answered by sending the browser
// back to the form with the reasons and what was typed -- and the next request, not this one, is the
// one that shows them.

import { guard, headerOf } from "./guards.sl"

// The member of the session value the messages travel in.
val FlashKey = "_flash"

// `flash()` -- one-request messages on `req.flash`, carried to the next request in the session.
//
// `req.flash` is `{ messages, set(key, value) }`: `messages` is what the PREVIOUS request set, and
// `set` is what the next one will see. **A message lasts exactly one request**: whatever arrived is
// taken out of the session on the way through, whether anything read it or not, so a page reloaded
// does not say "saved" twice.
//
// **It is a guard over the session and not a second cookie**, so it goes under `session` and the
// messages are signed, stored, rotated and destroyed with everything else in it. What a handler sees
// as `req.session.value` is the session WITHOUT the messages, so a `login` that replaces the value
// and a `signedIn` that reads `user` from it are untouched -- and a message set on the same request
// as a `login` or a `logout` still arrives.
export flashGuard() -> object = guard("flash", (h) -> flashing(h))

flashing(h)
    async inner(req)
        if !has(req, "session")
            throw "`flash` needs the `session` guard above it -- there is no `req.session` on this request"

        val session = req.session
        val held = session.value
        val carried = held is object && has(held, FlashKey)
        val arrived = if carried && held[FlashKey] is object then held[FlashKey] else {}
        val shown = if carried then unflashed(held) else held

        // **A cell rather than a mutated request**, which is `session`'s own arrangement: what the
        // handler changes is held here and read once it has answered.
        val cell = { next: {}, value: shown, wrote: false }

        put(key: string, value)
            cell.next[key] = value

            null

        set(v)
            cell.value = v
            cell.wrote = true

            null

        destroy() = set(null)

        val reply = await h(req with { flash: { messages: arrived, set: put },
                                       session: { value: shown, set: set, destroy: destroy } })

        val leaving = keys(cell.next).length != 0

        // **Nothing to carry and nothing to take away is no write at all**, so an ordinary request
        // still answers with no `Set-Cookie`.
        if !carried && !leaving && !cell.wrote then return reply

        session.set(settled(cell, leaving))

        reply

    inner

// The session value with the messages taken off.
//
// **A session that held nothing but the messages is no session at all**, which is what it was before
// a message was put on it -- a visitor told "signed out" is still signed out, and the cookie that
// carried the message is cleared once it has been read rather than kept alive holding `{}`.
unflashed(held: object)
    val rest = without(held, FlashKey)

    if keys(rest).length == 0 then null else rest

// What the session holds once this request is done: the value the handler left, with the messages
// for the next request on it.
settled(cell: object, leaving: boolean)
    val base = cell.value

    if !leaving then return base

    if base == null then return { _flash: cell.next }

    if !(base is object)
        throw "`flash` keeps its messages in the session value, which has to be an object to hold them"

    base with { _flash: cell.next }

// `back(req, fallback)` -- a `303` to the page this request came from, or to `fallback`.
//
// **The `Referer` is followed only where it names THIS host**, and only its path and query are kept:
// a header a client wrote is not a place to send a browser, and an open redirect is how a phishing
// link borrows a trusted name. A `Referer` naming another origin, one that is not an absolute
// `http`/`https` URL, a request with no `Host`, and a path a browser would read as another host
// (`//evil.example`, `/\evil.example`) all go to `fallback`.
export goBack(req: object, fallback: string) -> object =
    { status: 303, headers: { Location: backTo(req) ?? fallback }, body: "" }

backTo(req: object) -> string | null
    val referer = headerOf(req, "referer")
    val host = headerOf(req, "host")

    if referer == null || host == null then return null

    val rest = afterScheme(referer)

    if rest == null then return null

    val slash = indexOf(rest, "/")
    val authority = if slash == null then rest else rest[0..<slash]

    if lower(authority) != lower(host) then return null

    var path = if slash == null then "/" else rest[slash..<rest.length]
    val hash = indexOf(path, "#")

    if hash != null then path = path[0..<hash]

    if startsWith(path, "//") || startsWith(path, "/\\") then null else path

// A URL with its `http://` or `https://` taken off, or `null` for anything else.
afterScheme(url: string) -> string | null
    val low = lower(url)

    if startsWith(low, "https://") then return url[8..<url.length]

    if startsWith(low, "http://") then return url[7..<url.length]

    null
