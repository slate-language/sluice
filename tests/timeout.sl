// `timeout(ms)` -- answering without the handler where the handler is taking too long.
//
// **These are the only tests here that wait for a real clock**, a deadline being a thing that has
// one. The waits are single-digit milliseconds and nothing in them is a race: what is asserted is
// which of two answers arrived, and the two are 5ms and 30ms apart.

import { api, timeout, request, response } from "../sluice.sl"
import { doc, status } from "./support.sl"

@test
async A_HANDLER_THAT_ANSWERS_IN_TIME_IS_UNTOUCHED()
    // The control, and the ordinary case: a deadline nothing came near costs the answer nothing at
    // all -- not an envelope, not a header, not a rewritten body.
    val app = api()

    app.get("/notes", timeout(500, {}, (req) -> "the notes"))

    assertEq(await app.handle(request("GET", "/notes")), "the notes")

@test
async A_HANDLER_THAT_NEVER_ANSWERS_IS_A_503_PROBLEM()
    // **A promise nobody is ever going to settle**, which is the shape of every hang worth being
    // afraid of: a query on a connection that has gone, a lock nobody releases.
    stuck(req) = pending()

    val app = api()

    app.get("/notes", timeout(5, {}, stuck))

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 503)
    assertEq(doc(r).title, "Service Unavailable")
    assertEq(doc(r).detail, "this request took longer than 5ms to answer")
    assertEq(doc(r).instance, "/notes")

@test
async AN_ANSWER_THAT_ARRIVES_TOO_LATE_IS_DROPPED_AND_COUNTED()
    // **The half that is easy to leave out.** The response has already gone, so a handler finishing
    // afterwards is writing into a socket somebody else has answered -- and dropping it silently
    // would make a service that is quietly missing every deadline look like one that is well.
    var late = []

    async slow(req)
        await sleep(30)

        "the notes"

    val app = api()

    app.get("/notes", timeout(5, { onLate: (v) -> push(late, v) }, slow))

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 503)
    assertEq(late, [])

    await sleep(60)

    assertEq(late, [{ ok: true, value: "the notes" }], "the handler did finish, and its answer went nowhere")

@test
async A_HANDLER_THAT_FAULTS_TOO_LATE_IS_REPORTED_RATHER_THAN_LOST()
    // **The case that would otherwise vanish.** The request has been answered, so there is nothing
    // left to raise the fault from -- and putting it back on the loop would stop the server over a
    // defect the deadline itself probably caused. It comes through the same channel as a late answer,
    // as the other half of a result.
    var late = []
    var caught = null

    noted(e)
        caught = e

    async breaking(req)
        await sleep(30)

        throw "the note store went away"

    val app = api({ onFault: noted })

    app.get("/notes", timeout(5, { onLate: (v) -> push(late, v) }, breaking))

    assertEq(status(await app.handle(request("GET", "/notes"))), 503)

    await sleep(60)

    assertEq(len(late), 1)
    assertEq(late[0].ok, false)
    assertEq(late[0].error.message, "the note store went away")
    assertEq(caught, null, "and it is not the 500 of a request that has already been answered")

@test
async A_HANDLER_THAT_BEATS_ITS_DEADLINE_IS_NOT_COUNTED_LATE()
    // The control for the one above.
    var late = []

    async quick(req)
        await sleep(1)

        "the notes"

    val app = api()

    app.get("/notes", timeout(200, { onLate: (v) -> push(late, v) }, quick))

    assertEq(await app.handle(request("GET", "/notes")), "the notes")

    await sleep(20)

    assertEq(late, [])

@test
async status_IS_HOW_A_HANDLER_THAT_IS_REALLY_A_PROXY_SAYS_504()
    // **503 is the default because this server is the ORIGIN.** RFC 9110 gives 504 to a server
    // "acting as a gateway or proxy" that did not hear from an upstream one in time; a handler
    // calling something else really is that, and says so here.
    stuck(req) = pending()

    val app = api()

    app.get("/notes", timeout(5, { status: 504 }, stuck))

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 504)
    assertEq(doc(r).title, "Gateway Timeout")

@test
async A_HANDLER_THAT_FAULTS_INSIDE_ITS_DEADLINE_IS_STILL_THE_ORDINARY_500()
    // **A deadline is not an error handler.** The fault is carried across the gate and raised again
    // on the other side, so what a client is told is what `handle` tells it about any defect.
    var caught = null

    noted(e)
        caught = e.message

    breaking(req)
        throw "the note store is not there"

    val app = api({ onFault: noted })

    app.get("/notes", timeout(500, {}, breaking))

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 500)
    assertEq(doc(r).title, "Internal Server Error")
    assertEq(caught, "the note store is not there")

@test
async A_FAULT_AFTER_AN_await_IS_CARRIED_ACROSS_THE_GATE_TOO()
    var caught = null

    noted(e)
        caught = e.message

    async breaking(req)
        await sleep(1)

        throw "the note store went away"

    val app = api({ onFault: noted })

    app.get("/notes", timeout(500, {}, breaking))

    assertEq(status(await app.handle(request("GET", "/notes"))), 500)
    assertEq(caught, "the note store went away")

@test
async A_HANDLER_THAT_NEEDS_NO_CLOCK_BEATS_A_DEADLINE_OF_ZERO()
    // **Because a settled promise resumes before a timer does**, which is slate's two queues and not
    // an accident: what a suspended call is owed is drained to empty between every turn of the one
    // that answers timers. So a handler with no waiting in it answers even where it was given no time
    // at all, and a deadline is a bound on WAITING rather than a coin toss.
    val app = api()

    app.get("/notes", timeout(0, {}, (req) -> "the notes"))

    assertEq(await app.handle(request("GET", "/notes")), "the notes")

@test
async THE_GUARD_PRINTS_THE_DEADLINE_IT_WAS_GIVEN()
    val app = api()

    app.get("/notes", timeout(250, {}, (req) -> "the notes"))

    assertEq(app.routes()[0].guards, ["timeout(250ms)"])
