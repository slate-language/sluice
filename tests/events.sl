// `hub()` and `sse()` -- publishing to whoever is listening, and the stream they listen through.
//
// **Not one of these needs a port.** A streamed response is a source, so a test pulls events out of
// a handler's answer exactly as the server would, which is what keeps this in the ordinary suite.

import { api, hub, sse, cors, logger, request, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

@test
async ONE_PUBLISH_REACHES_EVERYBODY_ON_THE_TOPIC()
    val feed = hub()
    val one = feed.subscribe("notes")
    val two = feed.subscribe("notes")

    feed.publish("notes", "first")

    assertEq((await one.next()).value, "first")
    assertEq((await two.next()).value, "first")

@test
async A_PUBLISH_TO_ANOTHER_TOPIC_REACHES_NOBODY()
    // **Topics are whatever the program calls them** and nothing registers one, so this is what says
    // a subscriber is on one topic rather than on the hub.
    val feed = hub()
    val here = feed.subscribe("notes")

    feed.publish("elsewhere", "not this")
    feed.publish("notes", "this")

    assertEq((await here.next()).value, "this")

@test
async A_SUBSCRIBER_WAITING_ON_next_IS_HANDED_THE_NEXT_PUBLISH()
    // **The half that makes a hub a hub**: `next` parks on a promise and `publish` settles it, so a
    // client connected before anything happened is served the moment something does.
    val feed = hub()
    val one = feed.subscribe("notes")
    val waiting = one.next()

    feed.publish("notes", "while you were waiting")

    val step = await waiting

    assertEq(step.done, false)
    assertEq(step.value, "while you were waiting")

@test
async EVENTS_PUBLISHED_BEFORE_ANYBODY_PULLS_ARE_QUEUED_IN_ORDER()
    val feed = hub()
    val one = feed.subscribe("notes")

    feed.publish("notes", 1)
    feed.publish("notes", 2)
    feed.publish("notes", 3)

    assertEq((await one.next()).value, 1)
    assertEq((await one.next()).value, 2)
    assertEq((await one.next()).value, 3)

@test
async A_SUBSCRIBER_THAT_FALLS_BEHIND_LOSES_THE_OLDEST_AND_THE_DROPS_ARE_COUNTED()
    // **A live feed stays live.** A client that cannot keep up wants the newest state and not a
    // backlog -- and the alternative to dropping is a queue one slow client can grow until the
    // server runs out of memory.
    //
    // **The count is what makes it a decision rather than a silence**, so an operator can see a
    // client falling behind and a test can say the bound was honoured.
    val feed = hub()
    val slow = feed.subscribe("notes", { bound: 2 })

    for i in 0..<5
        feed.publish("notes", i)

    assertEq(slow.dropped(), 3)
    assertEq((await slow.next()).value, 3)
    assertEq((await slow.next()).value, 4)

@test
async A_SUBSCRIBER_KEEPING_UP_DROPS_NOTHING()
    // The control. Without it the count above could be right for the wrong reason.
    val feed = hub()
    val quick = feed.subscribe("notes", { bound: 2 })

    for i in 0..<5
        feed.publish("notes", i)

        assertEq((await quick.next()).value, i)

    assertEq(quick.dropped(), 0)

@test
async CLOSING_A_SUBSCRIBER_TAKES_IT_OFF_THE_TOPIC()
    // **This is the leak that actually happens.** `slate:http`'s writer stops pulling from a source
    // when a connection ends and does not tell the source, so a subscriber nobody closes stays on
    // the topic for the life of the program -- and `count` is the only thing that can see it.
    val feed = hub()
    val one = feed.subscribe("notes")
    val two = feed.subscribe("notes")

    assertEq(feed.count("notes"), 2)

    one.close()

    assertEq(feed.count("notes"), 1)

    two.close()

    assertEq(feed.count("notes"), 0)

@test
async CLOSING_ENDS_A_STREAM_RATHER_THAN_LEAVING_IT_WAITING()
    // A `done` is what ends the response the source was feeding. Without it a parked `next` waits
    // for ever and the connection is held by a promise nobody will settle.
    val feed = hub()
    val one = feed.subscribe("notes")
    val waiting = one.next()

    one.close()

    assertEq((await waiting).done, true)
    assertEq((await one.next()).done, true)

@test
async CLOSING_TWICE_IS_THE_SAME_AS_CLOSING_ONCE()
    // A handler and a test are both entitled to call it, and a count that went negative would be a
    // bug nobody would look for.
    val feed = hub()
    val one = feed.subscribe("notes")

    one.close()
    one.close()

    assertEq(feed.count("notes"), 0)

@test
async A_PUBLISH_TO_A_CLOSED_SUBSCRIBER_GOES_NOWHERE_AND_DOES_NOT_FAULT()
    val feed = hub()
    val one = feed.subscribe("notes")

    one.close()
    feed.publish("notes", "into the void")

    assertEq((await one.next()).done, true)

// -- the response the hub is read through -----------------------------------------------------------

@test
async sse_ANSWERS_AN_EVENT_STREAM_AND_A_HEARTBEAT()
    val r = response(sse(hub().subscribe("notes")))

    assertEq(status(r), 200)
    assertEq(header(r, "Content-Type"), "text/event-stream")
    assertEq(header(r, "Cache-Control"), "no-cache")
    assertEq(r.heartbeat, 15)

@test
async A_STREAM_BEHIND_A_GUARD_KEEPS_ITS_HEARTBEAT()
    // **THE DEFECT THIS FOUND.** `asResponse` rebuilt an envelope from `status`, `headers` and `body`
    // and dropped everything else, so an event stream behind any guard at all lost the `heartbeat`
    // `slate:http` puts on it -- and died quietly on the first proxy with an idle timeout. Nothing in
    // this suite would have noticed, since it never reaches a socket.
    //
    // **The rule now is carry what was there rather than enumerate what is known**, which is also
    // what makes the next member `slate:http` grows arrive here for free.
    val app = api()
    val feed = hub()

    app.get("/events", cors({ origin: "*" }, logger((r) -> null, (req) -> sse(feed.subscribe("notes")))))

    val r = response(await app.handle(request("GET", "/events")))

    assertEq(r.heartbeat, 15)
    assertEq(header(r, "Content-Type"), "text/event-stream")
    assert(header(r, "Access-Control-Allow-Origin") != null)

@test
async A_HANDLER_ANSWERING_A_STREAM_IS_AN_ORDINARY_ROUTE()
    // The whole point of SSE over a WebSocket here: it is a `GET`, so it goes through the route table
    // and every guard in this package exactly as anything else does.
    val app = api()
    val feed = hub()

    app.get("/events", (req) -> sse(feed.subscribe(req.query.topic ?? "notes")))

    val r = response(await app.handle(request("GET", "/events")))

    assertEq(feed.count("notes"), 1)

    feed.publish("notes", { event: "made", data: { id: 7 } })

    // **What the source hands the writer is the formatted lines**, not the value -- `sse` wraps the
    // source it was given so that the writer never has to know what an event is.
    val step = await r.body.next()

    assertEq(step.done, false)
    assert(contains(step.value, "event: made"))
    assert(contains(step.value, "data: {\"id\":7}"))
