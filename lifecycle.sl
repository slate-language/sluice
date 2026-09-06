// Stopping, which is the one thing a server does that a request never sees.
//
// **A DEPLOYMENT ASKS A PROGRAM TO STOP WITH A SIGNAL AND THEN KILLS IT**, and the seconds between
// the two are the whole of what a graceful shutdown has to work in. What has to happen in them is
// fixed: stop taking new work, finish what is in hand, and let go of the socket -- in that order,
// because doing them in any other lets a request in.
//
// **`slate:http`'s `close` already does most of it, and that is why this is short.** Closing a
// server stops it accepting, closes every idle connection at once, and lets a connection with a
// request in flight finish that response before closing it -- node's rule since v19. What it does
// not do is WAIT, and it has no bound: it answers immediately, so a program that closes and exits
// cuts off exactly the requests it meant to let finish. The waiting and the bound are here.
//
// **NOTHING IN slate:http COUNTS WHAT IS IN FLIGHT**, so the count is `api`'s: `handle` is the one
// function every request goes through, and it is where a request begins and ends. A program serving
// a bare handler rather than an `api` passes its own `inflight` -- the shape is a function answering
// an integer and nothing more.

import { close as shutSocket } from slate:http
import { onSignal, offSignal } from slate:process

// `drain(server, options)` -- stop taking requests, let what is in hand finish, then close.
//
// **It answers what happened rather than nothing**: `{ cut, waited, ended }`, where `cut` is how
// many requests were still running when the grace ran out, `waited` is how long it took, and `ended`
// is how many event streams were ended. A shutdown that regularly cuts requests off is a grace that
// is too short or a handler that is too slow, and neither is visible unless the number is.
//
// **The seams are the two things that touch the world**: `close` is what actually lets go of the
// socket, and `inflight` is what says how many requests are still running. Both are options because
// this package's suite binds no port -- and because "closing" is a different thing for a server that
// is more than a socket, which is the same reason `slate:http` exports a `close` of its own rather
// than telling programs to close the handle.
//
// | option | |
// |---|---|
// | `grace` | the longest to wait for requests in flight, in milliseconds. `10000` |
// | `inflight` | a function answering how many requests are still running |
// | `stop` | called first, to stop taking new ones |
// | `close` | what closing the server means. `slate:http`'s `close` |
// | `poll` | how often to look, in milliseconds. `10` |
// | `hubs` | the event hubs whose streams to end, so that closing does not wait on them |
// | `farewell` | a last event published to every topic of those hubs before their streams end |
export async drainServer(server, options: object)
    val grace = options.grace ?? 10000
    val poll = options.poll ?? 10
    val inflight = options.inflight ?? none
    val stop = options.stop ?? null
    val closing = options.close ?? shutSocket
    val hubs = options.hubs ?? []
    val farewell = options.farewell ?? null

    // **Refusing comes first and closing comes last**, with the waiting in between: a request that
    // arrives while this is waiting would otherwise extend the wait it is inside.
    if stop != null then stop()

    // **AN EVENT STREAM IS NOT A REQUEST IN FLIGHT AND WAITING FOR ONE WOULD BE WAITING FOR EVER**,
    // which is why the hubs are ended here rather than counted above. `handle` is done with an SSE
    // route the moment it answers the response, so the count reads zero while the stream is still
    // open -- and then `close` holds the socket for that unfinished response until it ends or the
    // connection times out. So the streams are ended right after new work is refused: a subscriber
    // is told the stream is over, its browser reconnects to whatever is taking traffic by then, and
    // the requests genuinely in hand are still waited for below.
    val ending = {}

    if farewell != null then ending.event = farewell

    var ended = 0

    for feed in hubs
        ended = ended + feed.endAll(ending)

    // **A STREAM THAT HAS BEEN TOLD TO END HAS NOT ENDED YET**, and closing the socket under it
    // throws away the last event that was the whole point of sending one. So an ended stream is
    // waited for exactly as a request in hand is, under the same grace: it leaves its hub when its
    // reader has taken the end of the stream, and `open` is what says so.
    streaming() -> integer
        var live = 0

        for feed in hubs
            live = live + feed.open()

        live

    // **`inflight` is asked once a turn and no more**, a program's own counter being free to be
    // anything -- so the two numbers are kept apart rather than added up and read again at the end.
    var waited = 0
    var running = inflight()
    var live = streaming()

    while running + live > 0 && waited < grace
        await sleep(poll)

        waited = waited + poll
        running = inflight()
        live = streaming()

    closing(server)

    { cut: running, waited: waited, ended: ended }

// What `inflight` answers where nobody said. **Zero and not an error**: a program draining a server
// it has no counter for is asking for `close` with the connections given a moment to finish, which
// is what `slate:http` does on its own.
none() -> integer = 0

// `onShutdown(action, options)` -- run `action` when this program is asked to stop.
//
// **`SIGTERM` and `SIGINT` are both of them**: the first is what a container stopping and a
// `systemd` unit restarting send, the second is Ctrl-C, and a program that handled one and not the
// other would shut down cleanly in production and be killed in a terminal.
//
// **The answer is how to stop watching**, which is what makes this testable and what a program with
// more than one lifetime needs.
//
// **`on` and `off` are seams for the same reason `close` is.** `onSignal` is not in the JavaScript
// back end -- it is one of the names that faults there saying so -- and this package's suite runs on
// both, so what the suite drives is a pair of functions and what a program gets is the real ones.
//
// | option | |
// |---|---|
// | `signals` | which to watch. `["SIGTERM", "SIGINT"]` |
// | `on`, `off` | `slate:process`'s `onSignal` and `offSignal` |
export onShutdown(action: function, options: object) -> function
    val names = options.signals ?? ["SIGTERM", "SIGINT"]
    val on = options.on ?? onSignal
    val off = options.off ?? offSignal
    var ids = []

    for name in names
        push(ids, on(name, action))

    // **A named function because the body is statements**, which is the rule every callback in this
    // package is written to.
    stopWatching()
        for id in ids
            off(id)

        null

    stopWatching
