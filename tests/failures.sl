// `failures` -- a failure is a value the handler returns, and the mapping is checked by slate.

import { api, stack, json, logger, cors, guardOf, request } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

// What this application can fail with. **A closed set**, which is what makes the `match` below worth
// checking: a variant added here and left unanswered is refused before the program runs.
data Failure
    NoSuchNote(id)
    Taken(title)
    NotYours

answer(f: Failure) = f match
    NoSuchNote(id) -> { status: 404, body: "no note " + id }
    Taken(title) -> { status: 409, body: title + " is taken" }
    NotYours -> { status: 403, body: "not yours" }

made() -> object
    val app = api()

    app.failures(Failure, answer)

    app.get("/notes/:id", (req) ->
        if req.params.id == "7" then json({ id: 7 }, 200) else NoSuchNote(req.params.id))

    app.post("/notes", (req) -> Taken("first"))
    app.delete("/notes/:id", (req) -> NotYours)

    app

@test
async A_HANDLER_THAT_ANSWERS_A_RESPONSE_IS_LEFT_ALONE()
    val r = await made().handle(request("GET", "/notes/7"))

    assertEq(status(r), 200)
    assertEq(doc(r).id, 7)

@test
async EVERY_VARIANT_HAS_THE_HTTP_ANSWER_THE_MAPPING_GAVE_IT()
    val app = made()

    assertEq(await app.handle(request("GET", "/notes/9")), { status: 404, body: "no note 9" })
    assertEq(await app.handle(request("POST", "/notes")), { status: 409, body: "first is taken" })
    assertEq(await app.handle(request("DELETE", "/notes/7")), { status: 403, body: "not yours" })

@test
async A_FIELDLESS_VARIANT_IS_A_VALUE_AND_IS_STILL_RECOGNISED()
    // `NotYours` is the value, not `NotYours()`, and the test for it is identity.
    assertEq(status(await made().handle(request("DELETE", "/notes/1"))), 403)

@test
async WITHOUT_A_MAPPING_A_FAILURE_IS_WHATEVER_slate_http_MAKES_OF_IT()
    // Nothing is guessed at: an application that never registered its failures gets its value back
    // as the answer, which is what a handler returning anything else would get.
    val app = api()

    app.get("/notes/:id", (req) -> NoSuchNote(req.params.id))

    assertEq(await app.handle(request("GET", "/notes/9")), NoSuchNote("9"))

@test
async THE_MAPPING_MAY_ANSWER_A_PROMISE()
    async slowly(f: Failure)
        await sleep(1)

        answer(f)

    val app = api()

    app.failures(Failure, slowly)
    app.get("/notes/:id", (req) -> NoSuchNote(req.params.id))

    assertEq(await app.handle(request("GET", "/notes/9")), { status: 404, body: "no note 9" })

@test
async A_MAPPING_THAT_FAULTS_IS_A_DEFECT_AND_ANSWERS_500()
    // A mapping that faults is a defect in the application exactly as a handler that faults is, and
    // it gets the same answer rather than escaping into the server.
    var caught = null

    noted(e)
        caught = e.message

    breaking(f: Failure)
        throw "the mapping is wrong"

    val app = api({ onFault: noted })

    app.failures(Failure, breaking)
    app.get("/notes/:id", (req) -> NoSuchNote(req.params.id))

    assertEq(status(await app.handle(request("GET", "/notes/9"))), 500)
    assertEq(caught, "the mapping is wrong")

@test
async THE_MAPPING_RUNS_UNDER_THE_GUARDS_SO_EVERY_ONE_OF_THEM_SEES_HTTP()
    // **This is the one thing about the order that is not obvious, and it is load-bearing.** A
    // failure is what the handler answered; a guard above it must see the response that goes out.
    // A logger over an unmapped failure would report `200` for what a client received as `409`.
    var seen = []
    val app = api()

    app.failures(Failure, answer)
    app.post("/notes", logger((r) -> push(seen, r), (req) -> Taken("first")))

    assertEq(await app.handle(request("POST", "/notes")), { status: 409, body: "first is taken" })
    assertEq(seen[0].status, 409)

@test
async A_GUARD_THAT_READS_THE_ANSWER_DOES_NOT_HIDE_A_FAILURE_FROM_THE_MAPPING()
    // `cors` turns whatever it is given into an envelope so it can add a header. Over an unmapped
    // failure that envelope is no longer recognisable as one, and the failure would go out as a
    // `200` with a rendered data value in the body.
    val app = api()

    app.failures(Failure, answer)
    app.post("/notes", cors({}, (req) -> Taken("first")))

    val r = await app.handle(request("POST", "/notes", { headers: { Origin: "https://a.example" } }))

    assertEq(status(r), 409)
    assertEq(header(r, "Access-Control-Allow-Origin"), "*")

// -- a guard that refuses by RETURNING a failure ---------------------------------------------------

// **A guard of the application's own, refusing the way a handler does.** It used to be that only a
// handler could: the mapping sat under every guard, so a `Failure` a guard returned met nothing that
// would translate it and went out as a `200` carrying a rendered data value. The mapping is applied
// between every pair of guards now, so whatever answered a failure, the thing above it sees HTTP.
val needsNote = guardOf("needsNote", (h) -> (req) -> unlessAnonymous(h, req))

unlessAnonymous(h, req) = if has(req.headers, "x-note") then h(req) else NotYours

carrying(v) -> object = { headers: { "X-Note": v } }

@test
async A_FAILURE_A_GUARD_RETURNS_IS_MAPPED_EXACTLY_AS_A_HANDLER_S_IS()
    val app = api()

    app.failures(Failure, answer)
    app.get("/notes/:id", stack([needsNote])((req) -> json({ id: 7 }, 200)))

    assertEq(await app.handle(request("GET", "/notes/7")), { status: 403, body: "not yours" })
    // The control: the same route, the same guard, and a request the guard lets through.
    assertEq(status(await app.handle(request("GET", "/notes/7", carrying("yes")))), 200)

@test
async A_LOGGER_ABOVE_A_REFUSING_GUARD_REPORTS_THE_STATUS_THE_CLIENT_GOT()
    // The same thing the handler case has always promised, read one level out: a guard above a
    // refusal must see the response and not the failure value.
    var seen = []
    val app = api()

    app.failures(Failure, answer)
    app.get("/notes/:id", stack([logger((r) -> push(seen, r)), needsNote])((req) -> json({ id: 7 }, 200)))

    assertEq(status(await app.handle(request("GET", "/notes/7"))), 403)
    assertEq(seen[0].status, 403)

@test
async A_GUARD_THAT_READS_THE_ANSWER_DOES_NOT_HIDE_A_REFUSING_GUARD_S_FAILURE()
    // `cors` over an untranslated failure wraps it in an envelope, which is what stopped it being
    // recognisable as a failure at all. It sees a `403` here, the same as over a handler's.
    val app = api()

    app.failures(Failure, answer)
    app.get("/notes/:id", stack([cors({}), needsNote])((req) -> json({ id: 7 }, 200)))

    val r = await app.handle(request("GET", "/notes/7", { headers: { Origin: "https://a.example" } }))

    assertEq(status(r), 403)
    assertEq(header(r, "Access-Control-Allow-Origin"), "*")

@test
async WITHOUT_A_MAPPING_A_GUARD_S_FAILURE_IS_WHAT_A_HANDLER_S_IS()
    // Nothing is guessed at here either: an application that registered no failures gets the value
    // back as the answer, whichever level of the composition returned it.
    val app = api()

    app.get("/notes/:id", stack([needsNote])((req) -> json({ id: 7 }, 200)))

    assertEq(await app.handle(request("GET", "/notes/7")), NotYours)
