// An event hub, and the server-sent stream a subscriber reads it through.
//
// **A HUB IS ONE-WAY, WHICH IS WHY THIS IS SSE AND NOT A WEBSOCKET.** A server-sent stream is a plain
// `GET`, so every guard in this package already applies to it -- the session and the CSRF token
// included -- and a browser reconnects on its own. A WebSocket hub would need the upgrade path, a
// frame protocol of its own, and a second set of guards that do not compose with the first. Where a
// program genuinely needs two-way traffic it wants `slate:ws` directly and not this.
//
// **NOTHING HERE IS A SHAPE OF SLUICE'S OWN.** `subscribe` answers a SOURCE -- `{ next }` answering
// `{ done, value }` -- which is exactly what `slate:http`'s `sse` already takes, so a route is
//
//     app.get("/events", (req) -> sse(feed.subscribe("notes")))
//
// and a test pulls events straight out of the source with no port anywhere.

// How many events a subscriber that has stopped reading may fall behind before the oldest are
// dropped. **A live feed stays live**: a client that cannot keep up wants the newest state and not a
// backlog, so the queue is bounded and the oldest go.
val Backlog = 256

// `hub(options)` -- publish to a topic, subscribe to one, and count who is listening.
//
// **`replay` IS THE ONE OPTION AND IT IS OFF BY DEFAULT.** `hub({ replay: 64 })` keeps the last 64
// events of every topic so that a client reconnecting with a `Last-Event-ID` is handed what it
// missed; `hub()` keeps nothing, which is what most feeds want -- a browser reconnects, asks for the
// current state and carries on.
export makeHub(options: object = {}) -> object
    val keep = options.replay ?? 0

    // Topic name to `{ listeners, ring, next }`. **An object used as a table**, the topics being
    // whatever the program calls them.
    val topics = {}

    // What the hub holds about one topic, made on first use.
    //
    // **`next` starts at 1 rather than 0** so that every id a client can be holding is a positive
    // number, and "before the first event" has a value to be.
    topicOf(topic: string) -> object
        if !has(topics, topic) then topics[topic] = { listeners: [], ring: [], next: 1 }

        topics[topic]

    // Everybody on a topic, or an empty list for one nobody has asked about.
    listeners(topic: string) -> array = if has(topics, topic) then topics[topic].listeners else []

    // `publish(topic, value)` -- hand a value to everybody listening.
    //
    // **A waiting subscriber is settled and an unwatched one is queued**, which is the whole of the
    // arrangement: `next` either has something to answer or parks on a promise this settles.
    publish(topic: string, value)
        val event = if keep > 0 then remembered(topic, value) else value

        for one in listeners(topic)
            // **A stream that is ending takes nothing new**, its last event having gone out already:
            // queueing onto it would be handing something to a reader that is on its way out.
            if one.closed || one.ending then continue

            if one.waiting != null
                val waiting = one.waiting

                one.waiting = null

                settle(waiting, { done: false, value: event })
            else
                enqueue(one, event)

        null

    // The event as it will go out, with the id this topic gives it, kept in the topic's ring.
    //
    // **THE IDS ARE THE TOPIC'S AND NOT THE HUB'S**, because that is what `Last-Event-ID` means: a
    // client reconnects to the stream it was reading, and an id from another topic would place it
    // somewhere arbitrary in this one.
    remembered(topic: string, value)
        val held = topicOf(topic)
        val event = identified(value, held.next)

        held.next = held.next + 1

        push(held.ring, event)

        if held.ring.length > keep then held.ring = held.ring[1..]

        event

    // Everything the topic still holds that was published after the id a client says it last saw.
    //
    // **AN ID OLDER THAN THE BUFFER ANSWERS EVERYTHING HELD AND THE CLIENT IS TOLD NOTHING**, which
    // falls out of the comparison rather than being a case: every event still in the ring is newer
    // than an id that fell out of it. That is what a browser expects -- `EventSource` has no way of
    // being told it missed something and no way of asking again -- so a client that must not have a
    // hole checks its own ids, and one that only wants the current state carries on.
    heldAfter(topic: string, lastSeen) -> array
        if keep <= 0 || lastSeen == null then return []
        if !has(topics, topic) then return []

        val after = numbered(lastSeen)

        // **An id this hub did not write replays nothing and goes live**, a position that cannot be
        // read being no position at all. Answering the whole ring instead would hand a client that
        // reconnected to the wrong server a burst of events it had already seen.
        if after == null then return []

        var out = []

        for one in topics[topic].ring
            if numbered(one.id) > after then push(out, one)

        out

    // Take one subscriber off its topic and tell whoever was reading that the stream ended.
    //
    // **It is here rather than inside `subscribe` because two things end a subscription**: the
    // program or its reader, through the `close` a subscriber answers, and the hub itself when a
    // drain ends every stream at once. Both mean the same thing to a reader, so both are one
    // function. **Idempotent**, a handler, a writer and a drain all being entitled to call it.
    endOne(topic: string, one: object)
        if one.closed then return null

        one.closed = true

        if one.waiting != null
            val waiting = one.waiting

            one.waiting = null

            settle(waiting, { done: true, value: null })

        val held = topicOf(topic)

        held.listeners = without(held.listeners, one)

        null

    // `subscribe(topic, options)` -- a source of everything published to `topic` from now on, and of
    // what it missed where `lastEventId` says where it left off.
    //
    // **THE WRITER CLOSES THIS WHEN THE READER HAS GONE, WHICH IS slate 0.0.29's DOING AND NOT THIS
    // FILE'S.** A streamed response that ends with its source unexhausted -- a browser tab closed, a
    // socket cut off under the response, a peer that reset the stream -- calls `close` on the source
    // it was reading, and `sse` forwards that to the source it was given. So a subscriber whose
    // client went away leaves the topic with nothing written here at all. Before that a writer told
    // a source nothing, and every tab ever opened stayed on the topic for the life of the program.
    //
    // **`close` IS STILL THE PROGRAM'S TO CALL FOR A SUBSCRIPTION IT IS ENDING ITSELF** -- a handler
    // that stops a stream, a test taking a subscriber off a topic -- and it is idempotent, so the
    // two cannot fight. `count` is what says either of them worked, and `tests/hangup.sl` is the one
    // test here that binds a port, because a writer noticing that nobody is reading is the one thing
    // a handler driven directly cannot show.
    subscribe(topic: string, options: object = {}) -> object
        val one = { queue: [], waiting: null, dropped: 0, closed: false, ending: false,
                    bound: options.bound ?? Backlog }

        // **The replay goes through the queue the live events go through**, so a replay longer than
        // `bound` drops its oldest and counts them exactly as a burst would. One rule about falling
        // behind rather than two.
        for held in heldAfter(topic, options.lastEventId ?? null)
            enqueue(one, held)

        push(topicOf(topic).listeners, one)

        // The next event, or a promise of one. **A closed subscriber is `done`**, which is what ends
        // the response the source was feeding.
        async pull()
            if one.closed then return { done: true, value: null }

            if one.queue.length > 0
                val head = one.queue[0]

                one.queue = one.queue[1..]

                return { done: false, value: head }

            // **A stream that is ending is done once what it held has gone out**, which is what lets
            // a shutdown send a last event and still end the stream in the same breath: `endAll`
            // publishes, and the reader takes that event and then the end of the stream.
            if one.ending
                endOne(topic, one)

                return { done: true, value: null }

            one.waiting = pending()

            await one.waiting

        // Leave the topic. **Idempotent**, a handler and a test both being entitled to call it, and
        // it settles a parked `next` so that whoever was reading is told the stream ended rather
        // than waiting for ever.
        close() = endOne(topic, one)

        // How many events this subscriber was too slow to take.
        dropped() -> integer = one.dropped

        { next: pull, close: close, dropped: dropped }

    // `count(topic)` -- how many subscribers a topic has.
    //
    // **It is here for the tests and for an operator**, and it is the only way to say a subscriber
    // was let go: a hub that leaked one would look exactly like a hub that did not.
    count(topic: string) -> integer = listeners(topic).length

    // `open()` -- how many streams this hub is feeding, across every topic.
    //
    // **A DRAIN NEEDS ONE NUMBER AND NOT A LIST OF TOPICS IT DOES NOT KNOW.** `count` answers for a
    // topic a program named; this answers for the hub, which is what says whether the streams
    // `endAll` ended have actually finished -- a subscriber leaves its topic when its reader takes
    // the end of the stream, and not a moment before.
    open() -> integer
        var live = 0

        for topic in keys(topics)
            live = live + topics[topic].listeners.length

        live

    // `endAll(options)` -- end every open stream on every topic, and answer how many there were.
    //
    // **A SHUTDOWN THAT DOES NOT END ITS STREAMS DOES NOT SHUT DOWN.** An event stream is a response
    // that never finishes: `slate:http`'s `close` lets a connection with a request in flight finish
    // that response before closing it, so a server with one subscriber attached holds its socket
    // until the stream ends or the socket times out. Nothing in `slate:http` can end it either --
    // the source is this hub's, so this is the only place that knows how. `drain` calls it, and a
    // browser reconnects on its own to whichever instance is taking traffic by then.
    //
    // **THE LAST EVENT IS THE PROGRAM'S, BECAUSE SSE HAS NO GOODBYE OF ITS OWN.** A stream simply
    // ends, and what a client should make of that is the application's protocol and not this
    // package's: `endAll({ event: { event: "shutdown", retry: 5000 } })` says it and `endAll()` says
    // nothing. The event goes out before the end and through the queue every other event goes
    // through, so a reader takes it and then takes the end of the stream.
    //
    // **What it marks is `ending` and not `closed`**, which is the whole of why the last event
    // arrives: a closed subscriber answers `done` with its queue unread, and an ending one answers
    // what it holds and then `done`. A subscriber parked with nothing to take is ended on the spot.
    endAll(options: object = {}) -> integer
        val farewell = options.event ?? null
        var ended = 0

        for topic in keys(topics)
            if farewell != null then publish(topic, farewell)

            // **`endOne` rewrites the list this walks**, `without` answering a new array -- so the
            // loop holds the one it was given and every subscriber on the topic is reached.
            for one in listeners(topic)
                if one.closed then continue

                ended = ended + 1
                one.ending = true

                // Nothing left to take: a parked reader has an empty queue by construction, so the
                // farewell above either settled it or there was none.
                if one.waiting != null then endOne(topic, one)

        ended

    { publish: publish, subscribe: subscribe, count: count, open: open, endAll: endAll }

// `lastEventId(req)` -- the id a reconnecting client says it last saw, or `null`.
//
// **THE HUB TAKES THE ID RATHER THAN THE REQUEST, WHICH IS WHAT KEEPS IT ONE-WAY.** A hub knows
// about topics and events and nothing about HTTP; `sse` is `slate:http`'s and takes a source, not a
// request. Reading the header inside `subscribe` would put a request in the middle of both. So the
// route reads it, which is one visible line:
//
//     app.get("/events", (req) -> sse(feed.subscribe("notes", { lastEventId: lastEventId(req) })))
//
// **And it is a plain function rather than a guard for the same reason a guard would be wrong**: a
// guard writing onto the request would make replay something a stream got only where somebody had
// remembered to wrap it, and a stream without it would look identical and silently lose events.
export lastSeenId(req: object) -> string | null
    val said = req.headers["last-event-id"] ?? null

    if said is string && said != "" then return said

    // **A browser sends the header on its own and cannot be made to send anything else.** A client
    // that is not a browser often cannot put a header on an `EventSource` at all -- the browser API
    // takes a URL and nothing else -- so the query parameter is read as well, which is what every
    // polyfill uses and what a `curl` reconnecting by hand can write.
    val asked = req.query["lastEventId"] ?? null

    if asked is string && asked != "" then asked else null

// An event with its id on it.
//
// **An object is given an `id` MEMBER and anything else is wrapped as its `data`**, which is
// `slate:http`'s own shape for a piece of an event stream: a piece is a string, which is its data, or
// an object naming any of `event`, `id`, `retry` and `data`. So the id a hub assigns is the id the
// client is sent, with nothing between the two, and an `id` the publisher wrote itself is replaced --
// the ids are the hub's, and one it did not assign could not be replayed against.
identified(value, id: integer) =
    val at = string(id)

    if value is object then value with { id: at } else { id: at, data: value }

// An event id as the number it was assigned, or `null` for anything this hub did not write. **Text
// from a client**, so it answers rather than faulting.
numbered(raw) -> integer | null
    if raw is not string then return null

    val n = number(raw)

    if n is not integer then null else n

// Put one event on a subscriber's queue. **The oldest goes and the drop is counted**, so that a
// client falling behind is a number somebody can read rather than a silence.
enqueue(one: object, value)
    push(one.queue, value)

    if one.queue.length > one.bound
        one.queue = one.queue[1..]
        one.dropped = one.dropped + 1

    null

// A list without one member of it, compared by identity.
without(xs: array, gone) -> array
    var out = []

    for x in xs
        if x != gone then push(out, x)

    out
