// A browser that goes away, and the subscriber the server lets go of.
//
// **THIS IS THE ONE TEST IN THIS PACKAGE THAT BINDS A PORT, AND THERE IS NO OTHER WAY TO WRITE IT.**
// Everything else here drives `api.handle` directly, which is what keeps the suite fast and
// unflakeable -- but what is under test here is `slate:http`'s writer noticing that nobody is
// reading and telling the source so, and a writer noticing a reader has gone is exactly the thing a
// value handed to `handle` cannot have. The rest of the hub's behaviour is in `tests/events.sl`
// with no socket anywhere.
//
// **`slate:net` IS OWED ON THE JAVASCRIPT BACK END**, so under `slate test --js tests` this file
// asks the host for a listener, is told there is none, and answers without asserting anything --
// which is what `sockets()` below is. The names all import; it is calling one that says
// *"`listen` is not in the JavaScript back end yet"*.

import { serve, close as closeServer } from slate:http
import { listen, connect, send, onData, close as closeSocket, localPort } from slate:net
import { stderr } from slate:process

import { api, hub, sse } from "../sluice.sl"

// Whether this host has sockets at all, asked by opening one and letting it go.
//
// **The question is asked of the HOST and not of a flag**, there being nothing to read: a name on
// the JavaScript back end's owed list exists and faults when it is called, so calling it is the
// only way to find out. Asked once, since the answer cannot change.
val Host = { asked: false, has: false }

sockets() -> boolean
    if Host.asked then return Host.has

    Host.asked = true

    try
        val probe = listen(0, (c) -> null)

        closeSocket(probe)

        Host.has = true
    catch e
        // **The note goes to `stderr` and not to `print`**, because the runner keeps what a passing
        // test wrote and shows it only above a failure -- said with `print`, a skip is something
        // nobody is ever told about.
        stderr("tests/hangup.sl: no sockets on this host, so the hang-up tests assert nothing -- " +
            e.message + "\n")

    Host.has

// Everything the client has been sent so far.
heard(seen: object, chunk)
    if chunk != null then seen.text = seen.text + chunk

    null

// Wait for something to become true, or give up. **Bounded, because a test that waits for ever on a
// condition that will not come is a suite that hangs rather than a suite that fails.**
async until(said, tries: integer = 200) -> boolean
    var i = 0

    while i < tries
        if said() then return true

        await sleep(25)

        i = i + 1

    false

@test
async A_SUBSCRIBER_WHOSE_READER_HAS_GONE_IS_TAKEN_OFF_THE_TOPIC()
    // **THE LEAK THIS PACKAGE SHIPPED WITH, AND THE END-TO-END PROOF THAT IT IS OVER.** Until slate
    // 0.0.29 a streamed writer that stopped pulling said nothing at all, so a browser tab that closed
    // left its subscriber on the topic for the life of the program -- and `close()` was the
    // handler's to call from a place that could not tell it had happened. The writer now calls
    // `close` on a source whose response ended with it unexhausted, `sse` forwards that to the
    // source it was given, and this hub's subscriber already answered a `close`. Nothing in this
    // package changed; what changed is underneath it.
    //
    // **`count(topic)` is the only thing that can see any of it**, which is why it exists.
    if !sockets() then return null

    val app = api()
    val feed = hub()

    // **No heartbeat**, so that the only thing writing into the socket is a published event and the
    // moment the writer finds out is a moment this test chose.
    app.get("/events", (req) -> sse(feed.subscribe("notes"), { heartbeat: 0 }))

    val server = serve(0, app)
    val port = localPort(server)
    val seen = { text: "" }
    val c = (await connect("127.0.0.1", port)).value

    onData(c, (chunk) -> heard(seen, chunk))

    await send(c, "GET /events HTTP/1.1\r\nHost: h\r\n\r\n")

    assert(await until(() -> feed.count("notes") == 1), "the subscription is made by the request")

    feed.publish("notes", "first")

    // **The stream is live before anything is taken away**, which is the control: a count that fell
    // to zero because the response never started would prove nothing at all.
    assert(await until(() -> contains(seen.text, "data: first")), "the first event reaches the client")

    // The reader goes. **Nonsense on the same connection is how a socket really goes away
    // mid-response**: the refusal path closes the socket while the response is still being written
    // into it, where a client that merely hangs up leaves writes succeeding until the kernel says
    // otherwise. `slate:http`'s own cut-off tests are written the same way and say so.
    await send(c, "\x01\x02 not a request at all\r\n\r\n")

    closeSocket(c)

    assert(await until(() -> dropped(feed)), "the subscriber is let go of once the writer finds out")

    assertEq(feed.count("notes"), 0)

    closeServer(server)

@test
async A_SUBSCRIBER_WHOSE_READER_IS_STILL_THERE_IS_LEFT_ALONE()
    // **THE CONTROL, and without it the zero above says nothing.** A `close` called at every way out
    // of the writer's loop -- or a source that fell off the topic the first time it was pulled --
    // would make that test pass for a reason that has nothing to do with the reader going away. So
    // this is the same stream with the client kept, reading events as they come, and the count
    // stays where it was.
    if !sockets() then return null

    val app = api()
    val feed = hub()

    app.get("/events", (req) -> sse(feed.subscribe("notes"), { heartbeat: 0 }))

    val server = serve(0, app)
    val port = localPort(server)
    val seen = { text: "" }
    val c = (await connect("127.0.0.1", port)).value

    onData(c, (chunk) -> heard(seen, chunk))

    await send(c, "GET /events HTTP/1.1\r\nHost: h\r\n\r\n")

    assert(await until(() -> feed.count("notes") == 1), "the subscription is made by the request")

    feed.publish("notes", "first")

    assert(await until(() -> contains(seen.text, "data: first")), "the first event reaches the client")

    // **The same poll as above, expected to run out.** It publishes into a socket that is very much
    // there, and what it is waiting for never happens.
    assert(!(await until(() -> dropped(feed), 20)), "a reader that is still reading keeps its place")

    assertEq(feed.count("notes"), 1)

    // **The claim is made; the rest is tidying up, and it is worth a sentence.** A streamed response
    // never runs to `done`, so a server closed under one holds its connection until the socket times
    // out -- five seconds of a suite that is otherwise instant, and five seconds this test spent
    // before it ended the stream itself. Cutting the connection off the way the test above does ends
    // the response, lets the source go, and leaves the loop with nothing in it.
    await send(c, "\x01\x02 not a request at all\r\n\r\n")

    closeSocket(c)

    assert(await until(() -> dropped(feed)), "and the reader that has gone is let go of after all")

    closeServer(server)

// One more event into a socket that has gone, and whether the topic is empty yet.
//
// **The writer finds out by WRITING**, having nothing else to go on: it is parked on `next` until
// something is published, and the failed write is what ends the response and tells the source. So
// the poll publishes rather than merely looking.
dropped(feed: object) -> boolean
    feed.publish("notes", "into a socket that has gone")

    feed.count("notes") == 0
