// Signed cookie sessions, the store one may be kept in, and the CSRF token that goes with them.
//
// **WITH NO STORE THE SESSION IS THE DATA, SIGNED.** Nothing is held anywhere: the value travels in
// the cookie, an HMAC over it says nobody changed it, and the server keeps not a byte. That is the
// default and it is what a small service wants -- no backing thing to run, nothing to fall over, and
// a handler that reads a session touches no I/O at all.
//
// **What that costs is written down rather than discovered.** A cookie is about 4 KB, so a session is
// a handful of fields and not a shopping basket; and there is no revocation -- a signed cookie is
// good until it expires, so `maxAge` is the only way to end one early and a password change does not
// log anybody out.
//
// **WITH A STORE THE COOKIE CARRIES ONLY A SIGNED, OPAQUE ID** and the value lives under it, which is
// what buys both back: revocation is a `delete` and the session may be any size. The two modes are
// one guard and one cookie format -- the payload is `{ v, e }` signed either way, and `v` is the
// session in one and its id in the other -- so everything already written against `req.session` is
// unchanged, and `store.sl` says what a store is.
//
// **THE SIGNATURE AND THE STORED ID ARE BASE64URL**, which is `slate:url`'s from slate 0.0.29 and was
// hex before it: a digest is 43 characters rather than 64 and an id 24 rather than 36, on a cookie
// that `setCookie` percent-encodes anyway. The alphabet is the one a cookie carries unescaped, so
// the saving is real rather than swallowed by the encoding.
//
// **A COOKIE WRITTEN BY THE HEX SPELLING IS NOBODY TO THIS ONE**, which is what adopting it costs:
// the digest a client is holding is not the digest this reader makes of the payload, so every
// session and every login written by a server before this reads as a client with no cookie at all.
// That is the ordinary way of being nobody and not a failure -- the reader answers `null`, the
// handler is told there is nobody logged in, and the next login writes the new spelling.

import { hmac, randomBytes, timingSafeEqual } from slate:crypto
import { setCookie } from slate:http
import { epochMillis, now } from slate:time
import { base64urlEncode, base64urlDecode } from slate:url

import { guard } from "./guards.sl"
import { problemResponse, withHeaders } from "./response.sl"

// -- sessions --------------------------------------------------------------------------------------

// `session(secret)` -- read a signed cookie in, and write one back where the handler set it.
//
// A handler is given `req.session`, which is `{ value, set, destroy }`:
//
//     login(req)
//         req.session.set({ user: req.body.name })
//
//         json({ ok: true })
//
// **`value` is `null` where there was no cookie, where it was tampered with, and where it expired**,
// which are one thing to a handler: there is nobody logged in. Telling them apart would hand a client
// the difference between "no cookie" and "a bad signature", which is a thing to know only if you are
// forging one. **A store adds two more ways of being nobody** -- an id it never had, and one that was
// revoked -- and they are the same thing again.
//
// **The cookie is written only where `set` was called**, so an ordinary request that reads a session
// and answers carries no `Set-Cookie` at all -- no cache churn, and no cookie on every response in a
// log. `set(null)` clears it, and `destroy()` is that with a name.
export sessionGuard(secret: string, options: object = {}) -> object =
    guard("session", (h) -> sessioned(secret, options, h))

sessioned(secret: string, options: object, h)
    val name = options.name ?? "session"
    val store = options.store ?? null

    async inner(req)
        // **A cookie that says nothing this secret signed is an empty payload**, which is the same
        // thing to everything below as a request that carried no cookie at all.
        val said = readSigned(secret, req.cookies[name] ?? null) ?? {}

        // **THE TWO MODES NAME WHAT THEY CARRY AND CANNOT READ EACH OTHER.** A payload says `v`, the
        // session itself, or `i`, an id into a store, and each mode reads its own member and nothing
        // else -- so a cookie from the other arrangement, well signed by the same secret, is nobody
        // rather than a session whose value is somebody's opaque id.
        var id = if store != null && has(said, "i") && said.i is string then said.i else null
        var held = if store == null && has(said, "v") then said.v else null

        if id != null
            held = await store.get(id)

            // **AN ID THE STORE NO LONGER KNOWS IS A DEAD ID, NOT ONE TO WRITE BACK TO.** Keeping it
            // would let a revoked id be brought back by the next `set` that happened to carry it.
            if held == null then id = null

        // **A cell rather than a mutated request**, which is this package's rule read where it is
        // hardest to follow: the request a guard hands on is a value, so what a handler changes is
        // something the guard is holding and reads afterwards.
        val cell = { held: held, wrote: false }

        set(v)
            cell.held = v
            cell.wrote = true

            null

        // **`destroy()` IS `set(null)` WITH A NAME AND NOT A SECOND PATH.** It reads as what logging
        // out is, and one code path means the store cannot be revoked in one of them and not the
        // other.
        destroy() = set(null)

        val reply = await h(req with { session: { value: held, set: set, destroy: destroy } })

        if !cell.wrote then return reply

        if store == null
            // **`null` is the only thing that clears a session**, so one may perfectly well be
            // `false` or `0`.
            val carried = if cell.held == null then null else { v: cell.held }

            return withHeaders(reply,
                { "Set-Cookie": signedCookie(secret, name, carried, options, req) })

        withHeaders(reply,
            { "Set-Cookie": await storedCookie(store, secret, name, id, cell.held, options, req) })

    inner

// The store write a `set` means, and the cookie that goes with it.
//
// **A SESSION THAT IS WRITTEN IS WRITTEN UNDER A NEW ID, AND THE OLD ID IS DELETED.** That is what
// closes session fixation: an id planted in somebody's browser before they logged in is not the id
// they are logged in under, so whoever planted it holds nothing. It costs a delete beside the set,
// which is why `set` is the only thing that writes -- an ordinary request reads the session and
// touches the store once.
//
// **Clearing revokes rather than merely forgetting.** `set(null)` deletes the entry and clears the
// cookie, so a logged-out session is gone from the server and not just from the browser.
async storedCookie(store: object, secret: string, name: string, id, held, options: object,
                   req: object) -> string
    if id != null then await store.delete(id)

    if held == null then return signedCookie(secret, name, null, options, req)

    // **144 bits of the operating system's randomness**, which is what makes an id unguessable and
    // is the only property it has: it says nothing, means nothing, and is worth nothing to anybody
    // holding it once the store has let it go.
    //
    // **18 bytes because base64url spends four characters on every three**, so an id that is a
    // multiple of three is 24 characters with nothing wasted and nothing to pad.
    val fresh = base64urlEncode(randomBytes(18))

    await store.set(fresh, held, ttlOf(options))

    signedCookie(secret, name, { i: fresh }, options, req)

// How long a stored session lives, in milliseconds, or `null` for an entry with no age of its own.
// **The same `maxAge` the cookie is given**, so the two cannot drift apart into a cookie pointing at
// an entry that has gone or an entry outliving every cookie that could reach it.
ttlOf(options: object) =
    if !has(options, "maxAge") then null else options.maxAge * 1000

// The `Set-Cookie` line for a payload that was signed, or for a session that was cleared.
//
// **Clearing is an empty value with `Max-Age=0`**, which is the only way HTTP has of saying it: there
// is no "delete this cookie" and a browser drops one whose age has run out.
signedCookie(secret: string, name: string, carried, options: object, req: object) -> string
    if carried == null then return setCookie(name, "", cookieOptions(options, req) with { maxAge: 0 })

    val payload = toJSON(carried with { e: expiryOf(options) })

    val digest = base64urlEncode(hmac("SHA-256", secret, payload))

    setCookie(name, payload + "." + digest, cookieOptions(options, req))

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

    // **`name` and `store` are this guard's own and everything else is the cookie's**, which is what
    // makes `options` one object rather than two: a member `setCookie` knows about is passed
    // straight through, so a cookie attribute this package has never heard of works on the day
    // `slate:http` grows it.
    for [k, v] in entries(options)
        if k != "name" && k != "store" then out[k] = v

    out

overHttps(req: object) -> boolean =
    (req.headers["x-forwarded-proto"] ?? "") == "https"

// What a cookie says, if it says anything this secret signed.
//
// **Every way of being wrong answers `null`**, and the order matters: the signature is checked before
// the JSON is parsed, so a payload nobody signed is never handed to the parser at all.
readSigned(secret: string, raw)
    if raw == null || raw is not string then return null

    // **The LAST dot, because JSON has dots in it.** `{"v":{"n":1.5}}` is an ordinary payload and
    // splitting on the first would cut it in half.
    val at = lastIndexOf(raw, ".")

    if at == null || at == 0 then return null

    val payload = raw[0..<at]

    // **A digest arrives from a client**, so text that is not base64url at all is a condition and
    // not a defect -- `base64urlDecode` answers a result for exactly that reason, and everything it
    // refuses is one more way of being nobody. **A digest of the wrong LENGTH is nobody too and
    // costs nothing to reach**: `timingSafeEqual` answers `false` for two byte strings of different
    // lengths rather than faulting, so the hex spelling this replaced -- 64 characters that are
    // every one of them base64url, decoding to 48 bytes -- is a failed comparison and not a fault.
    val said = base64urlDecode(raw[(at + 1)..])

    if !said.ok then return null
    if !timingSafeEqual(said.value, hmac("SHA-256", secret, payload)) then return null

    val parsed = parseJSON(payload)

    if !parsed.ok || parsed.value is not object then return null

    // A payload carries a session under `v` or an id under `i`, and one carrying neither is not a
    // payload of this package's however well it is signed.
    if !has(parsed.value, "v") && !has(parsed.value, "i") then return null

    val ends = parsed.value.e ?? null

    // **The cookie's own expiry is read before the store is asked**, so an expired session costs no
    // lookup and a store that has forgotten to expire an entry cannot resurrect one.
    if ends != null && epochMillis(now()) >= ends then return null

    parsed.value

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
// **It is stateless, which is what lets it pair with a session of either kind.** The
// synchroniser-token pattern is stronger and wants the token kept beside the session, which is
// something only the store mode could offer -- so it would be a guard that worked in one arrangement
// and not the other, where this one works in both.
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

        withHeaders(reply, { "Set-Cookie": setCookie(name, base64urlEncode(randomBytes(32)),
            { httpOnly: false, sameSite: "Lax", path: "/", secure: overHttps(req) }) })

    inner

contains(xs: array, v) -> boolean =
    for x in xs
        if x == v then return true

    false
