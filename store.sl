// Where a session lives when it does not live in the cookie, and the one store this package ships.
//
// **A STORE IS THREE FUNCTIONS AND NOT A CLASS OR A SHAPE.** It is a plain object:
//
//     { get: (id) -> value or null,
//       set: (id, value, ttl) -> nothing,
//       delete: (id) -> nothing }
//
// **Every one of them may answer a promise**, which is what lets a store be a database: the session
// guard awaits all three, and `await` of a plain value answers it, so a store whose functions are
// ordinary works unchanged. That is the whole interface -- no registration, no base class, and
// nothing for this package to know about redis.
//
// **`ttl` is MILLISECONDS, or `null` for an entry that lasts until somebody deletes it**, and it is
// what `session`'s own `maxAge` becomes. Milliseconds because that is what `epochMillis` answers and
// what every comparison in here is against; a store that wants seconds divides once, at its edge.
//
// **`get` answers `null` for an id that was never there, one that expired and one that was revoked**,
// which are one thing to the guard above it: there is nobody logged in. A store that told them apart
// would be answering a question only somebody forging an id wants asked.
//
// **A DELETE IS `without`, AND THE MARK-AND-REBUILD IT REPLACES WAS A WORKAROUND FOR A MISSING
// BUILTIN.** slate 0.0.30 takes a key out of an object; what the cost of that is, and why it is the
// right cost here, is on `memoryStore` itself.

import { epochMillis, now } from slate:time

// `memoryStore(options)` -- a store in this process's memory, with a time to live.
//
// **It is a reference implementation and it says so**: everything in it is gone when the program
// stops and nothing is shared between two of them, so it is what a single server, a development
// machine and this suite want, and a fleet wants redis or a table.
//
// `options` takes `ttl`, a default lifetime in milliseconds for an entry set without one, and `now`,
// a clock answering milliseconds since the epoch. **The clock is injectable because expiry is
// otherwise untestable**: a suite that had to wait for a session to age would be a suite with a
// sleep in it, and a sleep in a test is a flake with a schedule.
export makeMemoryStore(options: object = {}) -> object
    val clock = options.now ?? systemClock
    val standing = options.ttl ?? null

    // **A DELETE IS `without`, WHICH IS slate 0.0.30's AND IS WHY THIS STORE IS NOW FOUR LINES
    // SHORTER THAN ITS OWN EXPLANATION USED TO BE.** Until then there was no way to take a key out of
    // an object, so an entry was marked dead, a counter followed how many dead ones there were, and
    // the table was rebuilt whenever they outnumbered the living -- five moving parts and one
    // invariant between them, all of it for a missing builtin.
    //
    // **WHAT IT COSTS IS SAID RATHER THAN HIDDEN: `without` COPIES THE TABLE, so a delete is linear
    // in the sessions held where the scheme it replaces was amortised constant.** A `set` mints a new
    // id and deletes the old one, so a delete is as common as a login -- and a login against a table
    // of fifty thousand copies fifty thousand entries. That is the right trade for THIS store and
    // said here so that it is not discovered: it is the reference implementation, it holds one
    // process's sessions, and a service with enough of them for the copy to be what hurts wanted
    // redis or a table several orders of magnitude earlier.
    val table = { held: {} }

    async get(id: string)
        val one = entryOf(table, id)

        if one == null then return null

        // **Expiry is checked on the way out rather than swept on a timer.** A timer would keep this
        // store alive for as long as the program, and an entry nobody asks for costs nothing but the
        // room it is in -- which the read that finds it expired takes away.
        if one.ends != null && clock() >= one.ends
            drop(table, id)

            return null

        one.value

    async set(id: string, value, ttl = null)
        val lasts = ttl ?? standing

        table.held[id] = { value: value, ends: if lasts == null then null else clock() + lasts }

        null

    async delete(id: string)
        drop(table, id)

        null

    // How many sessions are held. **Not part of the interface** -- a redis store could not answer it
    // without a scan -- and it is here because the alternative for a test that means to say an entry
    // was really removed is to trust that it was.
    size() -> integer = len(keys(table.held))

    { get: get, set: set, delete: delete, size: size }

systemClock() -> integer = epochMillis(now())

// The entry under an id, or `null` for one that is not there.
entryOf(table: object, id: string) = if has(table.held, id) then table.held[id] else null

// **`without` ANSWERS A NEW OBJECT**, which is `with`'s rule read the other way, so the table is
// replaced rather than changed under whoever is holding it. An id that is not there is not an error,
// so this needs no test of its own before it runs.
drop(table: object, id: string)
    table.held = without(table.held, id)

    null
