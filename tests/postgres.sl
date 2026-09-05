// `examples/tasks/postgres.sl` against a PostgreSQL server written in slate.
//
// **This is the half `tests/tasks.sl` cannot reach.** That file substitutes a store over an array,
// which says everything about the routes and nothing about the SQL; this one runs the real store
// over a real socket and reads what it actually sent -- the statements, the parameters, the SQLSTATE
// a unique violation comes back as, and the columns as the types they were read into.
//
// **`slate:net` is not on the JavaScript back end**, so nothing here can run under `slate test --js`:
// the names import and say *"not in the JavaScript back end yet"* when a program reaches them.
// **Every test here therefore ends in a `skip` on that host**, which slate 0.0.30 gave the runner --
// a third verdict beside a pass and a failure, said on the line where a passing test's timing goes
// and counted on the last line of the run. Until then a test left out on one host `return`ed, which
// is a PASS: nine of them, green, having asserted nothing at all.

import { percentDecode } from slate:http
import { close as closeSocket } from slate:net

import { request } from "../sluice.sl"
import { doc, status, header } from "./support.sl"
import { server, portOf } from "./pgserver.sl"
import { application } from "../examples/tasks/tasks.sl"
import { postgres } from "../examples/tasks/postgres.sl"

// **A test that hangs is worse than a test that fails**, a socket keeping the program alive and the
// runner waiting out the rest of the run with nothing printed. Three seconds is far longer than a
// loopback exchange and far shorter than a person's patience.
val Guard = 3000

// The columns of the tasks table, as a server describes them: `int4`, `text` and `bool`.
val Columns = [{ name: "id", oid: 23 }, { name: "title", oid: 25 }, { name: "done", oid: 16 }]

// Why this host cannot run these, or `null` where it can. **The question is asked of the HOST and
// not of a flag**, there being nothing to read: a name on the JavaScript back end's owed list exists
// and faults when it is called, so calling it is the only way to find out. Asked once, since the
// answer cannot change.
val Host = { asked: false, why: null }

lacking() -> string | null
    if Host.asked then return Host.why

    Host.asked = true

    try
        closeSocket(server((sql, params) -> { tag: "SELECT 0" }))
    catch e
        Host.why = "this host has no listener, and a real PostgreSQL exchange needs one: " + e.message

    Host.why

// **`skip` RAISES, which is why nothing follows this line where it fires.** A skip is the test's
// whole verdict, exactly as `exit` is a script's, so forgetting a `return` beside it cannot leave the
// test running on the host it was written to be left out of.
needsASocket()
    val why = lacking()

    if why != null then skip(why)

    null

// A watchdog that ends the run rather than letting it hang, and says which test left it running.
//
// **A call rather than a `throw` written in the lambda**, a block lambda having to be the last
// argument where `setTimeout` takes the delay after it.
late(what: string) = setTimeout(() -> ranLong(what), Guard)

ranLong(what: string)
    throw "the " + what + " did not finish in time"

// A server whose answers are canned, keeping every statement it was sent.
told(replies: object, seen: array) -> function
    replying(sql, params)
        push(seen, { sql: sql, params: params })

        for [prefix, said] in entries(replies)
            if startsWith(sql, prefix) then return said

        { tag: "SELECT 0" }

    replying

// The store, opened against a server answering `replies`.
async opened(replies: object, seen: array) -> object
    val fake = server(told(replies, seen))
    val made = await postgres({ host: "127.0.0.1",
                                port: portOf(fake),
                                user: "ada",
                                password: "pencil",
                                database: "tasks" })

    { fake: fake, made: made }

// What every test here answers with once it is done.
shut(open: object)
    if open.made.ok then open.made.value.close()

    closeSocket(open.fake)

// The replies a server gives that has one task in it.
val OneTask = { "create table": { tag: "CREATE TABLE" },
                "select id, title, done": { fields: Columns,
                                            rows: [["1", "write the example", "t"],
                                                   ["2", "run it against a real one", "f"]],
                                            tag: "SELECT 2" },
                "select 1 as up": { fields: [{ name: "up", oid: 23 }],
                                    rows: [["1"]],
                                    tag: "SELECT 1" } }

// -- what the store sends -------------------------------------------------------------------------

@test
async THE_STORE_MAKES_ITS_TABLE_ON_THE_WAY_IN()
    needsASocket()

    val guard = late("schema test")
    val seen = []
    val open = await opened(OneTask, seen)

    assert(open.made.ok)
    assert(startsWith(seen[0].sql, "create table if not exists tasks"))
    assert(contains(seen[0].sql, "title text not null unique"))

    // **No parameters, so it went as a simple `Query`** -- which is the only protocol that may carry
    // several statements, and the one a schema wants.
    assertEq(len(seen[0].params), 0)

    shut(open)
    clearTimeout(guard)

@test
async A_LISTING_READS_ITS_COLUMNS_AS_THE_TYPES_THE_SERVER_NAMED()
    // **`t` is not the string `"t"` once the column says `bool`**, and `1` is not `"1"` once it says
    // `int4`. Reading the OIDs is `pg`'s job and this is where the store finds out it happened.
    needsASocket()

    val guard = late("listing test")
    val seen = []
    val open = await opened(OneTask, seen)
    val r = await open.made.value.list()

    assert(r.ok)
    assertEq(len(r.value), 2)
    assertEq(r.value[0].id, 1)
    assertEq(r.value[0].title, "write the example")
    assertEq(r.value[0].done, true)
    assertEq(r.value[1].done, false)

    shut(open)
    clearTimeout(guard)

@test
async A_TITLE_CROSSES_AS_A_PARAMETER_AND_NEVER_AS_SQL()
    // **The server parses the statement before it is given a single value**, so nothing a title
    // contains can become part of the query. `$1` is the whole of the defence and there is no
    // escaping function anywhere in this example.
    needsASocket()

    val guard = late("parameter test")
    val seen = []
    val open = await opened({ "create table": { tag: "CREATE TABLE" },
                              "insert into tasks": { fields: Columns,
                                                     rows: [["7", "'; drop table tasks; --", "f"]],
                                                     tag: "INSERT 0 1" } }, seen)
    val r = await open.made.value.add("'; drop table tasks; --")

    assert(r.ok)
    assertEq(r.value.id, 7)

    val sent = seen[len(seen) - 1]

    assert(contains(sent.sql, "values ($1)"))
    assert(!contains(sent.sql, "drop table"))
    assertEq(sent.params, ["'; drop table tasks; --"])

    shut(open)
    clearTimeout(guard)

@test
async A_UNIQUE_VIOLATION_COMES_BACK_AS_23505_AND_NOT_AS_A_FAULT()
    // **A refusal is an answer.** The whole point of the SQLSTATE surviving the trip is that the
    // application above can turn `23505` into a `409` without knowing what a database is.
    needsASocket()

    val guard = late("violation test")
    val seen = []
    val open = await opened({ "create table": { tag: "CREATE TABLE" },
                              "insert into tasks": { error: { code: "23505",
                                                              message: "duplicate key value violates unique constraint \"tasks_title_key\"" } } }, seen)
    val r = await open.made.value.add("write the example")

    assert(!r.ok)
    assertEq(r.code, "23505")
    assert(contains(r.error, "tasks_title_key"))

    shut(open)
    clearTimeout(guard)

@test
async AN_UPDATE_THAT_MATCHED_NOTHING_ANSWERS_null_RATHER_THAN_A_REFUSAL()
    // **A task that is not there is not a database error**, and telling the two apart here is what
    // makes it a `404` rather than a `503`.
    needsASocket()

    val guard = late("update test")
    val seen = []
    val open = await opened({ "create table": { tag: "CREATE TABLE" },
                              "update tasks": { fields: Columns, rows: [], tag: "UPDATE 0" } }, seen)
    val r = await open.made.value.done(99)

    assert(r.ok)
    assertEq(r.value, null)
    assertEq(seen[len(seen) - 1].params, ["99"])

    shut(open)
    clearTimeout(guard)

@test
async A_DELETE_ANSWERS_WHETHER_THERE_WAS_ONE_TO_REMOVE()
    // **`INSERT` writes an object id before its count and nothing else does**, so the count is the
    // last word of the tag -- which is what `pg` reads and what this store's `true` rests on.
    needsASocket()

    val guard = late("delete test")
    val seen = []
    val one = await opened({ "create table": { tag: "CREATE TABLE" },
                             "delete from tasks": { tag: "DELETE 1" } }, seen)

    assertEq((await one.made.value.remove(1)).value, true)

    shut(one)

    val none = await opened({ "create table": { tag: "CREATE TABLE" },
                              "delete from tasks": { tag: "DELETE 0" } }, [])

    assertEq((await none.made.value.remove(1)).value, false)

    shut(none)
    clearTimeout(guard)

@test
async THE_HEALTH_PING_IS_A_ROUND_TRIP_AND_A_SERVER_THAT_REFUSES_IS_NOT_WELL()
    needsASocket()

    val guard = late("ping test")
    val seen = []
    val well = await opened(OneTask, seen)

    assert((await well.made.value.ping()).ok)
    assertEq(seen[len(seen) - 1].sql, "select 1 as up")

    shut(well)

    val ill = await opened({ "create table": { tag: "CREATE TABLE" },
                             "select 1 as up": { error: { code: "57P01",
                                                          message: "terminating connection due to administrator command" } } }, [])
    val r = await ill.made.value.ping()

    assert(!r.ok)
    assertEq(r.code, "57P01")

    shut(ill)
    clearTimeout(guard)

@test
async A_SERVER_THAT_IS_NOT_THERE_IS_A_RESULT_AND_NOT_A_FAULT()
    // **A database that is not up is something a program handles**, which is `pg`'s rule for
    // anything that reaches the network -- and what `postgres()` passes on rather than raising.
    needsASocket()

    val guard = late("unreachable test")
    val fake = server((sql, params) -> { tag: "SELECT 0" })
    val port = portOf(fake)

    closeSocket(fake)

    val made = await postgres({ host: "127.0.0.1", port: port, user: "ada", database: "tasks" })

    assert(!made.ok)
    assert(made.error != null)

    clearTimeout(guard)

// -- the whole thing ------------------------------------------------------------------------------

@test
async THE_APPLICATION_ANSWERS_HTTP_OVER_A_SOCKET_TO_THE_DATABASE()
    // **Every layer of the example at once**: a request value, the guards, the session, the store,
    // `pg`, a socket, the wire protocol, and a row read back out of it into a 201.
    needsASocket()

    val guard = late("end to end test")
    val seen = []
    val open = await opened({ "create table": { tag: "CREATE TABLE" },
                              "insert into tasks": { fields: Columns,
                                                     rows: [["1", "write the example", "f"]],
                                                     tag: "INSERT 0 1" },
                              "select id, title, done": { fields: Columns,
                                                          rows: [["1", "write the example", "f"]],
                                                          tag: "SELECT 1" },
                              "select 1 as up": { fields: [{ name: "up", oid: 23 }],
                                                  rows: [["1"]],
                                                  tag: "SELECT 1" } }, seen)

    assert(open.made.ok)

    val app = application(open.made.value, { secret: "a secret nobody else has", password: "open",
                                             sink: (r) -> null })
    val cookie = await cookieFor(app)
    val put = await app.handle(carrying(cookie, "POST", "/tasks", { title: "write the example" }))

    assertEq(status(put), 201)
    assertEq(doc(put).id, 1)
    assertEq(doc(put).done, false)
    assertEq(seen[len(seen) - 1].params, ["write the example"])

    // And the health check really asks the database.
    assertEq(status(await app.handle(request("GET", "/health"))), 200)
    assertEq(seen[len(seen) - 1].sql, "select 1 as up")

    shut(open)
    clearTimeout(guard)

// The session cookie a login answers, ready to be sent back. **DECODED, because that is what a
// server does** -- `setCookie` percent-encodes what it writes and `parseCookies` decodes what it
// reads.
async cookieFor(app: object) -> string
    val r = await app.handle(request("POST", "/login", { body: { user: "ada", password: "open" } }))
    val line = header(r, "set-cookie")

    if line == null then throw "that login set no cookie"

    val at = indexOf(line, ";")
    val pair = if at == null then line else line[0..<at]

    percentDecode(pair[(indexOf(pair, "=") + 1)..], false)

carrying(cookie: string, method: string, path: string, body = null) -> object
    if body == null then return request(method, path, { cookies: { session: cookie } })

    request(method, path, { cookies: { session: cookie }, body: body })
