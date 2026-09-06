// Stopping: the in-flight count, the drain, and the signals that begin one.
//
// **What closing means is an option, and that is what keeps this in the ordinary suite.** The one
// thing a drain does that touches the world is let go of a socket, so `close` is a function the
// caller may give -- which is also what a server that is more than a socket would need.

import { api, drain, onShutdown, request } from "../sluice.sl"
import { doc, status } from "./support.sl"

// An api with one route that answers whatever promise the test settles.
waiting(gate) -> object
    val app = api()

    app.get("/notes", (req) -> gate)

    app

@test
async NOTHING_IS_IN_FLIGHT_BEFORE_A_REQUEST_AND_NOTHING_AFTER_ONE()
    val app = api()

    app.get("/notes", (req) -> "the notes")

    assertEq(app.inflight(), 0)

    await app.handle(request("GET", "/notes"))

    assertEq(app.inflight(), 0)

@test
async A_REQUEST_BEING_ANSWERED_IS_IN_FLIGHT()
    // **`handle` is the one function every request goes through**, which is why the count is there
    // rather than in a guard -- a guard would never see the requests no route matched, and those are
    // exactly the ones a client retries during a shutdown.
    val gate = pending()
    val app = waiting(gate)
    val flight = app.handle(request("GET", "/notes"))

    assertEq(app.inflight(), 1)

    settle(gate, "the notes")

    assertEq(await flight, "the notes")
    assertEq(app.inflight(), 0)

@test
async A_REQUEST_THAT_MATCHED_NOTHING_IS_COUNTED_TOO()
    val app = api()

    assertEq(status(await app.handle(request("GET", "/nowhere"))), 404)
    assertEq(app.inflight(), 0)

@test
async A_HANDLER_THAT_FAULTS_IS_COUNTED_BACK_OUT()
    // **slate has no `finally`**, so the decrement is written twice -- and without the second one a
    // single defect would leave every later shutdown waiting out its whole grace for a request that
    // ended minutes ago.
    noted(e) = null

    breaking(req)
        throw "the note store is not there"

    val app = api({ onFault: noted })

    app.get("/notes", breaking)

    assertEq(status(await app.handle(request("GET", "/notes"))), 500)
    assertEq(app.inflight(), 0)

// -- draining ----------------------------------------------------------------------------------------

@test
async A_DRAINING_SERVER_REFUSES_A_NEW_REQUEST_WITH_A_503()
    // **503 is the load balancer's cue to send the next one elsewhere**, which is the whole reason a
    // draining server answers at all rather than closing the connection.
    val app = api()

    app.get("/notes", (req) -> "the notes")

    assertEq(app.draining(), false)

    app.stop()

    assertEq(app.draining(), true)

    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 503)
    assertEq(doc(r).title, "Service Unavailable")
    assertEq(doc(r).detail, "this server is shutting down")
    assertEq(doc(r).instance, "/notes")

@test
async A_DRAINING_SERVER_FAILS_ITS_OWN_HEALTH_CHECK()
    // **The order a rolling deployment needs**: stop being sent traffic, then finish what you have.
    // It falls out of the counting rather than being arranged.
    val app = api()

    app.health()

    assertEq(status(await app.handle(request("GET", "/health"))), 200)

    app.stop()

    assertEq(status(await app.handle(request("GET", "/health"))), 503)

@test
async A_REQUEST_IN_FLIGHT_FINISHES_INSIDE_THE_GRACE_AND_THEN_THE_SERVER_CLOSES()
    var closed = []
    val gate = pending()
    val app = waiting(gate)
    val flight = app.handle(request("GET", "/notes"))

    assertEq(app.inflight(), 1)

    val stopping = app.drain("the server", { grace: 2000, poll: 1, close: (s) -> push(closed, s) })

    // Refusing comes first, so nothing new can extend the wait it is inside.
    assertEq(app.draining(), true)
    assertEq(closed, [], "and the socket is not let go of until the request is done")

    settle(gate, "the notes")

    val outcome = await stopping

    assertEq(outcome.cut, 0)
    assertEq(closed, ["the server"])
    assertEq(await flight, "the notes")

@test
async A_REQUEST_STILL_RUNNING_AT_THE_GRACE_IS_CUT_AND_THE_NUMBER_IS_ANSWERED()
    // **A shutdown that regularly cuts requests off is a grace that is too short or a handler that is
    // too slow**, and neither is visible unless the number is.
    var closed = []
    val gate = pending()
    val app = waiting(gate)
    val flight = app.handle(request("GET", "/notes"))

    val outcome = await app.drain("the server", { grace: 20, poll: 2, close: (s) -> push(closed, s) })

    assertEq(outcome.cut, 1)
    assert(outcome.waited >= 20, "it waited the whole grace out first")
    assertEq(closed, ["the server"], "and let go of the socket anyway")

    settle(gate, "too late")

    assertEq(await flight, "too late")

@test
async A_DRAIN_WITH_NOTHING_IN_FLIGHT_CLOSES_AT_ONCE()
    var closed = []
    val app = api()

    val outcome = await app.drain("the server", { grace: 5000, poll: 10, close: (s) -> push(closed, s) })

    assertEq(outcome.cut, 0)
    assertEq(outcome.waited, 0, "nothing to wait for is nothing waited")
    assertEq(closed, ["the server"])

@test
async DRAINING_TWICE_IS_THE_SAME_AS_DRAINING_ONCE()
    // A signal handler and a `main` that finishes are both entitled to call it, and `slate:http`'s
    // own `close` is already a no-op the second time -- so nothing here has to guard against it and
    // nothing here may fault over it.
    var closed = []
    val app = api()

    await app.drain("the server", { grace: 100, poll: 1, close: (s) -> push(closed, s) })

    val outcome = await app.drain("the server", { grace: 100, poll: 1, close: (s) -> push(closed, s) })

    assertEq(outcome.cut, 0)
    assertEq(closed, ["the server", "the server"])

@test
async drain_ON_ITS_OWN_SERVES_A_PROGRAM_THAT_IS_NOT_AN_api()
    // The exported one, for a program serving a bare handler. **With no counter it waits for
    // nothing**, which is `slate:http`'s own `close` with the connections given a moment to finish.
    var closed = []

    val outcome = await drain("the server", { grace: 5000, close: (s) -> push(closed, s) })

    assertEq(outcome, { cut: 0, waited: 0 })
    assertEq(closed, ["the server"])

@test
async A_COUNTER_OF_THE_PROGRAMS_OWN_IS_WHAT_A_DRAIN_WAITS_ON()
    var left = 2
    var closed = []

    counted() -> integer
        left = left - 1

        left

    val outcome = await drain("the server", { grace: 1000, poll: 1, inflight: counted,
        close: (s) -> push(closed, s) })

    assertEq(outcome.cut, 0)
    assertEq(closed, ["the server"])

// -- the signals that begin one ------------------------------------------------------------------------

@test
async onShutdown_WATCHES_BOTH_SIGNALS()
    // **A program that handled one and not the other** would shut down cleanly in production and be
    // killed in a terminal.
    var watched = []

    on(name: string, fn: function) -> integer
        push(watched, name)

        watched.length

    off(id) = null

    onShutdown(() -> null, { on: on, off: off })

    assertEq(watched, ["SIGTERM", "SIGINT"])

@test
async THE_SIGNAL_RUNS_THE_ACTION()
    var handlers = {}
    var ran = 0

    on(name: string, fn: function) -> integer
        handlers[name] = fn

        keys(handlers).length

    off(id) = null

    fired()
        ran = ran + 1

        null

    onShutdown(fired, { on: on, off: off })

    handlers["SIGTERM"]()

    assertEq(ran, 1)

@test
async THE_ANSWER_IS_HOW_TO_STOP_WATCHING()
    var stopped = []

    on(name: string, fn: function) -> integer = name.length

    off(id)
        push(stopped, id)

        null

    val stop = onShutdown(() -> null, { on: on, off: off })

    assertEq(stopped, [])

    stop()

    assertEq(stopped, [7, 6], "one id per signal, in the order they were watched")

@test
async WHICH_SIGNALS_ARE_WATCHED_IS_THE_PROGRAMS()
    var watched = []

    on(name: string, fn: function) -> integer
        push(watched, name)

        watched.length

    off(id) = null

    onShutdown(() -> null, { signals: ["SIGHUP"], on: on, off: off })

    assertEq(watched, ["SIGHUP"])

@test
async A_SIGNAL_DRAINING_AN_api_IS_THE_WHOLE_SHAPE_OF_A_SHUTDOWN()
    // What a program actually writes, with the two host seams driven: a signal arrives, the api stops
    // taking requests, what is in hand finishes, and the socket is let go of.
    var handlers = {}
    var closed = []

    on(name: string, fn: function) -> integer
        handlers[name] = fn

        keys(handlers).length

    off(id) = null

    val gate = pending()
    val app = waiting(gate)
    val flight = app.handle(request("GET", "/notes"))

    var stopping = null

    asked()
        stopping = app.drain("the server", { grace: 2000, poll: 1, close: (s) -> push(closed, s) })

        null

    onShutdown(asked, { on: on, off: off })

    handlers["SIGTERM"]()

    assertEq(app.draining(), true)
    assertEq(status(await app.handle(request("GET", "/notes"))), 503)

    settle(gate, "the notes")

    assertEq((await stopping).cut, 0)
    assertEq(closed, ["the server"])
    assertEq(await flight, "the notes")
