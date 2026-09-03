// A defect in a handler: the client is told, and the fault is put back.
//
// **Every test here passes `onFault`**, and it has to. Without it the fault goes back on the loop --
// which is the right thing for a server and would end this suite, since a fault reaching the loop
// stops the program. `check/faults.sl` is the hand-run driver that shows the default doing exactly
// that, and it is not under `tests/` for that reason.

import { api, stack, logger, request } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

@test
async A_HANDLER_THAT_FAULTS_ANSWERS_A_500_PROBLEM()
    var caught = null

    noted(e)
        caught = e.message

    breaking(req)
        throw "the note store is not there"

    val app = api({ onFault: noted })

    app.get("/notes", breaking)

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 500)
    assertEq(header(r, "content-type"), "application/problem+json")
    assertEq(doc(r).title, "Internal Server Error")
    assertEq(doc(r).detail, "this request was not answered")
    assertEq(doc(r).instance, "/notes")

@test
async THE_FAULT_ITSELF_REACHES_onFault_WITH_ITS_OWN_WORDS_AND_PLACE()
    // **The detail a client is told and the fault a program is told are different things**, and
    // that is not an oversight: a 500 that quoted the defect would hand the inside of the program
    // to whoever could make it fall over.
    var caught = null

    noted(e)
        caught = e

    breaking(req)
        throw "the note store is not there"

    val app = api({ onFault: noted })

    app.get("/notes", breaking)

    val r = await app.handle(request("GET", "/notes"))

    assertEq(caught.message, "the note store is not there")
    assert(caught.line is integer, "a fault says where it came from")
    assert(caught.file is string)
    assert(!contains(r.body, "note store"), "and none of it is in what the client is told")

@test
async A_FAULT_FROM_INSIDE_A_GUARD_IS_THE_SAME_500()
    var caught = null

    noted(e)
        caught = e.message

    breaking(req)
        throw "gone"

    val app = api({ onFault: noted })

    app.get("/notes", logger(print, breaking))

    assertEq(status(await app.handle(request("GET", "/notes"))), 500)
    assertEq(caught, "gone")

@test
async A_FAULT_AFTER_AN_await_IS_CAUGHT_TOO()
    // A coroutine carries its handlers with it when it is set aside, so a promise that fails later
    // still raises inside the `try` that was written around the `await`.
    var caught = null

    noted(e)
        caught = e.message

    async breaking(req)
        await sleep(1)

        throw "it failed later"

    val app = api({ onFault: noted })

    app.get("/notes", breaking)

    assertEq(status(await app.handle(request("GET", "/notes"))), 500)
    assertEq(caught, "it failed later")

@test
async A_notFound_HANDLER_THAT_FAULTS_IS_A_500_AND_NOT_A_404()
    var caught = null

    noted(e)
        caught = e.message

    breaking(req)
        throw "the fallback is wrong"

    val app = api({ onFault: noted })

    app.get("/notes", (req) -> "the notes")
    app.notFound(breaking)

    assertEq(status(await app.handle(request("GET", "/nowhere"))), 500)
    assertEq(caught, "the fallback is wrong")

@test
async A_GUARD_ABOVE_A_FAULTING_HANDLER_DOES_NOT_LOG_IT()
    // The fault carries on up to `handle`, which answers the 500 and puts it back. A guard that
    // swallowed it to log it would be deciding that a defect is a log line.
    var seen = []
    var caught = null

    noted(e)
        caught = e.message

    breaking(req)
        throw "gone"

    val app = api({ onFault: noted })

    app.get("/notes", stack([logger((r) -> push(seen, r))])(breaking))

    assertEq(status(await app.handle(request("GET", "/notes"))), 500)
    assertEq(seen, [])
    assertEq(caught, "gone")
