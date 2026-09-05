// `memoryStore()` -- the one store this package ships, on its own.
//
// **The clock is injected**, so expiry is asserted rather than waited for: a suite that had to wait
// for a session to age would be a suite with a sleep in it, and a sleep in a test is a flake with a
// schedule.

import { memoryStore } from "../sluice.sl"

// A store and the hand that moves its clock. **`at` is milliseconds since the epoch**, which is what
// `ttl` is measured in and what a real clock answers.
ticking(options: object = {}) -> object
    val clock = { at: 1000 }

    reading() -> integer = clock.at

    { store: memoryStore(options with { now: reading }), clock: clock }

@test
async A_VALUE_SET_UNDER_AN_ID_IS_THE_VALUE_THAT_COMES_BACK()
    val store = memoryStore()

    await store.set("abc", { user: "ada" })

    assertEq((await store.get("abc")).user, "ada")

@test
async AN_ID_NOBODY_SET_IS_null_RATHER_THAN_A_FAULT()
    // An id arrives from a cookie, so one that is not there is a condition and not a defect.
    assertEq(await memoryStore().get("nothing under here"), null)

@test
async SETTING_AN_ID_AGAIN_REPLACES_IT_AND_ADDS_NOTHING()
    val store = memoryStore()

    await store.set("abc", 1)
    await store.set("abc", 2)

    assertEq(await store.get("abc"), 2)
    assertEq(store.size(), 1)

@test
async DELETING_TAKES_THE_ENTRY_AND_THE_ROOM_IT_WAS_IN()
    // **This is the revocation the whole store is for**, and `size` is what says the entry was really
    // removed rather than merely answered `null` for.
    val store = memoryStore()

    await store.set("abc", "here")

    assertEq(store.size(), 1)

    await store.delete("abc")

    assertEq(await store.get("abc"), null)
    assertEq(store.size(), 0)

@test
async DELETING_TWICE_AND_DELETING_NOTHING_ARE_BOTH_ORDINARY()
    // A logout that arrives twice is a client retrying, and a size that went negative would be a bug
    // nobody would look for.
    val store = memoryStore()

    await store.set("abc", "here")
    await store.delete("abc")
    await store.delete("abc")
    await store.delete("never there")

    assertEq(store.size(), 0)

@test
async AN_ENTRY_PAST_ITS_TTL_IS_NOBODY_AND_ITS_ROOM_GOES_BACK()
    val made = ticking()

    await made.store.set("abc", "here", 5000)

    made.clock.at = 5999

    assertEq(await made.store.get("abc"), "here")

    made.clock.at = 6000

    assertEq(await made.store.get("abc"), null)
    assertEq(made.store.size(), 0)

@test
async AN_ENTRY_WITH_NO_TTL_LASTS()
    // **A store is not a cache**, so an entry nobody put an age on stays until somebody deletes it.
    val made = ticking()

    await made.store.set("abc", "here")

    made.clock.at = 999999999

    assertEq(await made.store.get("abc"), "here")

@test
async A_STORE_MAY_CARRY_A_DEFAULT_TTL_FOR_AN_ENTRY_SET_WITHOUT_ONE()
    val made = ticking({ ttl: 100 })

    await made.store.set("abc", "here")

    made.clock.at = 1100

    assertEq(await made.store.get("abc"), null)

    // And an explicit one wins over it, in both directions.
    await made.store.set("longer", "here", 1000)
    await made.store.set("shorter", "here", 10)

    made.clock.at = 1200

    assertEq(await made.store.get("longer"), "here")
    assertEq(await made.store.get("shorter"), null)

@test
async A_STORE_PUT_THROUGH_MANY_LOGINS_AND_LOGOUTS_STILL_ANSWERS()
    // **A DELETE IS `without` AS OF slate 0.0.30**, where it used to mark an entry dead, count the
    // dead ones and rebuild the table once they outnumbered the living -- five moving parts for a
    // missing builtin, and this test is what said the arithmetic between them was right.
    //
    // **IT IS KEPT, BECAUSE WHAT IT PINS IS THE STORE AND NOT THE SCHEME.** A delete that lost
    // another entry, a `size` that drifted, an id written after two hundred of them that could not
    // be read back: none of those is visible in a store that only ever holds one. Hundreds of turns
    // of the thing a store actually does is where they show, whatever the delete is written as.
    val store = memoryStore()

    for i in 1..200
        val id = "id-" + string(i)

        await store.set(id, i)
        await store.delete(id)

    assertEq(store.size(), 0)

    await store.set("last", "here")

    assertEq(await store.get("last"), "here")
    assertEq(store.size(), 1)

@test
async DELETING_ONE_OF_MANY_LEAVES_THE_REST_WHERE_THEY_WERE()
    // The control for the two hundred above: a delete that took a neighbour with it would pass every
    // test that only ever holds one.
    val store = memoryStore()

    for i in 1..10
        await store.set("id-" + string(i), i)

    for i in 1..9
        await store.delete("id-" + string(i))

    assertEq(await store.get("id-10"), 10)
    assertEq(store.size(), 1)
