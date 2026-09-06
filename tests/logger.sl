// `logger(sink)` -- what happened, once the answer is known.

import { api, logger, body, stack, request } from "../sluice.sl"
import { status } from "./support.sl"

type NewNote = { title: string }

@test
async THE_SINK_IS_GIVEN_A_RECORD_AND_NOT_A_LINE_OF_TEXT()
    // A program can print it, count it, or send it somewhere structured; this package does not
    // decide which by handing over a string.
    var seen = []
    val app = api()

    app.get("/notes/:id", logger((r) -> push(seen, r), (req) -> "note " + req.params.id))

    await app.handle(request("GET", "/notes/7"))

    assertEq(seen.length, 1)
    assertEq(seen[0].method, "GET")
    assertEq(seen[0].path, "/notes/7")
    assertEq(seen[0].status, 200)
    assert(seen[0].ms is integer, "how long it took, in milliseconds")

@test
async THE_STATUS_LOGGED_IS_THE_ONE_THAT_WENT_OUT_WHOEVER_DECIDED_IT()
    // A guard under the logger refusing is still an answer, and the number is the one a client saw.
    var seen = []
    val app = api()

    app.post("/notes", stack([logger((r) -> push(seen, r)), body(NewNote)])((req) -> { status: 201 }))

    await app.handle(request("POST", "/notes", { body: { title: "a" } }))
    await app.handle(request("POST", "/notes", { body: "{ not json" }))

    assertEq([seen[0].status, seen[1].status], [201, 400])

@test
async THE_HANDLERS_OWN_ANSWER_IS_HANDED_ON_EXACTLY_AS_IT_WAS()
    // Reading a status off an answer must not turn a string into an envelope.
    val app = api()

    app.get("/notes", logger(print, (req) -> "the notes"))

    assertEq(await app.handle(request("GET", "/notes")), "the notes")
