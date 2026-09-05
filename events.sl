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

// `hub()` -- publish to a topic, subscribe to one, and count who is listening.
export makeHub() -> object
    // Topic name to the subscribers on it. **An object used as a table**, the topics being whatever
    // the program calls them.
    val topics = {}

    // Everybody on a topic, or an empty list for one nobody has asked about.
    listeners(topic: string) -> array = topics[topic] ?? []

    // `publish(topic, value)` -- hand a value to everybody listening.
    //
    // **A waiting subscriber is settled and an unwatched one is queued**, which is the whole of the
    // arrangement: `next` either has something to answer or parks on a promise this settles.
    publish(topic: string, value)
        for one in listeners(topic)
            if one.closed then continue

            if one.waiting != null
                val waiting = one.waiting

                one.waiting = null

                settle(waiting, { done: false, value: value })
            else
                push(one.queue, value)

                // **The oldest goes and the drop is counted**, so that a client falling behind is a
                // number somebody can read rather than a silence.
                if len(one.queue) > one.bound
                    one.queue = one.queue[1..]
                    one.dropped = one.dropped + 1

        null

    // `subscribe(topic, options)` -- a source of everything published to `topic` from now on.
    //
    // **`close()` HAS TO BE CALLED and nothing calls it for you**, which is this design's one sharp
    // edge: `slate:http`'s writer stops pulling from a source when a connection ends and does not
    // tell the source, so a subscriber nobody closes stays on the topic for the life of the program.
    // A handler that ends a stream calls `close`, and `count` is how a test says it worked.
    subscribe(topic: string, options: object = {}) -> object
        val one = { queue: [], waiting: null, dropped: 0, closed: false,
                    bound: options.bound ?? Backlog }

        if !has(topics, topic) then topics[topic] = []

        push(topics[topic], one)

        // The next event, or a promise of one. **A closed subscriber is `done`**, which is what ends
        // the response the source was feeding.
        async pull()
            if one.closed then return { done: true, value: null }

            if len(one.queue) > 0
                val head = one.queue[0]

                one.queue = one.queue[1..]

                return { done: false, value: head }

            one.waiting = pending()

            await one.waiting

        // Leave the topic. **Idempotent**, a handler and a test both being entitled to call it, and
        // it settles a parked `next` so that whoever was reading is told the stream ended rather
        // than waiting for ever.
        close()
            if one.closed then return null

            one.closed = true

            if one.waiting != null
                val waiting = one.waiting

                one.waiting = null

                settle(waiting, { done: true, value: null })

            topics[topic] = without(listeners(topic), one)

            null

        // How many events this subscriber was too slow to take.
        dropped() -> integer = one.dropped

        { next: pull, close: close, dropped: dropped }

    // `count(topic)` -- how many subscribers a topic has.
    //
    // **It is here for the tests and for an operator**, and it is the only way to say a subscriber
    // was let go: a hub that leaked one would look exactly like a hub that did not.
    count(topic: string) -> integer = len(listeners(topic))

    { publish: publish, subscribe: subscribe, count: count }

// A list without one member of it, compared by identity.
without(xs: array, gone) -> array
    var out = []

    for x in xs
        if x != gone then push(out, x)

    out
