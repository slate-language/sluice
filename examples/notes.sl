// A notes API, which is the whole of this package in one file.
//
//     slate examples/notes.sl
//
// **A port of `0` asks the kernel for one, and `localPort` says which it gave.** An example that
// bound 8080 would fail whenever the machine is already running a server, which is most of the time.

import { api, stack, body, logger, problem, json, request } from "../sluice.sl"
import { info } from logger
import { serve, close } from slate:http
import { localPort } from slate:net

// What a client may send. **The declaration is the validator** -- `body(NewNote, …)` checks against
// this and answers a 400 carrying every reason it did not fit.
type NewNote = { title: string, text: string, pinned?: boolean }

// What a handler may fail with. **A closed set, so the mapping below is checked**: add a variant and
// leave it unanswered and this file stops compiling.
data Failure
    NoSuchNote(id)
    Taken(title)

// **`type Fail = Failure` is what makes the data type a shape value**, which is what `failures` is
// given so that `handle` can tell a failure from a response.
type Fail = Failure

// The store, which a real program would have somewhere else.
var notes = {}
var nextId = 1

async main()
    val app = api()

    app.failures(Fail, answer)

    app.get("/notes", (req) -> json(values(notes)))

    app.get("/notes/:id", (req) ->
        if has(notes, req.params.id) then json(notes[req.params.id]) else NoSuchNote(req.params.id))

    // **The guards read in the order a request passes through them**, and they are composed here
    // rather than walked per request.
    app.post("/notes", stack([logger(said), body(NewNote)])(create))

    app.delete("/notes/:id", remove)

    app.get("/health", (req) -> "ok")

    val server = serve(0, app)
    val site = "http://127.0.0.1:" + string(localPort(server))

    for r in app.routes()
        print(r.method, r.path, r.guards)

    // What a client would do, so that running this shows something.
    print(await sent(site + "/notes", "POST", { title: "first", text: "a note" }))
    print(await sent(site + "/notes", "POST", { title: "first", text: "again" }))
    print(await sent(site + "/notes", "POST", { text: "no title" }))
    print(await sent(site + "/notes/1", "GET", null))
    print(await sent(site + "/notes/99", "GET", null))

    // **The same handlers, with no socket anywhere.** A request is a value, so this is what the
    // suite of a program written with this package looks like.
    print("without a port:", (await app.handle(request("GET", "/health"))))

    close(server)

// Every failure this application can produce, and what each one is as HTTP.
answer(f: Failure) = f match
    NoSuchNote(id) -> problem(404, "Not Found", "there is no note " + id, { instance: "/notes/" + id })
    Taken(title) -> problem(409, "Conflict", "that title is taken", { instance: "/notes", taken: title })

create(req)
    for note in values(notes)
        if note.title == req.body.title then return Taken(req.body.title)

    val id = string(nextId)

    nextId = nextId + 1
    notes[id] = { id: id, title: req.body.title, text: req.body.text, pinned: req.body.pinned ?? false }

    json(notes[id], 201)

remove(req)
    if !has(notes, req.params.id) then return NoSuchNote(req.params.id)

    notes = without(notes, req.params.id)

    { status: 204 }

// An object with one key gone, slate having no remover of its own.
without(o: object, key: string) -> object
    var out = {}

    for [k, v] in entries(o)
        if k != key then out[k] = v

    out

// **The guard hands a sink a record and the `logger` package takes one**, so there is nothing
// between them. The default sink writes a line of text on stdout.
said(r) = info("request", r)

async sent(url: string, method: string, value)
    val options = if value == null then { method: method } else { method: method, body: toJSON(value) }
    val r = await fetch(url, options)

    if !r.ok then return "could not reach the server: " + r.error

    string(r.value.status) + " " + r.value.body

main()
