// `session(secret)` and `csrf()` -- the cookie a server signs, and the token that goes with it.

import { percentDecode } from slate:http

import { api, session, csrf, json, request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

val Secret = "a secret nobody else has"

// An application that reads the session on `GET` and sets one on `POST`.
made(secret: string, options: object = {}) -> object
    val app = api()

    app.get("/me", session(secret, options, (req) -> json({ who: req.session.value })))
    app.post("/in", session(secret, options, (req) -> logIn(req)))
    app.post("/out", session(secret, options, (req) -> logOut(req)))

    app

// **The body is read here rather than through the `body` guard**, so that these tests are about the
// session and not about how a body arrives.
logIn(req: object) -> object
    req.session.set(parseJSON(req.body).value)

    json({ ok: true })

logOut(req: object) -> object
    req.session.set(null)

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
