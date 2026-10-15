// `tokens(store)` -- opaque API tokens, issued once, stored as a hash, verified by `bearer`.

import { api, bearer, tokens, memoryStore, json, request, response } from "../sluice.sl"
import { doc, status } from "./support.sl"

val Start = 1800000000000

// An api with one route behind `bearer(keys.verify)`, and the store and clock the keys are over.
made(options: object = {}) -> object
    val time = { at: Start }
    val store = options.store ?? memoryStore({ now: () -> time.at })
    val keys = tokens(store, (options.tokens ?? {}) with { now: () -> time.at })
    val app = api()

    app.get("/me", bearer(keys.verify, (req) -> json({ user: req.user })))

    { app: app, keys: keys, store: store, time: time }

async asked(it: object, token: string) =
    await it.app.handle(request("GET", "/me", { headers: { authorization: "Bearer " + token } }))

@test
async AN_ISSUED_TOKEN_FITS_bearer_DIRECTLY()
    val it = made()
    val issued = await it.keys.issue("1", { name: "laptop" })

    assert(startsWith(issued.token, "oat_"), "the prefix says what it is")
    assertEq(issued.name, "laptop")
    assertEq(issued.expiresAt, null)

    val r = await asked(it, issued.token)

    assertEq(status(r), 200)
    assertEq(parseJSON(response(r).body).value, { user: "1" })

@test
async ONLY_A_HASH_IS_STORED_AND_THE_PLAINTEXT_IS_ANSWERED_ONCE()
    var stored = []

    val inner = memoryStore()

    keep(id, v, ttl)
        push(stored, { id: id, value: v })

        inner.set(id, v, ttl)

    val it = made({ store: { get: inner.get, set: keep, delete: inner.delete } })
    val issued = await it.keys.issue("1")
    val validator = issued.token[(indexOf(issued.token, ".") + 1)..]

    assertEq(stored.length, 1)
    assertEq(stored[0].id, issued.id, "the store is keyed by the token's id")
    assert(!contains(toJSON(stored[0].value), validator), "the secret half is nowhere in the store")
    assert(!contains(toJSON(stored[0].value), issued.token))

@test
async AN_EXPIRED_TOKEN_IS_REFUSED()
    val it = made()
    val issued = await it.keys.issue("1", { expiresIn: 60 })

    assertEq(issued.expiresAt, Start + 60000)

    it.time.at = Start + 59999

    assertEq(status(await asked(it, issued.token)), 200, "a millisecond before")

    it.time.at = Start + 60000

    val r = await asked(it, issued.token)

    assertEq(status(r), 401)
    assertEq(doc(r).detail, "that token is not valid", "the same refusal whichever store expired it")

@test
async AN_EXPIRED_TOKEN_IS_REFUSED_EVEN_BY_A_STORE_THAT_KEEPS_NO_TTL()
    // The expiry is the token's own and not only the store's, so a store that ignores `ttl` cannot
    // keep one alive.
    var table = {}
    val forgetful = { get: (id) -> table[id] ?? null,
                      set: (id, v, ttl) -> put(table, id, v),
                      delete: (id) -> put(table, id, null) }

    val it = made({ store: forgetful })
    val issued = await it.keys.issue("1", { expiresIn: 1 })

    it.time.at = Start + 5000

    assertEq(status(await asked(it, issued.token)), 401)
    assertEq(table[issued.id], null, "and it is taken away on sight")

put(table: object, id: string, v) -> null
    table[id] = v

    null

@test
async A_REVOKED_TOKEN_IS_REFUSED_WHETHER_REVOKED_BY_ID_OR_BY_TOKEN()
    val it = made()
    val one = await it.keys.issue("1")
    val two = await it.keys.issue("1")

    await it.keys.revoke(one.id)
    await it.keys.revoke(two.token)

    for t in [one.token, two.token]
        val r = await asked(it, t)

        assertEq(status(r), 401)
        assertEq(doc(r).detail, "that token is not valid")

@test
async REVOKING_ONE_TOKEN_LEAVES_THE_OTHERS()
    val it = made()
    val one = await it.keys.issue("1")
    val two = await it.keys.issue("1")

    await it.keys.revoke(one.id)

    assertEq(status(await asked(it, two.token)), 200)

@test
async A_TOKEN_THAT_IS_WRONG_ANY_WAY_AT_ALL_IS_ONE_REFUSAL()
    // **One message for malformed, unknown and tampered**, so a guesser learns nothing about which
    // half was right.
    val it = made()
    val good = await it.keys.issue("1")
    val at = indexOf(good.token, ".")
    val tampered = good.token[0..<(at + 1)] + "A" + good.token[(at + 2)..]
    val other = good.token[0..<(at + 1)] + good.token[(at + 1)..] + "x"

    for bad in [tampered, other, "oat_nothing", "oat_.x", "oat_x.", "nope_" + good.token[4..],
                good.token[4..], "oat_unknown.validator"]
        val r = await asked(it, bad)

        assertEq(status(r), 401, bad)
        assertEq(doc(r).detail, "that token is not valid", bad)

@test
async load_ANSWERS_THE_USER_AND_A_USER_WHO_IS_GONE_IS_REFUSED()
    val it = made({ tokens: { load: (id) -> if id == "1" then { id: "1", name: "ada" } else null } })
    val ada = await it.keys.issue("1")
    val gone = await it.keys.issue("2")

    assertEq(parseJSON(response(await asked(it, ada.token)).body).value, { user: { id: "1", name: "ada" } })
    assertEq(status(await asked(it, gone.token)), 401)

@test
async THE_PREFIX_IS_THE_APPLICATION_S_TO_CHOOSE()
    val it = made({ tokens: { prefix: "notes_" } })
    val issued = await it.keys.issue("1")

    assert(startsWith(issued.token, "notes_"))
    assertEq(status(await asked(it, issued.token)), 200)
    assertEq(status(await asked(it, "oat_" + issued.token[6..])), 401)

@test
async EVERY_TOKEN_IS_DIFFERENT()
    val it = made()
    var seen = {}

    for i in [1, 2, 3, 4, 5, 6, 7, 8]
        val t = await it.keys.issue("1")

        assert(!has(seen, t.token))
        assert(!has(seen, t.id))

        seen[t.token] = true
        seen[t.id] = true

@test
async ISSUING_TO_NOBODY_IS_A_FAULT()
    val it = made()
    var faulted = false

    try
        await it.keys.issue(null)
    catch e
        faulted = true

    assert(faulted)
