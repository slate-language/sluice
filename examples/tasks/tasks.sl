// A task list, as HTTP. **This file holds no SQL and knows no database.**
//
// What it is written against is a STORE -- five functions, each answering a result and each of which
// may answer a promise. `postgres.sl` is one written over `pg` and is the only file here that knows
// any SQL; `tests/tasks.sl` writes another over an object, which is how every route below is driven
// with no database, no socket and nothing to start.
//
//     list()          every task, oldest first
//     add(title)      the task that was made
//     done(id)        the task, now finished -- or `null` where there is none
//     remove(id)      whether there was one to remove
//     ping()          how the store is, for the health check
//
// **A store answers `{ ok: true, value }` or `{ ok: false, error, code }`**, which is slate's rule
// for anything that reaches the network and is what `pg` already answers: a database that is down, a
// role that cannot read a table and a unique index that refused a row are all things a service turns
// into a status code rather than a defect. `code` is the SQLSTATE where there was one.

import { api, stack, body, session, memoryStore, logger, requestId, timeout, rateLimit,
    guardOf, problem, json } from "../../sluice.sl"

// What a client may send. **The declaration is the validator** -- `body(NewTask, …)` checks against
// it and answers a 400 carrying every reason it did not fit.
type NewTask = { title: string }
type Credentials = { user: string, password: string }

// What a handler may fail with. **A closed set, so the mapping below is checked**: add a variant and
// leave it unanswered and this file stops compiling.
data Failure
    NoSuchTask(id)
    Taken(title)
    Unavailable(reason)

// `application(store, options)` -- the api, over whichever store it was handed.
//
// `options` takes `secret`, the key the session cookie is signed with; `password`, the one this
// example lets anybody in with; and `sink`, where `logger` sends its record.
export application(store: object, options: object = {}) -> object
    val secret = options.secret ?? "a secret this example made up"
    val password = options.password ?? "open"
    val sink = options.sink ?? print
    val app = api()

    // The data type itself is what `failures` is given -- a `data` name is a shape value, which is
    // how `handle` tells a returned failure from a response.
    app.failures(Failure, answer)

    // **The operational guards go outside the ones about an endpoint**, which is what reading in
    // request order means: a request is named, then logged, then bounded, then counted, and only
    // then is who is asking anybody's business.
    val common = [requestId({}),
                  logger(sink),
                  timeout(2000, {}),
                  rateLimit({ limit: 100, window: 60000 }),
                  session(secret, { store: memoryStore(), maxAge: 3600 })]

    // Two stacks over one list: the second is the first plus the guard that wants somebody logged
    // in, so a route says which it is by which stack it is added under.
    val open = stack(common)
    val guarded = stack(concat(common, [needsSession]))

    app.post("/login", open(body(Credentials, (req) -> signIn(password, req))))
    app.post("/logout", open((req) -> signOut(req)))

    app.get("/tasks", guarded((req) -> listed(store)))
    app.post("/tasks", guarded(body(NewTask, (req) -> made(store, req))))
    app.post("/tasks/:id/done", guarded((req) -> finished(store, req)))
    app.delete("/tasks/:id", guarded((req) -> dropped(store, req)))

    // **A route convention rather than a guard**: the thing asking is a load balancer and not a
    // client, so it is added on its own and runs under nothing -- no session, no log line and no
    // rate limit. What it asks the store is a round trip to the database and not a flag in memory.
    app.health("/health", () -> reachable(store))

    app

// Every failure this application can produce, and what each one is as HTTP.
//
// **The annotation is what makes this checked.** slate proves the match covers the whole of
// `Failure` before the program runs, so a variant added above with no answer here is a compile
// error rather than a request that falls through to a 500.
answer(f: Failure) = f match
    NoSuchTask(id) -> problem(404, "Not Found", "there is no task " + id, { instance: "/tasks/" + id })
    Taken(title) -> problem(409, "Conflict", "there is already a task called " + title, { taken: title })
    Unavailable(reason) -> problem(503, "Service Unavailable", "the task store is not answering",
        { reason: reason })

// -- who is asking -------------------------------------------------------------------------------

// **A guard of this application's own**, which is what `guardOf` is for: it is composed like every
// other one and `api.routes()` prints it by the name given here.
//
// **A GUARD ANSWERS HTTP AND NOT A FAILURE**, which is the one thing about this package that is not
// obvious from the outside: `api.add` composes a route's guards AROUND the failure mapping rather
// than over it, so that a `logger` above a failure reports the status the client was really given.
// A guard returning `Failure` is therefore above the only thing that would have translated it, and
// what goes out is a `200` carrying a rendered data value. That is why this answers a problem
// document directly, exactly as `bearer`'s own 401 does.
val needsSession = guardOf("needsSession", (h) -> (req) -> ifSomebody(h, req))

ifSomebody(h, req) = if req.session.value == null then anybody() else h(req)

anybody() -> object = problem(401, "Unauthorized", "this asks for a session")

// A login as trivial as a login gets: one password, and the user's name is whatever they said.
//
// **A real one asks something that can say no** -- a directory, a password column, an identity
// provider -- and answers exactly the same way. What matters here is that `req.session.set` is what
// writes the cookie, and that the handler answering is not the one building it.
signIn(password: string, req: object) -> object
    if req.body.password != password then return problem(401, "Unauthorized", "that is not the password")

    req.session.set({ user: req.body.user })

    json({ ok: true })

signOut(req: object) -> object
    req.session.destroy()

    json({ ok: true })

// -- the tasks -----------------------------------------------------------------------------------

async listed(store: object)
    val r = await store.list()

    if !r.ok then return Unavailable(r.error)

    json(r.value)

async made(store: object, req: object)
    // **A shape says what KIND a member is and not what it may hold**, so the one check a task list
    // wants that `NewTask` cannot make is written here: an empty title fits `string` perfectly well
    // and is not a task.
    if trim(req.body.title) == "" then return problem(400, "Bad Request", "a task wants a title")

    val r = await store.add(req.body.title)

    if r.ok then return json(r.value, 201)

    // **`23505` is a unique violation**, which is the database saying what this application already
    // has a word for. Every other refusal is one it has nothing to say about, so it says so.
    if r.code == "23505" then return Taken(req.body.title)

    Unavailable(r.error)

async finished(store: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return NoSuchTask(req.params.id)

    val r = await store.done(id)

    if !r.ok then return Unavailable(r.error)
    if r.value == null then return NoSuchTask(req.params.id)

    json(r.value)

async dropped(store: object, req: object)
    val id = idOf(req.params.id)

    if id == null then return NoSuchTask(req.params.id)

    val r = await store.remove(id)

    if !r.ok then return Unavailable(r.error)
    if !r.value then return NoSuchTask(req.params.id)

    { status: 204 }

// **A path parameter is text and an id is a number, and the conversion belongs here.** Handing
// `/tasks/nonsense/done` to the database would be an error message from PostgreSQL about the syntax
// of an integer, arriving as a 503, for a client that simply asked for a task that is not there.
idOf(text: string) -> integer | null
    val n = number(text)

    if n is integer && n > 0 then n else null

// **A health check answers the reasons it is unwell**, and an empty answer means it is well. This
// one asks the store, which asks the database -- a check that read a flag in this process would go
// on saying `ok` while nothing it needs was reachable.
async reachable(store: object)
    val r = await store.ping()

    if r.ok then [] else ["the task store is not answering: " + r.error]
