// `bearer(verify)` -- the token out of `Authorization`, and everything that can be wrong with it.

import { api, bearer, request } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

// The application's verifier. **It answers a result**, which is the channel `slate:jwt`'s own
// `verify` uses: a bad token is a thing a server says `401` about and carries on.
check(token: string) -> object =
    if token == "good" then { ok: true, value: { id: 7, name: "ada" } }
    else { ok: false, error: "that token has expired" }

made(verify) -> object
    val app = api()

    app.get("/me", bearer(verify, (req) -> req.user.name))

    app

carrying(token: string) -> object = request("GET", "/me", { headers: { Authorization: token } })

@test
async A_GOOD_TOKEN_HANDS_THE_USER_ON_UNDER_user()
    assertEq(await made(check).handle(carrying("Bearer good")), "ada")

@test
async THE_SCHEME_IS_READ_WITHOUT_REGARD_TO_ITS_CASE()
    // `Bearer`, `bearer` and `BEARER` are one scheme; the token after it is not touched.
    assertEq(await made(check).handle(carrying("bearer good")), "ada")
    assertEq(await made(check).handle(carrying("BEARER good")), "ada")

@test
async NO_HEADER_AT_ALL_IS_A_401_PROBLEM_WITH_A_WWW_Authenticate()
    // Without that header a client is told it is unauthorised and not told what would authorise it.
    val r = await made(check).handle(request("GET", "/me"))

    assertEq(status(r), 401)
    assertEq(header(r, "WWW-Authenticate"), "Bearer")
    assertEq(header(r, "content-type"), "application/problem+json")
    assertEq(doc(r).title, "Unauthorized")
    assertEq(doc(r).detail, "this endpoint needs a bearer token")

@test
async ANOTHER_SCHEME_IS_REFUSED_AND_SAYS_SO()
    val r = await made(check).handle(carrying("Basic YWRhOnNlY3JldA=="))

    assertEq(status(r), 401)
    assertEq(doc(r).detail, "the Authorization header is not a bearer token")

@test
async AN_EMPTY_TOKEN_IS_REFUSED_BEFORE_THE_VERIFIER_IS_ASKED()
    var asked = false

    watching(t) -> object
        asked = true

        { ok: true, value: {} }

    val r = await made(watching).handle(carrying("Bearer   "))

    assertEq(status(r), 401)
    assertEq(doc(r).detail, "the bearer token is empty")
    assert(!asked, "an empty token is this package's refusal, not the application's")

@test
async A_TOKEN_THE_VERIFIER_REFUSES_CARRIES_THE_VERIFIERS_OWN_WORDS()
    val r = await made(check).handle(carrying("Bearer stale"))

    assertEq(status(r), 401)
    assertEq(doc(r).detail, "that token has expired")

@test
async A_VERIFIER_MAY_ANSWER_A_PROMISE()
    // A verifier that asks a database is an ordinary one.
    async slowly(token: string) -> object
        await sleep(1)

        check(token)

    assertEq(await made(slowly).handle(carrying("Bearer good")), "ada")

@test
async A_VERIFIER_THAT_DOES_NOT_ANSWER_A_RESULT_IS_A_DEFECT_AND_NOT_A_401()
    // A refusal here would turn one program's mistake into every client being told its token is bad.
    var caught = null

    // **A named function, because a lambda's one-line body is an expression** and an assignment is
    // a statement.
    noted(e)
        caught = e.message

    val app = api({ onFault: noted })

    app.get("/me", bearer((t) -> "yes", (req) -> "never reached"))

    assertEq(status(await app.handle(carrying("Bearer good"))), 500)
    assertEq(caught, "a `bearer` verifier answers a result -- { ok: true, value: user } or { ok: false, error: text }")
