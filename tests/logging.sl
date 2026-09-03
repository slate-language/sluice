// The `logger` guard and the `logger` package, which are two halves of one thing.
//
// **The guard hands a sink a record and the package takes one**, so nothing sits between them: no
// adapter, no formatter, no line of text built in the wrong place. This file is the test that says
// the two really do fit, since each was written against a description of the other.

import { api, logger, request } from "../sluice.sl"
import { info, setLevel, setSink, setClock, reset, text } from logger

val Stamp = "2026-09-03T18:19:05Z"

@test
async THE_GUARDS_RECORD_GOES_STRAIGHT_INTO_THE_LOGGING_PACKAGE()
    var written = []

    reset()
    setClock(() -> Stamp)
    setSink((r) -> push(written, r))

    val app = api()

    app.get("/notes/:id", logger((r) -> info("request", r), (req) -> "note " + req.params.id))

    assertEq(await app.handle(request("GET", "/notes/7")), "note 7")

    assertEq(len(written), 1)
    assertEq(written[0].level, "info")
    assertEq(written[0].message, "request")
    assertEq(written[0].method, "GET")
    assertEq(written[0].path, "/notes/7")
    assertEq(written[0].status, 200)
    assert(written[0].ms is integer)

    reset()

@test
async A_LEVEL_THAT_HOLDS_THE_RECORD_BACK_DOES_NOT_CHANGE_THE_ANSWER()
    // The sink is a function the application chose, so whether anything is written is its business
    // and the request is answered either way.
    var written = []

    reset()
    setClock(() -> Stamp)
    setSink((r) -> push(written, r))
    setLevel("error")

    val app = api()

    app.get("/notes", logger((r) -> info("request", r), (req) -> "the notes"))

    assertEq(await app.handle(request("GET", "/notes")), "the notes")
    assertEq(written, [])

    reset()

@test
async A_RECORD_RENDERS_AS_THE_LINE_A_PERSON_READS()
    var written = []

    reset()
    setClock(() -> Stamp)
    setSink((r) -> push(written, r))

    val app = api()

    app.post("/notes", logger((r) -> info("request", r), (req) -> { status: 201 }))

    await app.handle(request("POST", "/notes"))

    // `ms` is the one part of it nothing can predict, so what is pinned is everything before it.
    assert(startsWith(text(written[0]), Stamp + " INFO  request method=POST path=/notes status=201 ms="))

    reset()
