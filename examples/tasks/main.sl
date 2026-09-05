// A task-list API over PostgreSQL, run against a real one.
//
//     PG_URL=postgres://ada:secret@127.0.0.1:5432/tasks slate examples/tasks/main.sl
//
// With no `PG_URL` it connects wherever `psql` would -- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`
// and `PGDATABASE` are what `pg` reads when it is given nothing.
//
// **A port of `0` asks the kernel for one, and `localPort` says which it gave.** An example that
// bound 8080 would fail whenever the machine is already running a server, which is most of the time.
//
// The application is in `tasks.sl` and the SQL is in `postgres.sl`. This file is the wiring: read
// the environment, connect, serve, run a client through it so that there is something to look at,
// and then drain.

import { onShutdown } from "../../sluice.sl"
import { info, setLevel, setSink, json as asLine } from logger
import { serve } from slate:http
import { localPort } from slate:net

import { application } from "./tasks.sl"
import { postgres, configuration } from "./postgres.sl"

async main()
    setLevel("info")
    setSink((r) -> print(asLine(r)))

    val opened = await postgres(configuration())

    if !opened.ok
        print("no database:", opened.error)
        print("say where one is: PG_URL=postgres://user:secret@host/database")

        return

    val store = opened.value
    val app = application(store, { secret: "a secret this example made up", password: "open", sink: said })

    val server = serve(0, app)
    val site = "http://127.0.0.1:" + string(localPort(server))

    // **How a server under a deployment stops**: `SIGTERM` arrives, new requests are refused, what
    // is in hand finishes, and only then is the socket let go. `onShutdown` answers the way to stop
    // watching, which is called below so that this example's own ending is not a signal handler
    // holding the loop open.
    val stopWatching = onShutdown(() -> app.drain(server, { grace: 10000 }))

    print("listening on", site)

    for r in app.routes()
        print(r.method, r.path, r.guards)

    // What a client would do, so that running this shows something.
    print(shown(await sent(site, "GET", "/tasks", null, null)))
    print(shown(await sent(site, "POST", "/login", { user: "ada", password: "wrong" }, null)))

    val login = await sent(site, "POST", "/login", { user: "ada", password: "open" }, null)
    val who = login.cookie

    print(shown(login))

    val one = await sent(site, "POST", "/tasks", { title: "write the example" }, who)
    val two = await sent(site, "POST", "/tasks", { title: "run it against a real database" }, who)

    print(shown(one))
    print(shown(two))

    // The same title again, which the unique index refuses and the application answers as a 409.
    print(shown(await sent(site, "POST", "/tasks", { title: "write the example" }, who)))

    val first = "/tasks/" + string(idIn(one))
    val second = "/tasks/" + string(idIn(two))

    print(shown(await sent(site, "POST", first + "/done", null, who)))
    print(shown(await sent(site, "POST", "/tasks/999999/done", null, who)))
    print(shown(await sent(site, "POST", "/tasks/nonsense/done", null, who)))
    print(shown(await sent(site, "GET", "/tasks", null, who)))
    print(shown(await sent(site, "GET", "/health", null, null)))

    // **Every task this run made is taken away again**, so that running it a second time does what
    // the first run did rather than meeting its own titles in the table.
    print(shown(await sent(site, "DELETE", first, null, who)))
    print(shown(await sent(site, "DELETE", second, null, who)))
    print(shown(await sent(site, "GET", "/tasks", null, who)))

    stopWatching()

    print("drained:", await app.drain(server, { grace: 2000 }))

    store.close()

// **The guard hands a sink a record and the `logger` package takes one**, so there is nothing
// between them. `id=` on the line is `requestId`'s.
said(r) = info("request", r)

// -- a client, so that there is something to look at ----------------------------------------------

// One request, with the session cookie where there is one. It answers what was asked, what came
// back, and the cookie to carry on with.
async sent(site: string, method: string, path: string, value, cookie)
    val r = await fetch(site + path, asked(method, value, cookie))

    if !r.ok then return { method: method, path: path, status: 0, body: r.error, cookie: cookie }

    { method: method,
      path: path,
      status: r.value.status,
      body: r.value.body,
      cookie: cookieIn(r.value) ?? cookie }

asked(method: string, value, cookie) -> object
    val headers = if cookie == null then {} else { Cookie: cookie }

    if value == null then return { method: method, headers: headers }

    { method: method, headers: headers, body: toJSON(value) }

shown(r: object) -> string = r.method + " " + r.path + " -> " + string(r.status) + " " + r.body

idIn(r: object) -> integer
    val parsed = parseJSON(r.body)

    if !parsed.ok then throw "that answer carries no task: " + r.body

    parsed.value.id

// **`set-cookie` is a LIST and not a joined string**, which is `fetch`'s own rule: a cookie carries
// commas inside itself, so two of them joined by one cannot be taken apart again. What goes back is
// the `name=value` in front of the first `;`.
cookieIn(reply: object) -> string | null
    if !has(reply.headers, "set-cookie") then return null

    val lines = reply.headers["set-cookie"]
    val line = if lines is array then lines[0] else lines
    val at = indexOf(line, ";")

    if at == null then line else line[0..<at]

main()
