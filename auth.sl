// Signing in, staying signed in, and being allowed: `login`, `logout`, `signedIn`, `remember` and
// `can`.
//
// **NOTHING HERE IS A SECOND SESSION.** Who is signed in is one member of the session `session(…)`
// already keeps -- `{ user: id }` -- so the cookie, the signing, the store, the expiry and the rotation
// that closes fixation are all that guard's, and this file only says what the member means. A program
// that keeps its sessions in a signed cookie and one that keeps them in redis sign people in the same
// way.
//
// **A refusal is a value somebody returned**, which is this package's rule everywhere: `signedIn`
// answers a `401` problem, a redirect, or whatever the application asked it to answer -- one of its
// own failure variants included -- and `can` answers a `403` or the policy's own refusal. Either goes
// through `api.failures` exactly as a handler's failure does.

import { randomBytes, sha256, timingSafeEqual } from slate:crypto
import { setCookie } from slate:http
import { epochMillis, now } from slate:time
import { base64urlEncode } from slate:url

import { guard, labelOf } from "./guards.sl"
import { problemResponse, withHeaders } from "./response.sl"
import { cookieOptions } from "./sessions.sl"

// -- signing in ------------------------------------------------------------------------------------

// `login(req, user, options)` -- sign `user` in on the session this request carries.
//
// **Only an id is kept**: `idOf(user)` -- `user.id` unless the application says otherwise -- goes into
// the session as `{ user: id }`, and `signedIn` asks the application's `load` for the user again on
// every request. A record copied into a session is a record that goes stale the moment somebody edits
// it, and in a signed cookie it is also a record the browser carries about.
//
// **LOGGING IN STARTS A FRESH SESSION RATHER THAN ADDING TO THE ONE THERE WAS**, which is half of what
// closes fixation: whatever was in the session before the login -- planted or not -- is not in the one
// the user is signed in under. The other half is the session guard's own: a store mints a new id on
// every `set` and deletes the old one, and a signed cookie is a new cookie. A program that wants
// something to survive a login (where to go back to, say) reads it before calling this and carries it
// across itself.
//
// **Nothing is written here.** Like `req.session.set`, this marks what the guards below the handler
// write once the handler has answered, so a handler that faults after calling it has signed nobody in.
export signIn(req: object, user, options: object = {}) -> null
    val idOf = options.idOf ?? defaultIdOf
    val id = idOf(user)

    // **An id of `null` is the program's own mistake**: it would be a session nobody is signed in to,
    // written as though somebody were.
    if id == null then throw "`login`'s `idOf` answered null -- a signed-in user needs an id"

    sessionOf(req, "login").set({ user: id })

    // **A login always settles the remember-me cookie, one way or the other.** One asked for is
    // issued; one not asked for is forgotten, so a token left by whoever used this browser before
    // cannot sign THEM back in when this session ends.
    if has(req, "remember")
        if options.remember ?? false then req.remember.issue(id) else req.remember.forget()
    else if options.remember ?? false
        throw "`login(req, user, { remember: true })` needs the `remember` guard between `session` and the handler"

    null

defaultIdOf(user) = if user is object && has(user, "id") then user.id else null

// `logout(req)` -- end the session, and the remember-me token with it where there is one.
//
// **`destroy()` revokes rather than forgets** where the session is in a store, which is the session
// guard's own rule; a signed cookie is cleared and stays good wherever it was copied until it expires,
// which is the cost of holding nothing that the README states under *Sessions*.
export signOut(req: object) -> null
    sessionOf(req, "logout").destroy()

    if has(req, "remember") then req.remember.forget()

    null

// The session on a request, or a fault naming what was missing.
//
// **A route that signs people in with no session guard above it is a program that was put together
// wrong**, and every request to it would be refused for a reason no client could do anything about --
// so it is a fault and not a `401`.
sessionOf(req: object, what: string) -> object
    if !has(req, "session")
        throw "`" + what + "` needs the `session` guard above it -- there is no `req.session` on this request"

    req.session

// Who the session says is signed in, or `null`.
//
// **A value that is not `{ user: … }` is nobody**, so a session an application keeps for something
// else entirely -- a cart, a theme -- reads as no one signed in rather than as a fault.
export signedInId(value)
    if value is object && has(value, "user") then value.user else null

// -- the guard -------------------------------------------------------------------------------------

// `signedIn(load, options)` -- the user the session names, on `req.user`, or a refusal.
//
// **`load(id)` is the application's**, may answer a promise, and answers the user or `null` -- for a
// user who has been deleted since they signed in, or banned, or whatever else the application means by
// gone. **A `null` from it ends the session as well as refusing**, so a deleted user's cookie stops
// costing a lookup on every request.
//
// | option | |
// |---|---|
// | `redirect` | a path: a refusal is a `303` there rather than a problem -- what a page wants |
// | `refuse` | a value to answer instead, typically one of the application's own failure variants |
//
// **`refuse` is answered exactly as given**, so a `Failure` variant goes through `api.failures` like
// any guard's failure and the exhaustiveness check covers it. With neither, the refusal is a `401`
// problem document.
export signedInGuard(load: function, options: object = {}) -> object =
    guard("signedIn", (h) -> loading(load, options, h))

loading(load: function, options: object, h)
    async inner(req)
        val session = sessionOf(req, "signedIn")
        val id = signedInId(session.value)

        if id == null then return refused(req, options)

        val user = await load(id)

        if user == null
            session.destroy()

            return refused(req, options)

        await h(req with { user: user })

    inner

// What a refusal is, by what the route asked for.
//
// **`303 See Other` and not `302`**, because what a browser is being told is "go and GET this other
// thing", whatever method the refused request used -- which is what 303 means and what 302 only
// usually does.
//
// **The `401` carries no `WWW-Authenticate`**, unlike `bearer`'s. There is no registered scheme for "a
// cookie the server set", and inventing one would be a header no client can act on; the problem
// document is what says what happened.
refused(req: object, options: object)
    if has(options, "refuse") then return options.refuse

    if has(options, "redirect")
        return { status: 303, headers: { Location: options.redirect }, body: "" }

    problemResponse(401, "Unauthorized", "this needs somebody signed in", { instance: req.path })

// -- remember me -----------------------------------------------------------------------------------

// `remember(store, options)` -- a long-lived cookie that signs its holder back in once the session has
// gone, on `req.remember` as `{ issue(id), forget() }` for `login` and `logout` to use.
//
// **The scheme is the split token** -- a SELECTOR the server looks the token up by and a VALIDATOR it
// checks, with only a hash of the validator stored -- after Paragon Initiative's *Implementing Secure
// User Authentication in PHP Applications with Long-Term Persistence* (2015), and the rotation and the
// theft rule after Barry Jaspan's *Improved Persistent Login Cookie Best Practice* (2006):
//
// - **a store leak signs nobody in**, because what it holds is a SHA-256 of 256 random bits and not
//   the bits;
// - **the lookup is not a comparison**, the selector being an index that says nothing, and the one
//   comparison there is is `timingSafeEqual` over the validator's hash;
// - **a token is rotated every time it is used**, the selector staying and the validator changing --
//   so the selector names a SERIES of tokens of which only the newest is good;
// - **a good selector with a stale validator is theft.** Somebody used this series after the cookie
//   presented here was issued, and the only way to have it is to have copied it: the whole series is
//   deleted, which signs out the thief and the victim alike, and `onTheft(userId)` is called so the
//   application can end that user's sessions too -- a store of three functions cannot list them.
//
// **It runs between `session` and `signedIn`**, and does nothing at all for a request whose session
// already names somebody: the token is for when the session has gone, and is checked then and only
// then.
//
// | option | |
// |---|---|
// | `name` | the cookie's (`"remember"`) |
// | `maxAge` | how long a token lives, in seconds -- 30 days by default -- renewed on every use |
// | `onTheft` | called with the user id when a stale validator is presented; may answer a promise |
// | `now` | a clock answering milliseconds since the epoch |
//
// and every cookie attribute `session` takes, with the same safe defaults.
export rememberGuard(store: object, options: object = {}) -> object =
    guard("remember", (h) -> remembering(store, options, h))

val ThirtyDays = 30 * 24 * 60 * 60

remembering(store: object, options: object, h)
    val name = options.name ?? "remember"
    val lifetime = options.maxAge ?? ThirtyDays
    val clock = options.now ?? systemClock

    async inner(req)
        val session = sessionOf(req, "remember")
        val held = splitToken(req.cookies[name] ?? null)

        // **What this request's response has to do about the cookie**, decided by the token and then
        // by the handler. `keep` writes nothing; the others are written AFTER the handler has
        // answered, so a handler that faults leaves the store as the token found it.
        val cell = { act: "keep", user: null }

        var signedInAs = session

        if held != null && signedInId(session.value) == null
            val entry = await store.get(held.selector)

            if entry == null
                // A series that has gone -- expired, forgotten, or ended by a theft -- and a cookie
                // still naming it. Clearing it is all there is to do.
                cell.act = "clear"
            else if !timingSafeEqual(toBytes(digestOf(held.validator)), toBytes(entry.hash))
                await store.delete(held.selector)

                if has(options, "onTheft") then await options.onTheft(entry.user)

                cell.act = "clear"
            else if entry.until <= clock()
                await store.delete(held.selector)

                cell.act = "clear"
            else
                cell.act = "rotate"
                cell.user = entry.user

                // **The token signs its holder in through the session**, so everything below this
                // guard -- `signedIn` included -- sees an ordinary signed-in session, and the session
                // cookie is written on the way out like any other login's.
                session.set({ user: entry.user })

                signedInAs = session with { value: { user: entry.user } }

        issue(id)
            cell.act = "issue"
            cell.user = id

            null

        forget()
            cell.act = "forget"

            null

        val reply = await h(req with { session: signedInAs, remember: { issue: issue, forget: forget } })

        if cell.act == "keep" then return reply

        val cookie = await settled(store, name, lifetime, clock, options, req, held, cell)

        withHeaders(reply, { "Set-Cookie": cookie })

    inner

// The store write a decision means, and the cookie line that goes with it.
//
// **A rotation keeps the selector and an issue mints one**, which is the whole difference between
// "the same series, one step on" and "a new series": the theft rule only means anything if a series
// lives as long as the browser keeps presenting it.
async settled(store: object, name: string, lifetime: integer, clock: function, options: object,
              req: object, held, cell: object) -> string
    if cell.act == "clear" then return cleared(name, options, req)

    if cell.act == "forget"
        if held != null then await store.delete(held.selector)

        return cleared(name, options, req)

    if cell.act == "issue" && held != null then await store.delete(held.selector)

    val selector = if cell.act == "rotate" then held.selector else base64urlEncode(randomBytes(12))

    // **256 bits of the operating system's randomness**, of which the store keeps only a SHA-256.
    val validator = base64urlEncode(randomBytes(32))

    await store.set(selector,
                    { user: cell.user, hash: digestOf(validator), until: clock() + lifetime * 1000 },
                    lifetime * 1000)

    setCookie(name, selector + "." + validator, rememberCookie(options, req) with { maxAge: lifetime })

cleared(name: string, options: object, req: object) -> string =
    setCookie(name, "", rememberCookie(options, req) with { maxAge: 0 })

// The cookie attributes, which are the session's -- `HttpOnly`, `SameSite=Lax`, `Path=/`, `Secure`
// over https -- less this guard's own options.
rememberCookie(options: object, req: object) -> object =
    cookieOptions(without(without(options, "onTheft"), "now"), req)

// `selector.validator`, or `null` for anything that is not one.
//
// **A cookie arrives from a client**, so text of the wrong shape is one more way of being nobody and
// never a fault.
export splitToken(raw)
    if raw == null || raw is not string then return null

    val at = indexOf(raw, ".")

    if at == null || at == 0 || at == raw.length - 1 then return null

    { selector: raw[0..<at], validator: raw[(at + 1)..] }

// What the store keeps in place of a validator.
export digestOf(validator: string) -> string = base64urlEncode(sha256(validator))

export systemClock() -> integer = epochMillis(now())

// -- authorization ---------------------------------------------------------------------------------

// `policy(name, check)` -- a policy that prints under a name in `api.routes()`.
//
// **A slate function knows no name of its own**, so `can(isOwner)` can only print as `can`; a policy
// made here is a callable object with a `label`, which is exactly what a guard is, and prints as
// `can(isOwner)`.
export namedPolicy(name: string, check: function) -> object = { new: check, label: name }

// `can(policy)` -- the handler, where `policy(req)` says so.
//
// **`policy(req)` answers one of three things**, and may answer a promise of it:
//
// - `true` -- go on;
// - `false` -- a `403` problem;
// - **anything else is the refusal itself**, answered as it is: one of the application's own failure
//   variants, which `api.failures` maps like any guard's failure and the exhaustiveness check covers,
//   or a response the policy built.
//
// **`null` is none of those and is a fault**, being what a policy that forgot to answer answers --
// refusing on it would turn a defect into every client being told it may not.
export canGuard(check) -> object
    val label = if check is object && has(check, "label") then "can(" + labelOf(check) + ")" else "can"

    guard(label, (h) -> allowing(check, h))

allowing(check, h)
    async inner(req)
        val said = await check(req)

        if said == true then return await h(req)

        if said == false
            return problemResponse(403, "Forbidden", "this is not yours to do", { instance: req.path })

        if said == null
            throw "a `can` policy answers true, false, or the refusal to answer -- and this one answered null"

        said

    inner
