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

    // `entries` is id to `{ value, ends }` with a dead one held as `null`; `gone` counts those.
    val table = { held: {}, gone: 0 }

    async get(id: string)
        val one = entryOf(table, id)

        if one == null then return null

        // **Expiry is checked on the way out rather than swept on a timer.** A timer would keep this
        // store alive for as long as the program, and an entry nobody asks for costs nothing but the
        // room it is in -- which the next `set` past the threshold reclaims anyway.
        if one.ends != null && clock() >= one.ends
            drop(table, id)

            return null

        one.value

    async set(id: string, value, ttl = null)
        val lasts = ttl ?? standing

        put(table, id, { value: value, ends: if lasts == null then null else clock() + lasts })

        null

    async delete(id: string)
        drop(table, id)

        null

    // How many sessions are held. **Not part of the interface** -- a redis store could not answer it
    // without a scan -- and it is here because the alternative for a test that means to say an entry
    // was really removed is to trust that it was.
    size() -> integer = len(keys(table.held)) - table.gone

    { get: get, set: set, delete: delete, size: size }

systemClock() -> integer = epochMillis(now())

// The entry under an id, or `null` for one that is not there or is dead.
entryOf(table: object, id: string) = if has(table.held, id) then table.held[id] else null

put(table: object, id: string, one: object)
    if has(table.held, id) && table.held[id] == null then table.gone = table.gone - 1

    table.held[id] = one

    null

// **SLATE HAS NO WAY TO REMOVE A KEY FROM AN OBJECT** -- `keys`, `values`, `entries` and `has` are
// the whole of the object surface -- so an entry is marked dead and the table is rebuilt once the
// dead outnumber the living. That is amortised constant per delete, which is what this store needs:
// a session that is written is written under a NEW id and the old one is deleted, so a delete is as
// common as a login and not as rare as a logout.
drop(table: object, id: string)
    if entryOf(table, id) == null then return null

    table.held[id] = null
    table.gone = table.gone + 1

    if table.gone * 2 > len(keys(table.held)) then compact(table)

    null

compact(table: object)
    var fresh = {}

    for [k, v] in entries(table.held)
        if v != null then fresh[k] = v

    table.held = fresh
    table.gone = 0

    null
