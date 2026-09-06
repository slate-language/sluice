// The example under `examples/tasks/` -- every route of it, with no database and no socket.
//
// **The application is written against a store and this file writes one**, which is the whole point
// of the seam: `examples/tasks/postgres.sl` is five functions over `pg` and `memory()` below is the
// same five over an array, so the routes, the guards, the session, the failure mapping and the
// health check are all driven here exactly as they run against PostgreSQL.
//
// The half this cannot say anything about is whether the SQL is right, and `tests/postgres.sl` is
// that half: it drives `postgres.sl` itself against a PostgreSQL server written in slate.

import { percentDecode } from slate:http

import { request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"
import { application } from "../examples/tasks/tasks.sl"

val Secret = "a secret nobody else has"

// A store over an array, answering exactly what `postgres.sl` answers -- including the SQLSTATE a
// unique index refuses a duplicate title with, which is the one code the application reads.
//
// `options.down` is what a database that is not answering looks like from up here: every call a
// refusal, and nothing that faults.
memory(options: object = {}) -> object
    val down = options.down ?? null
    var rows = []
    var next = 1

    async list()
        if down != null then return { ok: false, error: down, code: null }

        { ok: true, value: rows }

    async add(title: string)
        if down != null then return { ok: false, error: down, code: null }

        for t in rows
            if t.title == title
                return { ok: false,
                         error: "duplicate key value violates unique constraint \"tasks_title_key\"",
                         code: "23505" }

        val made = { id: next, title: title, done: false }

        next = next + 1

        push(rows, made)

        { ok: true, value: made }

    async done(id: integer)
        if down != null then return { ok: false, error: down, code: null }

        for t in rows
            if t.id == id
                t.done = true

                return { ok: true, value: t }

        { ok: true, value: null }

    async remove(id: integer)
        if down != null then return { ok: false, error: down, code: null }

        var kept = []
        var gone = false

        for t in rows
            if t.id == id then gone = true else push(kept, t)

        rows = kept

        { ok: true, value: gone }

    async ping()
        if down != null then return { ok: false, error: down, code: null }

        { ok: true }

    { list: list, add: add, done: done, remove: remove, ping: ping, asked: () -> rows.length }

// The application, with a sink that keeps what it was told rather than printing it.
made(store: object, log: array) -> object =
    application(store, { secret: Secret, password: "open", sink: (r) -> push(log, r) })

// The session cookie a login answers, ready to be sent back.
async cookieFor(app: object, password: string = "open") -> string
    val r = await app.handle(request("POST", "/login", { body: { user: "ada", password: password } }))
    val line = header(r, "set-cookie")

    if line == null then throw "that login set no cookie"

    val at = indexOf(line, ";")
    val pair = if at == null then line else line[0..<at]

    // **DECODED, because that is what a server does.** `setCookie` percent-encodes what it writes
    // and `parseCookies` decodes what it reads, so handing the raw text back to `request` would be
    // testing a client nobody has.
    percentDecode(pair[(indexOf(pair, "=") + 1)..], false)

// The JSON array a listing answers. **`doc` is for a problem document and answers an object**, and
// a list of tasks is not one.
listed(reply) -> array
    val parsed = parseJSON(response(reply).body)

    if !parsed.ok then throw "that response body is not JSON: " + response(reply).body

    parsed.value

// A request carrying the session, which is what every task route wants.
carrying(cookie: string, method: string, path: string, body = null) -> object
    if body == null then return request(method, path, { cookies: { session: cookie } })

    request(method, path, { cookies: { session: cookie }, body: body })

// -- who is asking --------------------------------------------------------------------------------

@test
async A_TASK_ROUTE_WITHOUT_A_SESSION_IS_A_401_PROBLEM()
    val app = made(memory(), [])
    val r = await app.handle(request("GET", "/tasks"))

    assertEq(status(r), 401)
    assertEq(doc(r).title, "Unauthorized")

@test
async THE_WRONG_PASSWORD_IS_A_401_AND_SETS_NO_COOKIE()
    val app = made(memory(), [])
    val r = await app.handle(request("POST", "/login", { body: { user: "ada", password: "guess" } }))

    assertEq(status(r), 401)
    assertEq(header(r, "set-cookie"), null)

@test
async A_LOGIN_ANSWERS_A_COOKIE_AND_THE_TASKS_ARE_THEN_READABLE()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)
    val r = await app.handle(carrying(cookie, "GET", "/tasks"))

    assertEq(status(r), 200)
    assertEq(listed(r).length, 0)

@test
async LOGGING_OUT_ENDS_THE_SESSION()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)

    assertEq(status(await app.handle(carrying(cookie, "POST", "/logout"))), 200)

    // **The cookie the client still holds is an id the store no longer has**, which is what a store
    // buys over a signed cookie: a logout revokes rather than merely asking a browser to forget.
    assertEq(status(await app.handle(carrying(cookie, "GET", "/tasks"))), 401)

// -- the tasks ------------------------------------------------------------------------------------

@test
async A_TASK_IS_MADE_AND_COMES_BACK_IN_THE_LIST()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)
    val put = await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))

    assertEq(status(put), 201)
    assertEq(doc(put).title, "write the example")
    assertEq(doc(put).done, false)

    val all = await app.handle(carrying(cookie, "GET", "/tasks"))

    assertEq(listed(all).length, 1)
    assertEq(listed(all)[0].id, doc(put).id)

@test
async A_BODY_THAT_DOES_NOT_FIT_IS_A_400_CARRYING_THE_REASON()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)
    val r = await app.handle(carrying(cookie, "POST", "/tasks", { name: "the wrong member" }))

    assertEq(status(r), 400)
    assert(doc(r).mismatch.length > 0)

@test
async A_TITLE_THE_STORE_REFUSES_WITH_23505_IS_A_409_AND_NOT_A_503()
    // **The SQLSTATE is the whole of this test.** A unique index is what makes a duplicate title one
    // round trip rather than a read and a race, and `23505` is the database saying the one thing the
    // application already has a word for -- every other code it has nothing to say about and answers
    // `503`.
    val app = made(memory(), [])
    val cookie = await cookieFor(app)

    await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))

    val again = await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))

    assertEq(status(again), 409)
    assertEq(doc(again).taken, "write the example")

@test
async AN_EMPTY_TITLE_FITS_THE_SHAPE_AND_IS_REFUSED_ANYWAY()
    // **A shape says the KIND and the handler says the rest.** `{ title: string }` cannot express
    // *not empty*, so `""` gets past `body(NewTask)` and is stopped where the rule really lives.
    val app = made(memory(), [])
    val cookie = await cookieFor(app)

    assertEq(status(await app.handle(carrying(cookie, "POST", "/tasks", { title: "   " }))), 400)
    assertEq(status(await app.handle(carrying(cookie, "POST", "/tasks", { title: 7 }))), 400)

@test
async THE_LOG_REPORTS_THE_STATUS_THE_CLIENT_WAS_GIVEN_AND_NOT_A_200()
    // **The failure mapping runs UNDER the guards**, which is what makes this true and is the one
    // ordering in this package that is not obvious: a `logger` above an unmapped failure reports
    // `200` for what the client received as `409`.
    val log = []
    val app = made(memory(), log)
    val cookie = await cookieFor(app)

    await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))

    val again = await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))

    assertEq(status(again), 409)
    assertEq(log[log.length - 1].status, 409)

@test
async FINISHING_A_TASK_ANSWERS_IT_DONE()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)
    val put = await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))
    val id = string(doc(put).id)
    val r = await app.handle(carrying(cookie, "POST", "/tasks/" + id + "/done"))

    assertEq(status(r), 200)
    assertEq(doc(r).done, true)

@test
async A_TASK_THAT_IS_NOT_THERE_IS_A_404_PROBLEM_NAMING_IT()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)
    val r = await app.handle(carrying(cookie, "POST", "/tasks/99/done"))

    assertEq(status(r), 404)
    assertEq(doc(r).instance, "/tasks/99")

@test
async AN_ID_THAT_IS_NOT_A_NUMBER_IS_A_404_AND_THE_STORE_IS_NEVER_ASKED()
    // **A path parameter is text and an id is a number.** Handing `nonsense` to PostgreSQL would be
    // an error about integer syntax, arriving as a 503, for a client that asked for a task that is
    // not there -- so the conversion is the application's and a refusal here reaches no store.
    val store = memory({ down: "this store would fault if it were asked" })
    val app = made(store, [])
    val cookie = await cookieFor(app)

    assertEq(status(await app.handle(carrying(cookie, "POST", "/tasks/nonsense/done"))), 404)
    assertEq(status(await app.handle(carrying(cookie, "DELETE", "/tasks/-1"))), 404)

@test
async A_TASK_IS_REMOVED_AND_THE_ANSWER_HAS_NO_BODY()
    val app = made(memory(), [])
    val cookie = await cookieFor(app)
    val put = await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))
    val id = string(doc(put).id)

    assertEq(status(await app.handle(carrying(cookie, "DELETE", "/tasks/" + id))), 204)
    assertEq(status(await app.handle(carrying(cookie, "DELETE", "/tasks/" + id))), 404)

// -- a store that is not answering -----------------------------------------------------------------

@test
async A_STORE_THAT_REFUSES_IS_A_503_AND_NOT_A_DEFECT()
    // **A database that is down is an answer and not a fault.** `pg` answers a result for anything
    // that reaches the network, the store passes it up, and the application has a failure for it --
    // so nothing here raises and the client is told to come back.
    val app = made(memory({ down: "the server closed the connection" }), [])
    val cookie = await cookieFor(app)
    val r = await app.handle(carrying(cookie, "GET", "/tasks"))

    assertEq(status(r), 503)
    assertEq(doc(r).reason, "the server closed the connection")

@test
async THE_HEALTH_CHECK_ASKS_THE_STORE_AND_SAYS_WHY_IT_IS_UNWELL()
    val well = made(memory(), [])
    val ill = made(memory({ down: "no route to host" }), [])

    assertEq(status(await well.handle(request("GET", "/health"))), 200)

    val r = await ill.handle(request("GET", "/health"))

    assertEq(status(r), 503)
    assert(contains(doc(r).reasons[0], "no route to host"))

@test
async THE_HEALTH_CHECK_RUNS_UNDER_NO_GUARDS_AND_NEEDS_NO_SESSION()
    // **The thing asking is a load balancer and not a client of this API**, so the route is added on
    // its own: no session, no rate limit, and nothing in the traffic log.
    val log = []
    val app = made(memory(), log)

    assertEq(status(await app.handle(request("GET", "/health"))), 200)
    assertEq(log.length, 0)

// -- what the operational guards do -----------------------------------------------------------------

@test
async EVERY_ANSWER_CARRIES_A_REQUEST_ID_AND_THE_LOG_RECORD_SAYS_IT()
    val log = []
    val app = made(memory(), log)
    val cookie = await cookieFor(app)
    val r = await app.handle(carrying(cookie, "GET", "/tasks"))

    assert(header(r, "x-request-id") != null)
    assertEq(log[log.length - 1].id, header(r, "x-request-id"))
    assertEq(log[log.length - 1].status, 200)
    assertEq(log[log.length - 1].path, "/tasks")

@test
async A_ROUTE_SAYS_WHICH_GUARDS_IT_RUNS_UNDER()
    // **What a stack buys over plain composition is that a route can be printed**, and this is the
    // one thing that reads it. The order is the order a request passes through them.
    val app = made(memory(), [])
    var seen = {}

    for r in app.routes()
        seen[r.method + " " + r.path] = r.guards

    assertEq(seen["GET /tasks"],
        ["requestId", "logger", "timeout(2000ms)", "rateLimit", "session", "needsSession"])
    assertEq(seen["POST /tasks"],
        ["requestId", "logger", "timeout(2000ms)", "rateLimit", "session", "needsSession", "body(NewTask)"])
    assertEq(seen["GET /health"], [])
