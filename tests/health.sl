// `app.health(path, check)` -- the one route a deployment asks about rather than a client.

import { api, request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

@test
async health_ANSWERS_200_AND_A_STATUS_OF_ok()
    // **A body and not an empty 200**, because what reads this is a load balancer with a body
    // matcher and a person with `curl`, and neither is served by a blank page.
    val app = api()

    app.health()

    val r = await app.handle(request("GET", "/health"))

    assertEq(status(r), 200)
    assertEq(header(r, "Content-Type"), "application/json")
    assertEq(doc(r).status, "ok")

@test
async THE_PATH_IS_THE_PROGRAMS_WHERE_IT_SAYS_SO()
    val app = api()

    app.health("/-/ready")

    assertEq(status(await app.handle(request("GET", "/-/ready"))), 200)
    assertEq(status(await app.handle(request("GET", "/health"))), 404)

@test
async A_CHECK_WITH_NOTHING_TO_REPORT_IS_WELL()
    var asked = 0

    fine() -> array
        asked = asked + 1

        []

    val app = api()

    app.health("/health", fine)

    assertEq(status(await app.handle(request("GET", "/health"))), 200)
    assertEq(asked, 1, "and the check really was asked")

@test
async A_CHECK_THAT_REPORTS_REASONS_IS_A_503_CARRYING_THEM()
    // **A boolean would make a failing health check a page nobody can act on.** The operator is
    // looking at this because something is wrong and wants to be told which of the four things it is.
    unwell() -> array = ["the note store is not answering", "the queue is 40,000 deep"]

    val app = api()

    app.health("/health", unwell)

    val r = await app.handle(request("GET", "/health"))

    assertEq(status(r), 503)
    assertEq(header(r, "Content-Type"), "application/problem+json")
    assertEq(doc(r).title, "Service Unavailable")
    assertEq(doc(r).detail, "this service is not well")
    assertEq(doc(r).reasons, ["the note store is not answering", "the queue is 40,000 deep"])

@test
async ONE_REASON_MAY_BE_WRITTEN_AS_ONE_STRING()
    unwell() -> string = "the note store is not answering"

    val app = api()

    app.health("/health", unwell)

    assertEq(doc(await app.handle(request("GET", "/health"))).reasons, ["the note store is not answering"])

@test
async A_CHECK_ANSWERING_NOTHING_AT_ALL_IS_WELL()
    quiet() = null

    val app = api()

    app.health("/health", quiet)

    assertEq(status(await app.handle(request("GET", "/health"))), 200)

@test
async A_CHECK_MAY_ANSWER_A_PROMISE()
    // A check that asks a database is the ordinary one, so it is awaited like everything else here.
    async asked() -> array
        await sleep(1)

        ["the note store is not answering"]

    val app = api()

    app.health("/health", asked)

    assertEq(status(await app.handle(request("GET", "/health"))), 503)

@test
async A_CHECK_THAT_ANSWERS_SOMETHING_ELSE_IS_THE_PROGRAMS_OWN_MISTAKE()
    // **A refusal here would turn a defect into a service reporting itself well**, which is the one
    // answer a health check must never give by accident. So it faults, exactly as a `bearer`
    // verifier that does not answer a result does.
    var caught = null

    noted(e)
        caught = e.message

    confused() -> boolean = true

    val app = api({ onFault: noted })

    app.health("/health", confused)

    assertEq(status(await app.handle(request("GET", "/health"))), 500)
    assert(startsWith(caught, "a `health` check answers the reasons it is unwell"))

@test
async health_IS_A_ROUTE_UNDER_NO_GUARDS_AT_ALL()
    // **The thing asking is not a client of this API**: it has no token, is not to be logged with the
    // traffic and is not to be counted against a rate limit. So it is added on its own.
    val app = api()

    app.health()

    assertEq(app.routes(), [{ method: "GET", path: "/health", guards: [], handler: app.routes()[0].handler }])

@test
async ONLY_A_GET_ANSWERS_IT()
    val app = api()

    app.health()

    assertEq(status(await app.handle(request("POST", "/health"))), 405)
