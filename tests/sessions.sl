// `session(secret)` and `csrf()` -- the cookie a server signs, and the token that goes with it.

import { percentDecode } from slate:http

import { api, session, csrf, json, memoryStore, request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

val Secret = "a secret nobody else has"

// An application that reads the session on `GET` and sets one on `POST`.
made(secret: string, options: object = {}) -> object
    val app = api()

    app.get("/me", session(secret, options, (req) -> json({ who: req.session.value })))
    app.post("/in", session(secret, options, (req) -> logIn(req)))
    app.post("/out", session(secret, options, (req) -> logOut(req)))
    app.post("/gone", session(secret, options, (req) -> destroyed(req)))

    app

// **The body is read here rather than through the `body` guard**, so that these tests are about the
// session and not about how a body arrives.
logIn(req: object) -> object
    req.session.set(parseJSON(req.body).value)

    json({ ok: true })

logOut(req: object) -> object
    req.session.set(null)

    json({ ok: true })

// The same thing said the other way. **`destroy()` is `set(null)` with a name**, and what a store
// turns it into is a `delete`.
destroyed(req: object) -> object
    req.session.destroy()

    json({ ok: true })

// A handler that sets a session without reading a body, for the routes that are not a login.
greeter(req: object) -> object
    req.session.set("ada")

    json({ ok: true })

// Every `Set-Cookie` on an answer, as a list -- one of them or several.
//
// **The value is a STRING for one and an ARRAY for two**, which is `slate:http`'s shape for a header
// that repeats, so reading it has to take both.
cookies(reply) -> array
    var out = []

    for [k, v] in entries(response(reply).headers)
        if lower(k) == "set-cookie"
            out = if v is array then v else [v]

    out

// The `name=value` part of a `Set-Cookie` line, which is what a browser would send back.
sent(line: string) -> string
    val at = indexOf(line, ";")

    if at == null then line else line[0..<at]

// The value out of one, as `req.cookies` would hold it.
//
// **DECODED, because that is what a server does.** `setCookie` percent-encodes what it writes and
// `parseCookies` decodes what it reads, so a test handing the raw text back to `request` would be
// testing a client nobody has.
valueOf(line: string) -> string
    val one = sent(line)
    val at = indexOf(one, "=")

    percentDecode(one[(at + 1)..], false)

// A session cookie made by logging in, ready to be sent back.
async signedIn(secret: string = Secret) -> string
    val r = await made(secret).handle(request("POST", "/in", { body: "\"ada\"" }))

    valueOf(cookies(r)[0])

@test
async A_SESSION_SET_BY_ONE_REQUEST_IS_READ_BY_THE_NEXT()
    // **The round trip, and it is the only thing that says the two halves agree.** The cookie is
    // signed by the writer and checked by the reader, and either half could be wrong on its own and
    // still look right.
    val back = await made(Secret).handle(
        request("GET", "/me", { cookies: { session: await signedIn() } }))

    assertEq(doc(back).who, "ada")

@test
async NO_COOKIE_AT_ALL_IS_NOBODY_AND_NOT_A_FAILURE()
    // A request with no session is the ordinary case, not an error: it is what everybody's first
    // request looks like.
    assertEq(doc(await made(Secret).handle(request("GET", "/me"))).who, null)

@test
async A_COOKIE_THIS_SECRET_DID_NOT_SIGN_IS_NOBODY()
    // **The whole point of signing.** The payload here is perfectly good JSON and says what a real
    // one says; what it does not have is a digest this secret would produce.
    val stolen = await signedIn("some other server's secret")
    val back = await made(Secret).handle(request("GET", "/me", { cookies: { session: stolen } }))

    assertEq(doc(back).who, null)

@test
async A_PAYLOAD_CHANGED_UNDER_A_GOOD_DIGEST_IS_NOBODY()
    // **Tampering, which is what an attacker actually tries**: take a cookie you were given, change
    // `"ada"` to `"root"`, and send it back with the digest it came with.
    val good = await signedIn()
    val bent = replace(good, "ada", "bob")

    assert(bent != good)

    val back = await made(Secret).handle(request("GET", "/me", { cookies: { session: bent } }))

    assertEq(doc(back).who, null)

@test
async A_DIGEST_THAT_IS_NOT_HEX_IS_NOBODY_RATHER_THAN_A_FAULT()
    // A cookie arrives from outside the program, so nonsense in it is a condition and not a defect.
    // These are the shapes that would reach the decoder rather than being turned away by its length.
    for bad in ["{\"v\":1}.zz", "{\"v\":1}.abc", "{\"v\":1}.", "nodigest", "", "."]
        val back = await made(Secret).handle(request("GET", "/me", { cookies: { session: bad } }))

        assertEq(doc(back).who, null)

@test
async A_SESSION_PAST_ITS_maxAge_IS_NOBODY()
    // **The only revocation a signed cookie has**, which is why the doc says so: a server holds
    // nothing, so a session ends when it says it ends and not when anybody decides.
    val stale = await signedIn()
    val expired = await made(Secret, { maxAge: 0 - 1 }).handle(
        request("POST", "/in", { body: "\"ada\"" }))
    val cooked = valueOf(cookies(expired)[0])
    val back = await made(Secret).handle(request("GET", "/me", { cookies: { session: cooked } }))

    assertEq(doc(back).who, null)

    // And the control: the same application, a session that has not expired.
    assertEq(doc(await made(Secret).handle(
        request("GET", "/me", { cookies: { session: stale } }))).who, "ada")

@test
async A_REQUEST_THAT_ONLY_READS_A_SESSION_WRITES_NO_COOKIE()
    // **The cookie is written only where `set` was called.** Otherwise every response in a log
    // carries one and every cache has to think about it.
    assertEq(len(cookies(await made(Secret).handle(request("GET", "/me")))), 0)

@test
async CLEARING_A_SESSION_IS_AN_EMPTY_COOKIE_WITH_NO_AGE_LEFT()
    // There is no "delete this cookie" in HTTP. A browser drops one whose age has run out, so that
    // is what logging out is.
    val out = cookies(await made(Secret).handle(request("POST", "/out")))[0]

    assert(contains(out, "session=;") || contains(out, "session="))
    assert(contains(out, "Max-Age=0"))

@test
async THE_DEFAULTS_ARE_THE_SAFE_ONES_AND_EVERY_ONE_IS_OVERRIDABLE()
    val plain = cookies(await made(Secret).handle(request("POST", "/in", { body: "1" })))[0]

    assert(contains(plain, "HttpOnly"))
    assert(contains(plain, "SameSite=Lax"))
    assert(contains(plain, "Path=/"))

    // **`Secure` follows the request**, or a session would not work over `http://localhost` and
    // nobody could develop against one.
    assert(!contains(plain, "Secure"))

    val safe = cookies(await made(Secret).handle(
        request("POST", "/in", { body: "1", headers: { "x-forwarded-proto": "https" } })))[0]

    assert(contains(safe, "Secure"))

    val named = cookies(await made(Secret, { name: "sid", sameSite: "Strict" }).handle(
        request("POST", "/in", { body: "1" })))[0]

    assert(contains(named, "sid="))
    assert(contains(named, "SameSite=Strict"))

// -- two cookies in one response --------------------------------------------------------------------

@test
async A_SESSION_AND_A_CSRF_TOKEN_IN_ONE_RESPONSE_ARE_TWO_COOKIES()
    // **The defect this found**: `withHeaders` merged headers by name, so the second `Set-Cookie`
    // replaced the first and one of them was silently gone -- and a login that sets a session and a
    // token together is the first thing anybody writes. `slate:http` takes an array for a name that
    // repeats, which is the shape 0.0.27 gave it for exactly this.
    // **A GET, so that both guards write.** A `POST` with no token is a `403` before either of them
    // gets that far, which is the CSRF guard doing its job and not the case under test here.
    val app = api()

    app.get("/in", csrf({}, session(Secret, {}, greeter)))

    val two = cookies(await app.handle(request("GET", "/in")))

    assertEq(len(two), 2)
    assert(contains(two[0], "session=") || contains(two[1], "session="))
    assert(contains(two[0], "csrf=") || contains(two[1], "csrf="))

// -- CSRF ---------------------------------------------------------------------------------------

guarded(options: object = {}) -> object
    val app = api()

    app.get("/read", csrf(options, (req) -> "read"))
    app.post("/write", csrf(options, (req) -> "written"))

    app

@test
async A_SAFE_REQUEST_WITH_NO_TOKEN_IS_ISSUED_ONE()
    // The first safe request a client makes hands it what its next unsafe one will need.
    val r = await guarded().handle(request("GET", "/read"))
    val one = cookies(r)[0]

    assertEq(status(r), 200)
    assert(contains(one, "csrf="))

    // **This is the one cookie that is deliberately NOT `HttpOnly`**, and the whole double-submit
    // argument rests on it: a page has to be able to read this to put it in a header, and another
    // site's page cannot.
    assert(!contains(one, "HttpOnly"))

@test
async A_CLIENT_THAT_ALREADY_HAS_A_TOKEN_IS_NOT_GIVEN_A_NEW_ONE()
    // Reissuing on every response would change the token under a page that had already read it.
    assertEq(len(cookies(await guarded().handle(
        request("GET", "/read", { cookies: { csrf: "abc" } })))), 0)

@test
async AN_UNSAFE_REQUEST_CARRYING_BOTH_AND_MATCHING_GOES_THROUGH()
    val r = await guarded().handle(request("POST", "/write",
        { cookies: { csrf: "abc" }, headers: { "x-csrf-token": "abc" } }))

    assertEq(await r, "written")

@test
async AN_UNSAFE_REQUEST_WITH_NO_TOKEN_IS_A_403_PROBLEM()
    for missing in [request("POST", "/write"),
                    request("POST", "/write", { cookies: { csrf: "abc" } }),
                    request("POST", "/write", { headers: { "x-csrf-token": "abc" } })]
        val r = await guarded().handle(missing)

        assertEq(status(r), 403)
        assertEq(header(r, "content-type"), "application/problem+json")
        assertEq(doc(r).title, "Forbidden")

@test
async AN_UNSAFE_REQUEST_WHOSE_TOKEN_DOES_NOT_MATCH_IS_A_403_PROBLEM()
    val r = await guarded().handle(request("POST", "/write",
        { cookies: { csrf: "abc" }, headers: { "x-csrf-token": "abd" } }))

    assertEq(status(r), 403)
    assert(contains(doc(r).detail, "does not match"))

@test
async A_PREFIX_OF_A_GOOD_TOKEN_IS_REFUSED()
    // A prefix is what an attacker guessing a token a byte at a time sends, so it is worth pinning
    // that a shorter value is not somehow a match.
    //
    // **THE SUBSTITUTION OF `==` FOR `timingSafeEqual` IS NOT OBSERVABLE HERE AND NO TEST CAN CATCH
    // IT, WHICH IS WORTH SAYING RATHER THAN PRETENDING OTHERWISE.** It was tried: swapping the
    // comparison for `held != sent` leaves all 99 tests green, and it has to -- the two agree on
    // every ANSWER and differ only in how long they take to give it. What `timingSafeEqual` buys is
    // that the time does not depend on how much of a forged token was right, and a suite cannot see
    // time. `slate:crypto`'s own doc makes the same point from the other side.
    //
    // So the control that DOES work is the one the tampering tests run: replace the digest with
    // anything constant and this file goes red in four places.
    val r = await guarded().handle(request("POST", "/write",
        { cookies: { csrf: "abcdef" }, headers: { "x-csrf-token": "abcde" } }))

    assertEq(status(r), 403)

@test
async EVERY_METHOD_THAT_CHANGES_SOMETHING_IS_GUARDED_AND_THE_SAFE_ONES_ARE_NOT()
    // **A list nobody has to remember**: the check is on the method, so a route added later gets it
    // without anybody thinking about it. `GET` and `HEAD` change nothing, by the specification.
    val app = api()

    app.post("/thing", csrf({}, (req) -> "did it"))
    app.put("/thing", csrf({}, (req) -> "did it"))
    app.patch("/thing", csrf({}, (req) -> "did it"))
    app.delete("/thing", csrf({}, (req) -> "did it"))

    for m in ["POST", "PUT", "PATCH", "DELETE"]
        assertEq(status(await app.handle(request(m, "/thing"))), 403)

    // And the safe ones are not guarded: a `GET` with no token answers, and is issued one.
    val open = api()

    open.get("/thing", csrf({}, (req) -> "did it"))

    // **The answer is an ENVELOPE and not the bare string**, the guard having put a token on it --
    // which is what `response` is for and why the suite reads answers through it.
    val issued = await open.handle(request("GET", "/thing"))

    assertEq(status(issued), 200)
    assertEq(response(issued).body, "did it")

@test
async THE_COOKIE_AND_THE_HEADER_ARE_BOTH_NAMEABLE()
    val app = api()

    app.post("/write", csrf({ name: "xsrf", header: "X-XSRF-Token" }, (req) -> "written"))

    assertEq(await app.handle(request("POST", "/write",
        { cookies: { xsrf: "abc" }, headers: { "x-xsrf-token": "abc" } })), "written")

    assertEq(status(await app.handle(request("POST", "/write",
        { cookies: { xsrf: "abc" }, headers: { "x-csrf-token": "abc" } }))), 403)

// -- a session in a store ----------------------------------------------------------------------------
//
// **The same guard, the same cookie format and the same `req.session`.** What changes is what the
// `v` member of the payload is: the session itself with no store, and an opaque id into one with.

// The cookie a login answers, ready to be sent back.
async cookieFrom(app: object, body: string = "\"ada\"") -> string
    val r = await app.handle(request("POST", "/in", { body: body }))

    valueOf(cookies(r)[0])

// What the signed payload of a cookie says, which is how a test reads what is actually in it.
payloadOf(raw: string) -> object
    val at = lastIndexOf(raw, ".")
    val parsed = parseJSON(raw[0..<at])

    if !parsed.ok then throw "that cookie carries no payload: " + raw

    parsed.value

// A store that counts what it was asked. **This is also the whole argument for the interface being
// three plain functions**: wrapping one is an object literal, with nothing to subclass and nothing to
// register.
counted(store: object) -> object
    val seen = { gets: 0 }

    async get(id: string)
        seen.gets = seen.gets + 1

        await store.get(id)

    { get: get, set: store.set, delete: store.delete, seen: seen, size: store.size }

@test
async A_STORED_SESSION_ROUND_TRIPS_AND_THE_COOKIE_CARRIES_ONLY_AN_ID()
    // **The round trip and the point of the mode in one test.** What comes back is the session; what
    // went out is an id, and the value is nowhere near the client.
    val store = memoryStore()
    val app = made(Secret, { store: store })
    val cookie = await cookieFrom(app)

    // **What went out is read as a payload and not searched for as a substring.** The id and the
    // digest are both hex, and `ada` is three hex digits -- so a search of the whole cookie for the
    // session's own value fails about once in forty runs on a cookie that is perfectly correct.
    assert(!has(payloadOf(cookie), "v"))
    assert(payloadOf(cookie).i is string)
    assertEq(store.size(), 1)

    val back = await app.handle(request("GET", "/me", { cookies: { session: cookie } }))

    assertEq(doc(back).who, "ada")

    // And reading one writes nothing: no cookie, and the entry that was there is the entry that is
    // there. A store mode that rewrote on every read would be a database write per request.
    assertEq(len(cookies(back)), 0)
    assertEq(store.size(), 1)

@test
async A_STORED_SESSION_MAY_BE_BIGGER_THAN_A_COOKIE()
    // **The other half of what a store buys.** A signed cookie is about 4 KB and this is 40, so the
    // limit stops being one a program has to think about.
    val store = memoryStore()
    val app = made(Secret, { store: store })
    val big = repeat("x", 40000)
    val cookie = await cookieFrom(app, toJSON(big))

    assert(len(cookie) < 200)

    val back = await app.handle(request("GET", "/me", { cookies: { session: cookie } }))

    assertEq(len(doc(back).who), 40000)

@test
async REVOKING_A_STORED_SESSION_IS_A_delete_AND_THE_COOKIE_IS_THEN_NOBODY()
    // **This is what a store is for.** The same cookie, unchanged and perfectly signed, stops being
    // anybody the moment the server says so -- which a signed cookie on its own cannot do at all.
    val store = memoryStore()
    val app = made(Secret, { store: store })
    val cookie = await cookieFrom(app)

    await store.delete(payloadOf(cookie).i)

    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, null)

@test
async destroy_REVOKES_IN_STORE_MODE_RATHER_THAN_MERELY_FORGETTING()
    val store = memoryStore()
    val app = made(Secret, { store: store })
    val cookie = await cookieFrom(app)

    val out = await app.handle(request("POST", "/gone", { cookies: { session: cookie } }))

    // The entry is gone from the server, and the cookie is cleared at the client.
    assertEq(store.size(), 0)
    assert(contains(cookies(out)[0], "Max-Age=0"))
    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, null)

@test
async destroy_WITH_NO_STORE_CLEARS_THE_COOKIE()
    // **Both modes answer the same call**, so a program that grows a store later changes one option
    // and nothing else.
    val out = await made(Secret).handle(
        request("POST", "/gone", { cookies: { session: await signedIn() } }))

    assert(contains(cookies(out)[0], "Max-Age=0"))

@test
async A_SESSION_THAT_IS_WRITTEN_IS_WRITTEN_UNDER_A_NEW_ID()
    // **Session fixation, which is the one attack a store can walk into.** An id planted in
    // somebody's browser before they log in must not be the id they are logged in under, or whoever
    // planted it is logged in too. So a `set` mints a new id and deletes the old one, and the store
    // does not grow a session per login.
    val store = memoryStore()
    val app = made(Secret, { store: store })
    val first = await cookieFrom(app)

    val second = valueOf(cookies(await app.handle(
        request("POST", "/in", { body: "\"ada\"", cookies: { session: first } })))[0])

    assert(payloadOf(first).i != payloadOf(second).i)
    assertEq(store.size(), 1)
    assertEq(await store.get(payloadOf(first).i), null)
    assertEq((await store.get(payloadOf(second).i)), "ada")

@test
async A_TAMPERED_ID_IS_NOBODY_AND_THE_STORE_IS_NEVER_ASKED()
    // **The signature is checked before the store is**, which is what stops a client sending a
    // million guesses at an id and making the server look every one of them up.
    val store = counted(memoryStore())
    val app = made(Secret, { store: store })
    val cookie = await cookieFrom(app)

    assertEq(store.seen.gets, 0)

    val bent = replace(cookie, payloadOf(cookie).i, repeat("0", len(payloadOf(cookie).i)))

    assert(bent != cookie)
    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: bent } }))).who, null)
    assertEq(store.seen.gets, 0)

    // And the control: the cookie it came from is read, and the store is asked exactly once.
    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, "ada")
    assertEq(store.seen.gets, 1)

@test
async A_WELL_SIGNED_ID_THE_STORE_DOES_NOT_HAVE_IS_NOBODY()
    // A server restarted with a memory store, or an entry that expired: the cookie is perfect and
    // there is nothing behind it.
    val app = made(Secret, { store: memoryStore() })
    val cookie = await cookieFrom(app)
    val elsewhere = made(Secret, { store: memoryStore() })

    assertEq(doc(await elsewhere.handle(
        request("GET", "/me", { cookies: { session: cookie } }))).who, null)

@test
async A_STORED_SESSION_PAST_ITS_TTL_IS_NOBODY()
    // **The store's own expiry, on the clock a test can move.** The cookie here has not expired --
    // that half is pinned above, and this is the entry going rather than the cookie.
    val clock = { at: 1000 }

    reading() -> integer = clock.at

    val store = memoryStore({ now: reading })
    val app = made(Secret, { store: store, maxAge: 60 })
    val cookie = await cookieFrom(app)

    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, "ada")

    clock.at = 1000 + 60 * 1000

    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, null)

@test
async A_REQUEST_THAT_ONLY_READS_A_STORED_SESSION_WRITES_NEITHER_A_COOKIE_NOR_AN_ENTRY()
    val store = memoryStore()
    val app = made(Secret, { store: store })

    assertEq(len(cookies(await app.handle(request("GET", "/me")))), 0)
    assertEq(store.size(), 0)

@test
async THE_TWO_MODES_STAND_SIDE_BY_SIDE_AND_NEITHER_READS_THE_OTHER()
    // **One secret, one cookie name, two arrangements.** A cookie from one is well signed to the
    // other and is still nobody, because what the payload carries means a different thing in each --
    // which is what makes moving a program from one to the other a change of one option and a
    // logging-out of everybody, and not a security hole in either.
    val kept = made(Secret, { store: memoryStore() })
    val plain = made(Secret)

    val stored = await cookieFrom(kept)
    val signed = await cookieFrom(plain)

    assertEq(doc(await kept.handle(request("GET", "/me", { cookies: { session: stored } }))).who, "ada")
    assertEq(doc(await plain.handle(request("GET", "/me", { cookies: { session: signed } }))).who, "ada")

    assertEq(doc(await kept.handle(request("GET", "/me", { cookies: { session: signed } }))).who, null)
    assertEq(doc(await plain.handle(request("GET", "/me", { cookies: { session: stored } }))).who, null)

@test
async A_STORE_IS_THREE_FUNCTIONS_AND_ANYTHING_ANSWERING_THEM_IS_ONE()
    // **The interface is what this asserts**: no registration, no base class, nothing of this
    // package's in it. A store over a database is this with `await` in the middle -- and these are
    // deliberately NOT `async`, which is the other half of the claim: the guard awaits all three and
    // `await` of a plain value answers it, so the promise in the interface is what a store MAY answer
    // and not what it must.
    val kept = { rows: {} }

    get(id: string) = if has(kept.rows, id) then kept.rows[id] else null

    set(id: string, value, ttl = null)
        kept.rows[id] = value

        null

    delete(id: string)
        if has(kept.rows, id) then kept.rows[id] = null

        null

    val app = made(Secret, { store: { get: get, set: set, delete: delete } })
    val cookie = await cookieFrom(app)

    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, "ada")

@test
async A_STORE_THAT_FAULTS_IS_A_500_AND_NOT_A_QUIET_LOGGING_OUT()
    // **A database that is down is not a client who is nobody.** A guard that caught this and handed
    // the handler `null` would log every user out on a blip and answer `200` while doing it, which
    // is the failure a program can neither see nor recover from. So it faults, and a fault is a 500
    // -- `api({ onFault: … })` being how a test watches one without ending the run.
    var caught = null

    noted(e)
        caught = e.message

    async falling(id: string)
        throw "the session store is not there"

    async setting(id: string, value, ttl = null) = null
    async deleting(id: string) = null

    val app = api({ onFault: noted })
    val store = { get: falling, set: setting, delete: deleting }

    app.get("/me", session(Secret, { store: store }, (req) -> json({ who: req.session.value })))

    // A cookie the guard will actually look up: it has to get past the signature to reach the store.
    val cookie = await cookieFrom(made(Secret, { store: memoryStore() }))
    val r = await app.handle(request("GET", "/me", { cookies: { session: cookie } }))

    assertEq(status(r), 500)
    assertEq(caught, "the session store is not there")

@test
async A_COOKIE_PAST_ITS_maxAge_IS_NOBODY_AND_THE_STORE_IS_NOT_ASKED()
    // **The cookie's own expiry is read before the store is**, which is what stops an expired session
    // costing a lookup -- and what stops a store that has forgotten to expire an entry resurrecting
    // one the cookie says is over.
    val store = counted(memoryStore())
    val app = made(Secret, { store: store, maxAge: 0 - 1 })
    val cookie = await cookieFrom(app)

    assertEq(store.seen.gets, 0)
    assertEq(doc(await app.handle(request("GET", "/me", { cookies: { session: cookie } }))).who, null)
    assertEq(store.seen.gets, 0)

@test
async A_STORED_SESSION_AND_A_CSRF_TOKEN_IN_ONE_RESPONSE_ARE_STILL_TWO_COOKIES()
    // The neighbouring guard, over the mode that awaits: the session cookie is now written after two
    // store calls, and `withHeaders` still has to keep both `Set-Cookie` lines.
    val app = api()

    app.get("/in", csrf({}, session(Secret, { store: memoryStore() }, greeter)))

    val two = cookies(await app.handle(request("GET", "/in")))

    assertEq(len(two), 2)
    assert(contains(two[0], "session=") || contains(two[1], "session="))
    assert(contains(two[0], "csrf=") || contains(two[1], "csrf="))

@test
async A_STORED_SESSION_COOKIE_CARRIES_THE_SAME_ATTRIBUTES_AS_ANY_OTHER()
    // **`options` is one object and `store` is this guard's own**, so it has to be kept off the
    // cookie by name -- a member `setCookie` has never heard of going straight through is otherwise
    // exactly what the pass-through rule promises.
    val line = cookies(await made(Secret, { store: memoryStore(), maxAge: 60 }).handle(
        request("POST", "/in", { body: "\"ada\"" })))[0]

    assert(contains(line, "HttpOnly"))
    assert(contains(line, "SameSite=Lax"))
    assert(contains(line, "Path=/"))
    assert(contains(line, "Max-Age=60"))
    assert(!contains(line, "store"))
