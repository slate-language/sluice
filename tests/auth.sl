// `login`, `logout`, `signedIn`, `remember` and `can` -- driven through `app.handle`, with a cookie jar
// standing in for the browser.

import { percentDecode } from slate:http

import { api, stack, session, memoryStore, login, logout, signedIn, remember, can, policy, logger,
    guardOf, problem, json, request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

val Secret = "a secret nobody else has"

val People = { "1": { id: "1", name: "ada" }, "2": { id: "2", name: "bob" } }

// What a refusal can be, mapped the way an application maps one.
data Failure
    NotSignedIn(what)
    NotYours(what)

answer(f: Failure) = f match
    NotSignedIn(what) -> problem(401, "Unauthorized", "sign in to " + what)
    NotYours(what) -> problem(404, "Not Found", "there is no " + what)

// A user by id, or `null` for one that is not there -- which is what `load` answers for somebody
// deleted since they signed in.
async load(id) = if has(People, id) then People[id] else null

// -- the browser -----------------------------------------------------------------------------------

// Every `Set-Cookie` on an answer, as a list.
cookies(reply) -> array
    var out = []

    for [k, v] in entries(response(reply).headers)
        if lower(k) == "set-cookie"
            out = if v is array then v else [v]

    out

// The jar after an answer: what was set is replaced, and what was cleared is gone.
//
// **Values are DECODED, because that is what a server does** -- `setCookie` percent-encodes and
// `parseCookies` decodes.
taken(jar: object, reply) -> object
    var out = {}

    for [k, v] in entries(jar)
        out[k] = v

    for line in cookies(reply)
        val at = indexOf(line, ";")
        val one = if at == null then line else line[0..<at]
        val eq = indexOf(one, "=")
        val name = one[0..<eq]
        val value = percentDecode(one[(eq + 1)..], false)

        if value == "" then out = without(out, name) else out[name] = value

    out

// A clock a test moves by hand.
val Start = 1800000000000

clock() -> object = { at: Start }

// -- the application -------------------------------------------------------------------------------

// The board, in miniature: a session in a store, the remember-me guard under it, and sign-in, sign-out
// and three routes that want somebody.
made(options: object = {}) -> object
    val time = options.time ?? clock()
    val tick = () -> time.at
    val sessions = options.sessions ?? memoryStore({ now: tick })
    val remembered = options.remembered ?? memoryStore({ now: tick })
    val thefts = options.thefts ?? []
    val sessionOptions = if options.signedCookie ?? false then {} else { store: sessions }
    val app = if has(options, "onFault") then api({ onFault: options.onFault }) else api()

    app.failures(Failure, answer)

    val known = stack([session(Secret, sessionOptions),
                       remember(remembered, { now: tick, onTheft: (id) -> push(thefts, id) })])

    app.post("/visit", known((req) -> visited(req)))
    app.post("/in", known((req) -> signedInAs(req)))
    app.post("/out", known((req) -> signedOut(req)))
    app.get("/me", known(signedIn(load, (req) -> json({ name: req.user.name }))))
    app.get("/page", known(signedIn(load, (req) -> "a page", { redirect: "/signin" })))
    app.get("/notes", known(signedIn(load, (req) -> "the notes", { refuse: NotSignedIn("read the notes") })))

    { app: app, sessions: sessions, remembered: remembered, thefts: thefts, time: time }

// A session that is not anybody yet -- what an attacker would plant.
visited(req: object) -> object
    req.session.set({ cart: ["a lamp"] })

    json({ ok: true })

signedInAs(req: object) -> object
    val said = parseJSON(req.body).value

    login(req, People[said.id], { remember: said.remember ?? false })

    json({ ok: true })

signedOut(req: object) -> object
    logout(req)

    json({ ok: true })

// Send a request with this jar and answer `{ reply, jar }` -- the jar as it is afterwards.
async sent(it: object, method: string, path: string, jar: object, body = null) -> object
    val options = if body == null then { cookies: jar } else { cookies: jar, body: toJSON(body) }
    val reply = await it.app.handle(request(method, path, options))

    { reply: reply, jar: taken(jar, reply) }

// A browser that has signed in as `id`, remembering or not.
async signedInJar(it: object, id: string = "1", keep: boolean = false) -> object
    val r = await sent(it, "POST", "/in", {}, { id: id, remember: keep })

    assertEq(status(r.reply), 200)

    r.jar

// -- login, logout and signedIn --------------------------------------------------------------------

@test
async A_LOGIN_IS_READ_BY_THE_NEXT_REQUEST_AND_THE_USER_IS_LOADED()
    val it = made()
    val jar = await signedInJar(it)
    val me = await sent(it, "GET", "/me", jar)

    assertEq(status(me.reply), 200)
    assertEq(parseJSON(response(me.reply).body).value, { name: "ada" })

@test
async ONLY_THE_ID_IS_KEPT_IN_THE_SESSION()
    // **The user is loaded on every request rather than copied in**, which is what keeps an edited
    // record from going stale -- so what the store holds is the id and nothing of the record.
    var stored = []

    val inner = memoryStore()
    val watching = { get: inner.get, delete: inner.delete, set: (id, v, ttl) -> keep(stored, inner, id, v, ttl) }

    val it = made({ sessions: watching })

    await signedInJar(it)

    assertEq(map(stored, (s) -> s.value), [{ user: "1" }])

@test
async NOBODY_SIGNED_IN_IS_A_401_PROBLEM_WITH_NO_BEARER_CHALLENGE()
    val it = made()
    val r = await sent(it, "GET", "/me", {})

    assertEq(status(r.reply), 401)
    assertEq(header(r.reply, "content-type"), "application/problem+json")
    assertEq(doc(r.reply).instance, "/me")
    assertEq(header(r.reply, "WWW-Authenticate"), null, "a session is not a bearer token")

@test
async A_SESSION_THAT_NAMES_NOBODY_IS_NOBODY_AND_NOT_A_FAULT()
    // A session an application keeps for something else -- a cart -- has no `user` in it.
    val it = made()
    val visit = await sent(it, "POST", "/visit", {})
    val r = await sent(it, "GET", "/me", visit.jar)

    assertEq(status(r.reply), 401)

@test
async AN_HTML_ROUTE_IS_REDIRECTED_TO_SIGN_IN_WITH_A_303()
    val it = made()
    val r = await sent(it, "GET", "/page", {})

    assertEq(status(r.reply), 303)
    assertEq(header(r.reply, "Location"), "/signin")

    val again = await sent(it, "GET", "/page", await signedInJar(it))

    assertEq(response(again.reply).body, "a page")

@test
async A_REFUSAL_AS_A_FAILURE_VARIANT_GOES_THROUGH_THE_MAPPING()
    val it = made()
    val r = await sent(it, "GET", "/notes", {})

    assertEq(status(r.reply), 401)
    assertEq(doc(r.reply).detail, "sign in to read the notes")

@test
async A_USER_DELETED_SINCE_SIGNING_IN_IS_REFUSED_AND_THE_SESSION_ENDS()
    // `load` answering `null` is somebody who is gone. The session is revoked as well as refused, so
    // the cookie stops costing a lookup.
    val it = made()

    // A route whose `load` no longer knows anybody, which is what a deletion looks like from here.
    it.app.get("/gone", session(Secret, { store: it.sessions }, signedIn((id) -> null, (req) -> "unreachable")))

    val gone = await sent(it, "GET", "/gone", await signedInJar(it))

    assertEq(status(gone.reply), 401)
    assert(contains(cookies(gone.reply)[0], "Max-Age=0"), "the session cookie is cleared")
    assertEq(it.sessions.size(), 0, "and the session is gone from the store")

@test
async signedIn_WITH_NO_SESSION_GUARD_ABOVE_IT_IS_A_FAULT()
    // A program put together wrong, so every request would be refused for a reason no client could
    // help: a fault, which `handle` answers with a 500.
    var caught = []

    noted(e)
        push(caught, e)

    val app = api({ onFault: noted })

    app.get("/me", signedIn(load, (req) -> "unreachable"))

    val r = await app.handle(request("GET", "/me"))

    assertEq(status(r), 500)
    assert(contains(string(caught[0]), "session"), "the fault names what is missing")

@test
async A_LOGOUT_ENDS_THE_SESSION_IN_THE_STORE()
    val it = made()
    val jar = await signedInJar(it)
    val out = await sent(it, "POST", "/out", jar)

    assertEq(it.sessions.size(), 0)

    // **The old cookie is what a thief would have kept**, and it is nobody now.
    val stale = await sent(it, "GET", "/me", jar)

    assertEq(status(stale.reply), 401)

@test
async idOf_SAYS_WHICH_MEMBER_IS_THE_ID_AND_A_NULL_ONE_IS_A_FAULT()
    var caught = []

    noted(e)
        push(caught, e)

    val app = api({ onFault: noted })
    val sessions = memoryStore()

    app.post("/in", session(Secret, { store: sessions }, (req) -> byName(req)))
    app.post("/broken", session(Secret, { store: sessions }, (req) -> badId(req)))

    assertEq(status(await app.handle(request("POST", "/in"))), 200)
    assertEq(status(await app.handle(request("POST", "/broken"))), 500)
    assert(contains(string(caught[0]), "idOf"))

byName(req: object)
    login(req, { name: "ada" }, { idOf: (u) -> u.name })

    "in"

badId(req: object)
    login(req, { name: "ada" })

    "unreachable"

// -- fixation --------------------------------------------------------------------------------------

@test
async A_SESSION_PLANTED_BEFORE_LOGIN_IS_NOT_THE_ONE_SIGNED_IN_IN_A_STORE()
    // **Session fixation**: an attacker gets a session of their own, plants its cookie in a victim's
    // browser, and waits for the victim to log in. If the login wrote into the planted session, the
    // attacker's copy of the cookie would now be the victim's.
    val it = made()
    val planted = (await sent(it, "POST", "/visit", {})).jar

    val victim = await sent(it, "POST", "/in", planted, { id: "1" })

    assert(victim.jar.session != planted.session, "the login is under a new cookie")

    val attacker = await sent(it, "GET", "/me", planted)

    assertEq(status(attacker.reply), 401, "the planted cookie is nobody")
    assertEq(status((await sent(it, "GET", "/me", victim.jar)).reply), 200)
    assertEq(it.sessions.size(), 1, "and the planted id is gone from the store")

@test
async A_SESSION_PLANTED_BEFORE_LOGIN_IS_NOT_THE_ONE_SIGNED_IN_IN_A_SIGNED_COOKIE()
    // **The same attack against a session with no store.** There is no id to fix: the cookie IS the
    // session, so the login writes a new one and the planted cookie goes on saying what it said.
    val it = made({ signedCookie: true })
    val planted = (await sent(it, "POST", "/visit", {})).jar

    val victim = await sent(it, "POST", "/in", planted, { id: "1" })

    assert(victim.jar.session != planted.session)
    assertEq(status((await sent(it, "GET", "/me", planted)).reply), 401)
    assertEq(status((await sent(it, "GET", "/me", victim.jar)).reply), 200)

@test
async A_LOGIN_STARTS_A_FRESH_SESSION_AND_KEEPS_NOTHING_PLANTED_IN_THE_OLD_ONE()
    val it = made()
    val planted = (await sent(it, "POST", "/visit", {})).jar
    val victim = await sent(it, "POST", "/in", planted, { id: "1" })

    var values = []

    readBack(req: object)
        push(values, req.session.value)

        "read"

    it.app.get("/raw", session(Secret, { store: it.sessions }, readBack))

    await sent(it, "GET", "/raw", victim.jar)

    assertEq(values, [{ user: "1" }])

// -- remember me -----------------------------------------------------------------------------------

// The remember-me cookie, split into its two halves.
halves(jar: object) -> object
    val raw = jar.remember
    val at = indexOf(raw, ".")

    { selector: raw[0..<at], validator: raw[(at + 1)..] }

@test
async A_REMEMBERED_LOGIN_SIGNS_BACK_IN_ONCE_THE_SESSION_HAS_GONE()
    val it = made()
    val jar = await signedInJar(it, "1", true)

    assert(has(jar, "remember"), "a remember-me cookie was issued")

    // The browser has been closed: the session cookie is gone and the remember-me one is not.
    val back = await sent(it, "GET", "/me", { remember: jar.remember })

    assertEq(status(back.reply), 200)
    assertEq(parseJSON(response(back.reply).body).value, { name: "ada" })
    assert(has(back.jar, "session"), "the token signed its holder in through a fresh session")

    // **Rotated on use**: the same series, a new validator.
    assertEq(halves(back.jar).selector, halves(jar).selector)
    assert(halves(back.jar).validator != halves(jar).validator)

@test
async ONLY_A_HASH_OF_THE_VALIDATOR_IS_STORED()
    var stored = []

    val inner = memoryStore()
    val watching = { get: inner.get, delete: inner.delete, set: (id, v, ttl) -> keep(stored, inner, id, v, ttl) }

    val it = made({ remembered: watching })
    val jar = await signedInJar(it, "1", true)
    val token = halves(jar)

    assertEq(stored[0].id, token.selector)
    assert(stored[0].value.hash != token.validator)
    assert(!contains(toJSON(stored[0].value), token.validator), "the validator is nowhere in what was stored")

keep(stored: array, inner: object, id, v, ttl)
    push(stored, { id: id, value: v, ttl: ttl })

    inner.set(id, v, ttl)

@test
async A_STOLEN_TOKEN_USED_BY_THE_THIEF_THEN_BY_THE_VICTIM_ENDS_THE_SERIES()
    // **The theft case.** The thief copies the cookie and uses it first, which rotates the series to a
    // validator only the thief has. When the victim's browser next presents the old one, the selector
    // is good and the validator is stale -- which can only happen to a copied cookie.
    val it = made()
    val victim = await signedInJar(it, "1", true)
    val stolen = { remember: victim.remember }

    val thief = await sent(it, "GET", "/me", stolen)

    assertEq(status(thief.reply), 200, "the thief gets in once")

    val caught = await sent(it, "GET", "/me", { remember: victim.remember })

    assertEq(status(caught.reply), 401, "the victim's stale token is refused")
    assert(!has(caught.jar, "remember"), "and the cookie is cleared")
    assertEq(it.thefts, ["1"], "the application is told whose series it was")

    // **The whole series is gone**, so the thief's rotated token is dead too.
    val after = await sent(it, "GET", "/me", { remember: thief.jar.remember })

    assertEq(status(after.reply), 401)

@test
async A_TOKEN_PAST_ITS_maxAge_IS_NOBODY()
    val it = made()
    val jar = await signedInJar(it, "1", true)

    it.time.at = it.time.at + 31 * 24 * 60 * 60 * 1000

    val r = await sent(it, "GET", "/me", { remember: jar.remember })

    assertEq(status(r.reply), 401)
    assert(!has(r.jar, "remember"))
    assertEq(it.thefts, [], "an expired token is not a theft")

@test
async A_TOKEN_IS_RENEWED_ON_EVERY_USE()
    // `maxAge` is how long a token lives unused: each use writes the series again for another 30
    // days, so somebody who comes back every week stays remembered.
    val it = made()
    var jar = await signedInJar(it, "1", true)

    for week in [1, 2, 3, 4, 5, 6]
        it.time.at = it.time.at + 7 * 24 * 60 * 60 * 1000

        val r = await sent(it, "GET", "/me", { remember: jar.remember })

        assertEq(status(r.reply), 200, "week " + string(week))

        jar = r.jar

@test
async A_LOGOUT_FORGETS_THE_TOKEN_IN_THE_STORE_AND_IN_THE_BROWSER()
    val it = made()
    val jar = await signedInJar(it, "1", true)
    val out = await sent(it, "POST", "/out", jar)

    assert(!has(out.jar, "remember"))
    assertEq(it.remembered.size(), 0)
    assertEq(status((await sent(it, "GET", "/me", { remember: jar.remember })).reply), 401)

@test
async A_LOGIN_WITHOUT_REMEMBER_FORGETS_A_TOKEN_SOMEBODY_ELSE_LEFT()
    // A shared computer: ada was remembered, bob signs in without asking to be. When bob's session
    // ends, ada's token must not sign ada back in on bob's browser.
    val it = made()
    val ada = await signedInJar(it, "1", true)
    val bob = await sent(it, "POST", "/in", { remember: ada.remember }, { id: "2" })

    assert(!has(bob.jar, "remember"))
    assertEq(it.remembered.size(), 0)

@test
async A_SIGNED_IN_SESSION_LEAVES_THE_TOKEN_ALONE()
    // The token is for when the session has gone, and is not even looked at while it has not.
    val it = made()
    val jar = await signedInJar(it, "1", true)
    val r = await sent(it, "GET", "/me", jar)

    assertEq(status(r.reply), 200)
    assertEq(cookies(r.reply), [])

@test
async A_MALFORMED_OR_UNKNOWN_TOKEN_IS_NOBODY_AND_IS_CLEARED()
    val it = made()

    for bad in ["nonsense", ".", "abc.", ".abc", "unknownselector.validator"]
        val r = await sent(it, "GET", "/me", { remember: bad })

        assertEq(status(r.reply), 401, bad)

    assertEq(it.thefts, [])

@test
async A_HANDLER_THAT_FAULTS_LEAVES_THE_SERIES_AS_IT_WAS()
    // **The rotation is written after the handler answers**, so a fault does not leave the store on a
    // validator the browser never received -- which the next request would read as a theft.
    var caught = []

    noted(e)
        push(caught, e)

    val it = made({ onFault: noted })

    it.app.get("/broken", stack([session(Secret, { store: it.sessions }),
                                 remember(it.remembered, { now: () -> it.time.at })])(signedIn(load, broken)))

    val jar = await signedInJar(it, "1", true)
    val r = await sent(it, "GET", "/broken", { remember: jar.remember })

    assertEq(status(r.reply), 500)

    val again = await sent(it, "GET", "/me", { remember: jar.remember })

    assertEq(status(again.reply), 200, "the same token still works")
    assertEq(it.thefts, [])

broken(req: object)
    throw "a defect in the handler"

@test
async REMEMBER_ASKED_FOR_WITHOUT_THE_GUARD_IS_A_FAULT()
    var caught = []

    noted(e)
        push(caught, e)

    val app = api({ onFault: noted })

    app.post("/in", session(Secret, {}, (req) -> rememberedWithout(req)))

    assertEq(status(await app.handle(request("POST", "/in"))), 500)
    assert(contains(string(caught[0]), "remember"))

rememberedWithout(req: object)
    login(req, People["1"], { remember: true })

    "unreachable"

// -- can -------------------------------------------------------------------------------------------

// Whether the note asked for is the signed-in user's.
async owns(req: object)
    if req.params.id == "404" then return NotYours("note " + req.params.id)

    req.params.id == req.user.id

guarded(it: object, check, seen: array) -> object
    it.app.get("/notes/:id", stack([logger((r) -> push(seen, r)),
                                    session(Secret, { store: it.sessions }),
                                    signedIn(load),
                                    can(check)])((req) -> "note " + req.params.id))

    it

@test
async can_LETS_THROUGH_WHAT_THE_POLICY_ALLOWS_AND_REFUSES_THE_REST_WITH_A_403()
    var seen = []
    val it = guarded(made(), owns, seen)
    val jar = await signedInJar(it, "1")

    assertEq(response((await sent(it, "GET", "/notes/1", jar)).reply).body, "note 1")

    val no = await sent(it, "GET", "/notes/2", jar)

    assertEq(status(no.reply), 403)
    assertEq(doc(no.reply).instance, "/notes/2")

@test
async A_POLICY_S_FAILURE_GOES_THROUGH_failures_AND_A_LOGGER_ABOVE_SEES_THE_STATUS_SENT()
    // **The mapping is applied between every pair of guards**, so a `logger` two layers above a
    // refusing `can` reports the 404 the client received and not the 200 an unmapped data value
    // would have gone out as.
    var seen = []
    val it = guarded(made(), owns, seen)
    val jar = await signedInJar(it, "1")
    val r = await sent(it, "GET", "/notes/404", jar)

    assertEq(status(r.reply), 404)
    assertEq(doc(r.reply).detail, "there is no note 404")
    assertEq(seen[seen.length - 1].status, 404)

@test
async A_LOGGER_ABOVE_A_FALSE_POLICY_REPORTS_THE_403()
    var seen = []
    val it = guarded(made(), owns, seen)
    val jar = await signedInJar(it, "1")

    await sent(it, "GET", "/notes/2", jar)

    assertEq(seen[seen.length - 1].status, 403)

@test
async A_POLICY_MAY_ANSWER_A_RESPONSE_OF_ITS_OWN()
    val app = api()

    app.get("/x", can((req) -> problem(451, "Unavailable For Legal Reasons"), (req) -> "x"))

    assertEq(status(await app.handle(request("GET", "/x"))), 451)

@test
async A_POLICY_THAT_ANSWERS_NULL_IS_A_FAULT_AND_NOT_A_REFUSAL()
    var caught = []

    noted(e)
        push(caught, e)

    val app = api({ onFault: noted })

    app.get("/x", can((req) -> null, (req) -> "x"))

    assertEq(status(await app.handle(request("GET", "/x"))), 500)
    assert(contains(string(caught[0]), "policy"))

@test
async routes_PRINTS_A_NAMED_POLICY_BY_ITS_NAME()
    val app = api()

    app.get("/a", can((req) -> true, (req) -> "a"))
    app.get("/b", can(policy("owns", owns), (req) -> "b"))
    app.get("/c", stack([session(Secret), remember(memoryStore()), signedIn(load)])((req) -> "c"))

    val rows = app.routes()

    assertEq(rows[0].guards, ["can"])
    assertEq(rows[1].guards, ["can(owns)"])
    assertEq(rows[2].guards, ["session", "remember", "signedIn"])

@test
async A_NAMED_POLICY_IS_STILL_CALLED_WITH_THE_REQUEST()
    val app = api()

    app.get("/n/:id", can(policy("even", (req) -> contains(["2", "4"], req.params.id)), (req) -> "ok"))

    assertEq(status(await app.handle(request("GET", "/n/2"))), 200)
    assertEq(status(await app.handle(request("GET", "/n/3"))), 403)
