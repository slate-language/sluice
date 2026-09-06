// `hub()` and `sse()` -- publishing to whoever is listening, and the stream they listen through.
//
// **Not one of these needs a port.** A streamed response is a source, so a test pulls events out of
// a handler's answer exactly as the server would, which is what keeps this in the ordinary suite.

import { api, hub, sse, lastEventId, cors, logger, request, response } from "../sluice.sl"
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
    // **A program ending a subscription of its own**, which is the half that is written here: the
    // other half is a reader that goes away, where `slate:http`'s writer calls this same `close`
    // and no program is told anything. That one needs a socket and is in `tests/hangup.sl`.
    // `count` is the only thing that can see either.
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

// -- Last-Event-ID replay ----------------------------------------------------------------------------

@test
async A_HUB_THAT_WAS_NOT_ASKED_TO_REPLAY_LEAVES_AN_EVENT_EXACTLY_AS_PUBLISHED()
    // **The default is off and off means untouched.** A hub that remembers nothing cannot honour a
    // `Last-Event-ID`, so sending an id would promise a client something the hub could not keep --
    // a browser holds the last id it saw and asks for what came after it, and would silently get
    // nothing.
    val feed = hub()
    val one = feed.subscribe("notes", { lastEventId: "1" })

    feed.publish("notes", "first")

    val step = await one.next()

    assertEq(step.value, "first")
    assertEq(step.done, false)

@test
async AN_EVENT_ON_A_REPLAYING_HUB_CARRIES_THE_ID_IT_WILL_BE_ASKED_FOR()
    // **An object is given an `id` member and anything else is wrapped as its `data`**, which is
    // `slate:http`'s own shape for a piece of an event stream. So the id the hub assigned is the id
    // the client is sent, with nothing in between.
    val feed = hub({ replay: 8 })
    val one = feed.subscribe("notes")

    feed.publish("notes", "plain")
    feed.publish("notes", { event: "made", data: { id: 7 } })

    val first = (await one.next()).value

    assertEq(first.id, "1")
    assertEq(first.data, "plain")

    val second = (await one.next()).value

    assertEq(second.id, "2")
    assertEq(second.event, "made")
    assertEq(second.data.id, 7)

@test
async IDS_INCREASE_BY_ONE_AND_EACH_TOPIC_COUNTS_ITS_OWN()
    // **The ids are the topic's**, because that is what `Last-Event-ID` means: a client reconnects to
    // the stream it was reading, and an id from another topic would place it somewhere arbitrary in
    // this one.
    val feed = hub({ replay: 8 })
    val here = feed.subscribe("notes")
    val there = feed.subscribe("users")

    for i in 0..<3
        feed.publish("notes", i)
        feed.publish("users", i)

    for want in ["1", "2", "3"]
        assertEq((await here.next()).value.id, want)
        assertEq((await there.next()).value.id, want)

@test
async A_CLIENT_THAT_RECONNECTS_IS_HANDED_WHAT_IT_MISSED_AND_THEN_GOES_LIVE()
    // **The whole item.** A browser drops the connection, reconnects with the id it last saw, and
    // what it missed is delivered before anything new -- which is what makes a feed a feed rather
    // than a window onto whatever happens next.
    val feed = hub({ replay: 8 })
    val first = feed.subscribe("notes")

    feed.publish("notes", "one")
    feed.publish("notes", "two")

    val seen = (await first.next()).value

    assertEq(seen.data, "one")

    first.close()

    feed.publish("notes", "three")

    val again = feed.subscribe("notes", { lastEventId: seen.id })

    assertEq((await again.next()).value.data, "two")
    assertEq((await again.next()).value.data, "three")

    // And then it is an ordinary live subscriber.
    feed.publish("notes", "four")

    assertEq((await again.next()).value.data, "four")

@test
async A_SUBSCRIBER_THAT_SAYS_NOTHING_GETS_NOTHING_BACK()
    // The control for the test above: replay happens because a client asked for it by id, and a
    // fresh `EventSource` -- which sends no header -- starts at the live edge.
    val feed = hub({ replay: 8 })

    feed.publish("notes", "before")

    val one = feed.subscribe("notes")

    feed.publish("notes", "after")

    assertEq((await one.next()).value.data, "after")

@test
async AN_ID_OLDER_THAN_THE_BUFFER_IS_HANDED_EVERYTHING_HELD_AND_TOLD_NOTHING()
    // **That is what a browser expects.** `EventSource` has no way of being told it missed something
    // and no way of asking again, so a hole is delivered as an ordinary gap in the ids: a client that
    // must not have one checks them, and one that only wants the current state carries on.
    val feed = hub({ replay: 2 })
    val watching = feed.subscribe("notes")

    for i in 1..5
        feed.publish("notes", i)

    val late = feed.subscribe("notes", { lastEventId: "1" })

    assertEq((await late.next()).value.data, 4)
    assertEq((await late.next()).value.data, 5)

    // Nothing was said about the two that fell out of the ring: the drop count is about this
    // subscriber falling behind, and this one never did.
    assertEq(late.dropped(), 0)

@test
async AN_ID_THIS_HUB_DID_NOT_WRITE_REPLAYS_NOTHING_AND_GOES_LIVE()
    // A `Last-Event-ID` arrives from outside the program -- from another server, from a proxy that
    // rewrote it, from somebody typing -- so nonsense in it is a condition and not a defect. A
    // position that cannot be read is no position at all, and answering the whole ring instead would
    // hand a client that reconnected to the wrong server a burst it had already seen.
    val feed = hub({ replay: 8 })

    feed.publish("notes", "old")

    for bad in ["", "abc", "1.5", "-", " 1"]
        val one = feed.subscribe("notes", { lastEventId: bad })

        feed.publish("notes", "live")

        assertEq((await one.next()).value.data, "live")

        one.close()

@test
async A_REPLAY_LONGER_THAN_THE_BOUND_DROPS_ITS_OLDEST_AND_COUNTS_THEM()
    // **The replay goes through the queue the live events go through**, so one rule about falling
    // behind rather than two: a client whose backlog is bigger than it is willing to hold loses the
    // oldest of it, and the count says so.
    val feed = hub({ replay: 8 })

    for i in 1..6
        feed.publish("notes", i)

    val slow = feed.subscribe("notes", { lastEventId: "0", bound: 2 })

    assertEq(slow.dropped(), 4)
    assertEq((await slow.next()).value.data, 5)
    assertEq((await slow.next()).value.data, 6)

@test
async REPLAY_ON_A_TOPIC_NOBODY_EVER_PUBLISHED_TO_IS_NOTHING_RATHER_THAN_A_FAULT()
    val feed = hub({ replay: 8 })
    val one = feed.subscribe("quiet", { lastEventId: "3" })

    feed.publish("quiet", "first")

    assertEq((await one.next()).value.data, "first")

// -- the id off the request --------------------------------------------------------------------------

@test
async lastEventId_READS_THE_HEADER_A_BROWSER_SENDS()
    assertEq(lastEventId(request("GET", "/events", { headers: { "Last-Event-ID": "7" } })), "7")

@test
async lastEventId_READS_THE_QUERY_PARAMETER_A_CLIENT_THAT_CANNOT_SET_HEADERS_USES()
    // The browser API takes a URL and nothing else, so a polyfill -- or a `curl` reconnecting by
    // hand -- has nowhere to put a header.
    assertEq(lastEventId(request("GET", "/events", { query: { lastEventId: "7" } })), "7")

@test
async lastEventId_IS_null_WHERE_THERE_IS_NONE_AND_WHERE_IT_IS_EMPTY()
    assertEq(lastEventId(request("GET", "/events")), null)
    assertEq(lastEventId(request("GET", "/events", { headers: { "Last-Event-ID": "" } })), null)
    assertEq(lastEventId(request("GET", "/events", { query: { lastEventId: "" } })), null)

@test
async A_ROUTE_REPLAYS_WHAT_THE_REQUEST_ASKED_FOR_AND_THE_ID_IS_ON_THE_WIRE()
    // **The shape a program actually writes**, and the reason the id is read at the route: a hub
    // knows about topics and not about requests, and `sse` takes a source and not a request.
    val app = api()
    val feed = hub({ replay: 8 })

    app.get("/events", (req) -> sse(feed.subscribe("notes", { lastEventId: lastEventId(req) })))

    feed.publish("notes", { event: "made", data: { id: 7 } })

    val r = response(await app.handle(
        request("GET", "/events", { headers: { "Last-Event-ID": "0" } })))

    val step = await r.body.next()

    assertEq(step.done, false)
    assert(contains(step.value, "id: 1"))
    assert(contains(step.value, "event: made"))
    assert(contains(step.value, "data: {\"id\":7}"))

@test
async AN_ID_AHEAD_OF_EVERYTHING_HELD_REPLAYS_NOTHING_AND_GOES_LIVE()
    // **A server that restarted counts from 1 again**, so a client reconnecting to it holds an id
    // ahead of anything this hub has. Nothing is replayed and the stream is live, which is the only
    // answer that cannot deliver something the client has already seen.
    val feed = hub({ replay: 8 })

    for i in 1..3
        feed.publish("notes", i)

    val ahead = feed.subscribe("notes", { lastEventId: "500" })

    feed.publish("notes", "live")

    assertEq((await ahead.next()).value.data, "live")

// -- ending every stream at once -----------------------------------------------------------------------

@test
async endAll_ENDS_A_PARKED_STREAM_ON_THE_SPOT_AND_SAYS_HOW_MANY()
    // **A subscriber parked on `next` is the shape a shutdown actually meets**: a browser with an
    // `EventSource` open and nothing happening. It is told the stream ended rather than left waiting.
    val feed = hub()
    val one = feed.subscribe("notes")
    val waiting = one.next()

    assertEq(feed.endAll(), 1)

    val step = await waiting

    assertEq(step.done, true)
    assertEq(step.value, null)
    assertEq(feed.count("notes"), 0, "and the topic is left with nobody on it")

@test
async endAll_REACHES_EVERY_TOPIC_AND_EVERY_SUBSCRIBER_ON_IT()
    val feed = hub()
    val here = feed.subscribe("notes")
    val alsoHere = feed.subscribe("notes")
    val elsewhere = feed.subscribe("alerts")

    val parked = [here.next(), alsoHere.next(), elsewhere.next()]

    assertEq(feed.endAll(), 3)

    for one in parked
        assertEq((await one).done, true)

    assertEq(feed.count("notes"), 0)
    assertEq(feed.count("alerts"), 0)

@test
async THE_LAST_EVENT_GOES_OUT_BEFORE_THE_END_AND_THE_READER_TAKES_BOTH()
    // **SSE has no goodbye of its own**, so what a client should make of the end is the program's
    // protocol -- `endAll` sends what it is given and then the stream ends.
    val feed = hub()
    val one = feed.subscribe("notes")
    val waiting = one.next()

    assertEq(feed.endAll({ event: { event: "shutdown", retry: 5000 } }), 1)

    val last = await waiting

    assertEq(last.done, false)
    assertEq(last.value, { event: "shutdown", retry: 5000 })
    assertEq((await one.next()).done, true, "and then the stream is over")
    assertEq(feed.count("notes"), 0)

@test
async A_BACKLOG_IS_HANDED_OVER_BEFORE_THE_END_RATHER_THAN_DROPPED()
    // **`ending` and not `closed` is the whole of why the last event arrives**: a closed subscriber
    // answers `done` with its queue unread, and this one answers what it holds and then `done`.
    val feed = hub()
    val one = feed.subscribe("notes")

    feed.publish("notes", "first")
    feed.publish("notes", "second")

    assertEq(feed.endAll({ event: "last" }), 1)

    assertEq((await one.next()).value, "first")
    assertEq((await one.next()).value, "second")
    assertEq((await one.next()).value, "last")
    assertEq((await one.next()).done, true)

@test
async A_STREAM_THAT_IS_ENDING_TAKES_NOTHING_NEW()
    // Queueing onto it would be handing something to a reader that is on its way out, and a value
    // published after the last event would arrive after it.
    val feed = hub()
    val one = feed.subscribe("notes")

    feed.endAll({ event: "last" })
    feed.publish("notes", "too late")

    assertEq((await one.next()).value, "last")
    assertEq((await one.next()).done, true)

@test
async endAll_ON_A_HUB_NOBODY_IS_READING_ENDS_NOTHING()
    val quiet = hub()
    val used = hub()
    val one = used.subscribe("notes")

    one.close()

    assertEq(quiet.endAll(), 0, "a hub no topic was ever named on")
    assertEq(used.endAll(), 0, "and a topic whose one subscriber had already gone")

@test
async endAll_TWICE_ENDS_NOTHING_THE_SECOND_TIME()
    // A signal handler and a `main` that finishes are both entitled to drain, so the second call
    // must be a number and not a fault.
    val feed = hub()
    val one = feed.subscribe("notes")
    val waiting = one.next()

    assertEq(feed.endAll(), 1)
    assertEq(feed.endAll(), 0)
    assertEq((await waiting).done, true)

@test
async A_SUBSCRIBER_THAT_CLOSED_ITSELF_IS_NOT_ENDED_AGAIN()
    // `close` is still the program's for a subscription it ends itself, and the two cannot fight.
    val feed = hub()
    val one = feed.subscribe("notes")
    val two = feed.subscribe("notes")

    one.close()

    assertEq(feed.endAll(), 1, "the one still reading")
    assertEq((await two.next()).done, true)
    assertEq((await one.next()).done, true)

@test
async open_IS_EVERY_STREAM_THE_HUB_IS_FEEDING_ACROSS_EVERY_TOPIC()
    // A drain needs one number and not a list of topics it does not know.
    val feed = hub()

    assertEq(feed.open(), 0)

    val here = feed.subscribe("notes")
    val elsewhere = feed.subscribe("alerts")

    assertEq(feed.open(), 2)

    here.close()

    assertEq(feed.open(), 1)

    elsewhere.close()

    assertEq(feed.open(), 0)

@test
async A_STREAM_STAYS_OPEN_UNTIL_ITS_READER_HAS_TAKEN_THE_END()
    // **THIS IS WHAT A DRAIN WAITS ON.** `endAll` says the stream is over; the reader has still to
    // take the last event and then the end of it, and a socket closed in between throws both away.
    val feed = hub()
    val one = feed.subscribe("notes")

    feed.endAll({ event: "last" })

    assertEq(feed.open(), 1, "told to end is not ended")
    assertEq((await one.next()).value, "last")
    assertEq(feed.open(), 1, "and the last event is not the end either")
    assertEq((await one.next()).done, true)
    assertEq(feed.open(), 0, "the end of the stream is what takes it off the topic")
