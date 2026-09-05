// Signed cookie sessions, and the CSRF token that goes with them.
//
// **A SESSION IS THE DATA, SIGNED, AND NOT AN IDENTIFIER INTO A STORE.** sluice has no storage of its
// own and no runtime dependency; a store needs a backing thing -- redis, a database, a file -- and
// that is a second design and a second package rather than a guard. What is here is self-contained:
// the value travels in the cookie, an HMAC over it says nobody changed it, and a server holds
// nothing at all.
//
// **What that costs is written down rather than discovered.** A cookie is about 4 KB, so a session
// is a handful of fields and not a shopping basket; and **there is no revocation** -- a signed cookie
// is good until it expires, so `maxAge` is the only way to end one early and a password change does
// not log anybody out. Where either matters, the answer is a store, and `session(secret, { store })`
// is the shape it would take without changing anything written against this.
//
// **The signature is HEX and not base64url**, which is a smaller decision than it looks: slate has no
// base64 a program can reach -- `slate:jwt` has one privately -- and 22 extra bytes on a cookie that
// `setCookie` percent-encodes anyway is cheaper than a fourth copy of an encoder.

import { hmac, randomBytes, timingSafeEqual } from slate:crypto
import { setCookie } from slate:http
import { epochMillis, now } from slate:time

import { guard } from "./guards.sl"
import { problemResponse, withHeaders } from "./response.sl"

// -- sessions --------------------------------------------------------------------------------------

// `session(secret)` -- read a signed cookie in, and write one back where the handler set it.
//
// A handler is given `req.session`, which is `{ value, set }`:
//
//     login(req)
//         req.session.set({ user: req.body.name })
//
//         json({ ok: true })
//
// **`value` is `null` where there was no cookie, where it was tampered with, and where it expired**,
// which are one thing to a handler: there is nobody logged in. Telling them apart would hand a client
// the difference between "no cookie" and "a bad signature", which is a thing to know only if you are
// forging one.
//
// **The cookie is written only where `set` was called**, so an ordinary request that reads a session
// and answers carries no `Set-Cookie` at all -- no cache churn, and no cookie on every response in a
// log. `set(null)` clears it.
export sessionGuard(secret: string, options: object = {}) -> object =
    guard("session", (h) -> sessioned(secret, options, h))

sessioned(secret: string, options: object, h)
    val name = options.name ?? "session"

    async inner(req)
        val held = readSession(secret, req.cookies[name] ?? null)

        // **A cell rather than a mutated request**, which is this package's rule read where it is
        // hardest to follow: the request a guard hands on is a value, so what a handler changes is
        // something the guard is holding and reads afterwards.
        val cell = { held: held, wrote: false }

        set(v)
            cell.held = v
            cell.wrote = true

            null

        val reply = await h(req with { session: { value: held, set: set } })

        if !cell.wrote then return reply

        withHeaders(reply, { "Set-Cookie": sessionCookie(secret, name, cell.held, options, req) })

    inner

// The `Set-Cookie` line for a session that was set, or for one that was cleared.
//
// **Clearing is an empty value with `Max-Age=0`**, which is the only way HTTP has of saying it: there
// is no "delete this cookie" and a browser drops one whose age has run out.
sessionCookie(secret: string, name: string, held, options: object, req: object) -> string
    if held == null then return setCookie(name, "", cookieOptions(options, req) with { maxAge: 0 })

    val payload = toJSON({ v: held, e: expiryOf(options) })

    setCookie(name, payload + "." + hex(hmac("SHA-256", secret, payload)), cookieOptions(options, req))

// When this session stops being valid, as milliseconds from the epoch, or `null` for one that lasts
// as long as the browser is open.
expiryOf(options: object) =
    if !has(options, "maxAge") then null else epochMillis(now()) + options.maxAge * 1000

// **The defaults are the safe ones and every one of them is overridable.** `HttpOnly` keeps the
// session out of reach of any script on the page, which is what makes stealing it a matter of
// stealing the browser; `SameSite=Lax` is what stops another site's form posting with it, and is the
// first line against CSRF rather than the token below; `Path=/` because a cookie with no path is
// scoped to the directory of the request that set it, which is almost never meant.
//
// **`Secure` follows the REQUEST rather than being on always**, because a session that refused to
// work over `http://localhost` would be a session nobody could develop against -- and a server
// behind a proxy reads `x-forwarded-proto`, which is the header that carries the answer.
cookieOptions(options: object, req: object) -> object
    var out = { httpOnly: true, sameSite: "Lax", path: "/", secure: overHttps(req) }

    for [k, v] in entries(options)
        if k != "name" then out[k] = v

    out

overHttps(req: object) -> boolean =
    (req.headers["x-forwarded-proto"] ?? "") == "https"

// What a cookie says, if it says anything this secret signed.
//
// **Every way of being wrong answers `null`**, and the order matters: the signature is checked before
// the JSON is parsed, so a payload nobody signed is never handed to the parser at all.
readSession(secret: string, raw)
    if raw == null || raw is not string then return null

    // **The LAST dot, because JSON has dots in it.** `{"v":{"n":1.5}}` is an ordinary payload and
    // splitting on the first would cut it in half.
    val at = lastIndexOf(raw, ".")

    if at == null || at == 0 then return null

    val payload = raw[0..<at]
    val said = unhex(raw[(at + 1)..])

    if said == null then return null
    if !timingSafeEqual(said, hmac("SHA-256", secret, payload)) then return null

    val parsed = parseJSON(payload)

    if !parsed.ok || parsed.value is not object then return null
    if !has(parsed.value, "v") then return null

    val ends = parsed.value.e ?? null

    if ends != null && epochMillis(now()) >= ends then return null

    parsed.value.v

// -- CSRF ------------------------------------------------------------------------------------------

// The methods that are allowed to change something, and therefore the ones a token is asked for.
val Unsafe = ["POST", "PUT", "PATCH", "DELETE"]

// `csrf()` -- the double-submit cookie.
//
// **A random value in a cookie that scripts CAN read, and the same value required in a header.** A
// form posted from another site carries the cookie -- browsers send those -- and cannot read it to
// put in a header, because reading it needs script running on this origin. That is the whole of the
// argument, and it is why this one cookie is deliberately not `HttpOnly`.
//
// **`SameSite=Lax` on the session is the first line and this is depth.** A browser that honours it
// does not send the session with a cross-site POST at all; the token is what covers the browsers and
// the cases that do.
//
// **It is stateless, which is what lets it pair with a stateless session.** The synchroniser-token
// pattern is stronger and wants somewhere to keep the token, which is the store this package does
// not have.
export csrfGuard(options: object = {}) -> object =
    guard("csrf", (h) -> checked(options, h))

checked(options: object, h)
    val name = options.name ?? "csrf"
    val header = (options.header ?? "x-csrf-token").lower()

    async inner(req)
        val held = req.cookies[name] ?? null

        if contains(Unsafe, req.method.upper())
            val sent = req.headers[header] ?? null

            if held == null || sent == null
                return problemResponse(403, "Forbidden",
                    "this request needs a `" + header + "` header matching the `" + name + "` cookie",
                    { instance: req.path })

            if !timingSafeEqual(toBytes(held), toBytes(sent))
                return problemResponse(403, "Forbidden",
                    "the `" + header + "` header does not match the `" + name + "` cookie",
                    { instance: req.path })

        val reply = await h(req)

        // **A token is issued where there is none**, so the first safe request a client makes hands
        // it what the next unsafe one will need. Reissuing on every response would change the token
        // under a page that had already read it.
        if held != null then return reply

        withHeaders(reply, { "Set-Cookie": setCookie(name, hex(randomBytes(32)),
            { httpOnly: false, sameSite: "Lax", path: "/", secure: overHttps(req) }) })

    inner

contains(xs: array, v) -> boolean =
    for x in xs
        if x == v then return true

    false

// -- hex -------------------------------------------------------------------------------------------

val Digits = "0123456789abcdef"

// Bytes as hex. **Written here because slate has no base64 a program can reach** and a signature has
// to survive a cookie, which is text.
hex(bytes: array) -> string
    var out = ""

    for b in bytes
        out = out + Digits[(b / 16)..<(b / 16 + 1)] + Digits[(b % 16)..<(b % 16 + 1)]

    out

// Hex back to bytes, or `null` for anything that is not hex. **A signature arrives from a client**,
// so this answers rather than faulting: text from outside the program is a condition and not a
// defect.
unhex(s: string)
    if len(s) % 2 != 0 then return null

    var out = []
    var i = 0

    while i < len(s)
        val hi = nibble(s[i..<(i + 1)])
        val lo = nibble(s[(i + 1)..<(i + 2)])

        if hi < 0 || lo < 0 then return null

        push(out, hi * 16 + lo)

        i = i + 2

    out

nibble(c: string) -> integer =
    val at = indexOf(Digits, c.lower())

    if at == null then 0 - 1 else at
