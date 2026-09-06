// `requestId` -- one name for this request, on the request and on the answer.

import { api, requestId, logger, stack, request, response } from "../sluice.sl"
import { status, header } from "./support.sl"

@test
async AN_ID_A_CLIENT_SENT_IS_TAKEN_AND_ECHOED()
    // **A request already named further up keeps that name**, which is the whole of what makes an id
    // a TRACE id: a gateway, a load balancer or a caller has already written it in its own log, and a
    // server that renamed it would break the one join a person is trying to make.
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val r = await app.handle(request("GET", "/notes", { headers: { "X-Request-Id": "abc-123" } }))

    assertEq(response(r).body, "abc-123")
    assertEq(header(r, "x-request-id"), "abc-123")

@test
async A_REQUEST_THAT_ARRIVED_WITH_NO_ID_IS_GIVEN_ONE()
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val r = await app.handle(request("GET", "/notes"))
    val id = response(r).body

    // **22 characters, which is 16 bytes in base64url** -- the same randomness the hex spelling
    // carried in 32, on a value written into a header on every answer and into every log line.
    assertEq(id.length, 22)
    assertEq(header(r, "x-request-id"), id)

@test
async TWO_REQUESTS_ARE_NOT_GIVEN_THE_SAME_ID()
    // The control. Without it the length above could be right for an id that never changes.
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val one = response(await app.handle(request("GET", "/notes"))).body
    val two = response(await app.handle(request("GET", "/notes"))).body

    assert(one != two, "16 random bytes, not a constant")

@test
async AN_ID_THIS_GUARD_GENERATED_IS_ONE_IT_WOULD_ACCEPT_FROM_A_CLIENT()
    // **The alphabet claim, checked rather than asserted in a comment.** base64url is `-` and `_`
    // beside the letters and digits, and every one of them is in the set an id may be made of -- so
    // a second server behind this one, handed the id this one wrote, echoes it rather than replacing
    // it. A generator whose output its own check refused would break the join the header exists for,
    // and nothing else in this file would have noticed.
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val made = response(await app.handle(request("GET", "/notes"))).body
    val again = await app.handle(request("GET", "/notes", { headers: { "X-Request-Id": made } }))

    assertEq(response(again).body, made)

@test
async AN_ID_CARRYING_A_LINE_BREAK_IS_REPLACED_RATHER_THAN_ECHOED()
    // **THIS IS THE ONE THAT MATTERS.** The value goes back out in a response header, so a client
    // that could put a carriage return in it would be writing headers of its own into every answer.
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val r = await app.handle(request("GET", "/notes",
        { headers: { "X-Request-Id": "abc\r\nX-Admin: true" } }))

    assertEq(response(r).body.length, 22)
    assert(!contains(header(r, "x-request-id"), "X-Admin"))

@test
async AN_ID_LONGER_THAN_THE_LIMIT_IS_REPLACED()
    // An id of unbounded length is a log line of unbounded length, on every line the request writes.
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val r = await app.handle(request("GET", "/notes", { headers: { "X-Request-Id": repeat("a", 201) } }))

    assertEq(response(r).body.length, 22)

@test
async AN_ID_THAT_IS_EMPTY_OR_A_SPACE_IS_REPLACED()
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    assertEq(response(await app.handle(request("GET", "/notes", { headers: { "x-request-id": "" } }))).body.length, 22)
    assertEq(response(await app.handle(request("GET", "/notes", { headers: { "x-request-id": "a b" } }))).body.length, 22)

@test
async THE_HEADER_AND_THE_GENERATOR_ARE_BOTH_THE_PROGRAMS()
    // A service that already names its requests something else says so, rather than carrying two.
    var n = 0

    counted() -> string
        n = n + 1

        "req-" + string(n)

    val app = api()

    app.get("/notes", requestId({ header: "Trace-Id", generate: counted }, (req) -> req.id))

    val r = await app.handle(request("GET", "/notes"))

    assertEq(response(r).body, "req-1")
    assertEq(header(r, "Trace-Id"), "req-1")
    assertEq(header(r, "X-Request-Id"), null)

@test
async A_UUID_AND_A_traceparent_BOTH_SURVIVE_THE_CHECK()
    // The characters the check allows are the ones a trace header really carries, and the test that
    // says so is the two shapes anybody would send.
    val app = api()

    app.get("/notes", requestId({}, (req) -> req.id))

    val uuid = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    val parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    assertEq(response(await app.handle(request("GET", "/notes", { headers: { "x-request-id": uuid } }))).body, uuid)
    assertEq(response(await app.handle(request("GET", "/notes", { headers: { "x-request-id": parent } }))).body, parent)

// -- and what a log makes of it ---------------------------------------------------------------------

@test
async THE_LOGGERS_RECORD_CARRIES_THE_ID()
    // **The point of the whole guard.** A record with the id in it is a log a person can follow one
    // request through; without it every line about one request is a line about all of them.
    var seen = []
    val app = api()

    app.get("/notes/:id", stack([requestId({}), logger((r) -> push(seen, r))])((req) -> "note"))

    await app.handle(request("GET", "/notes/7", { headers: { "x-request-id": "abc-123" } }))

    assertEq(seen[0].id, "abc-123")
    assertEq(seen[0].status, 200)

@test
async A_LOGGER_ABOVE_THE_ID_SEES_A_REQUEST_THAT_HAS_NOT_GOT_ONE_YET()
    // **A guard adds to the request it hands DOWN**, so a stack reads in request order and the id has
    // to be put on above whatever means to read it. This is the shape somebody will write by mistake,
    // and what it does is worth pinning rather than leaving to be discovered in a log.
    var seen = []
    val app = api()

    app.get("/notes", stack([logger((r) -> push(seen, r)), requestId({})])((req) -> "note"))

    val r = await app.handle(request("GET", "/notes", { headers: { "x-request-id": "abc-123" } }))

    assertEq(has(seen[0], "id"), false)
    assertEq(header(r, "x-request-id"), "abc-123", "and the answer still carries it")

@test
async A_RECORD_HAS_NO_id_WHERE_NOTHING_PUT_ONE_THERE()
    // Absent rather than `null`: a record whose members depend on which guards ran is one a reader
    // can take at face value.
    var seen = []
    val app = api()

    app.get("/notes", logger((r) -> push(seen, r), (req) -> "the notes"))

    await app.handle(request("GET", "/notes"))

    assertEq(has(seen[0], "id"), false)

@test
async THE_GUARD_PRINTS_UNDER_ITS_OWN_NAME()
    val app = api()

    app.get("/notes", requestId({}, (req) -> "the notes"))

    assertEq(app.routes()[0].guards, ["requestId"])
