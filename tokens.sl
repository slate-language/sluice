// `tokens(store, options)` -- opaque API tokens: issued once, kept as a hash, checked by `bearer`.
//
// **A token is a prefix, a selector and a validator** -- `oat_<selector>.<validator>` -- which is the
// remember-me cookie's split token again, for the same reasons: the store is looked up by the
// selector, which says nothing, and holds only a SHA-256 of the validator, which is compared with
// `timingSafeEqual`. **So a copy of the store is a list of who has tokens and not a way to use any of
// them**, and the plaintext exists exactly once, in what `issue` answers.
//
// **The prefix is what makes a token recognisable where it should not be** -- a log line, a commit, a
// paste -- which is what a secret scanner keys on; the name is Adonis's for the same thing, *opaque
// access token*.
//
// `verify` answers the result `bearer(verify)` takes, so the two fit with nothing between them:
//
//     val keys = tokens(memoryStore())
//
//     app.get("/notes", bearer(keys.verify, list))
//
// The store is the session store's three functions, and `memoryStore()` is one.

import { randomBytes, timingSafeEqual } from slate:crypto
import { base64urlEncode } from slate:url

import { digestOf, splitToken, systemClock } from "./auth.sl"

// | option | |
// |---|---|
// | `prefix` | what every token begins with (`"oat_"`) |
// | `load` | `load(userId)` -> the user `verify` answers, or `null` for one who is gone; the id itself by default |
// | `now` | a clock answering milliseconds since the epoch |
export makeTokens(store: object, options: object = {}) -> object
    val prefix = options.prefix ?? "oat_"
    val clock = options.now ?? systemClock
    val load = options.load ?? null

    // `issue(userId, { name, expiresIn })` -- a new token, answered ONCE.
    //
    // It answers `{ token, id, name, expiresAt }`: `token` is the plaintext and nothing keeps it, `id`
    // is what `revoke` takes and what a page listing somebody's tokens shows, and `expiresAt` is
    // milliseconds since the epoch, or `null` for a token that lasts until it is revoked. `expiresIn`
    // is in SECONDS, like every `maxAge` in this package.
    async issue(userId, details: object = {}) -> object
        if userId == null then throw "a token is issued to somebody -- `issue` was given a null user id"

        val name = details.name ?? null
        val expiresIn = details.expiresIn ?? null
        val expiresAt = if expiresIn == null then null else clock() + expiresIn * 1000

        // **96 bits of selector and 256 of validator**, both from the operating system. The selector
        // only has to not collide; the validator is the secret.
        val selector = base64urlEncode(randomBytes(12))
        val validator = base64urlEncode(randomBytes(32))

        await store.set(selector,
                        { user: userId, hash: digestOf(validator), name: name, expiresAt: expiresAt },
                        if expiresIn == null then null else expiresIn * 1000)

        { token: prefix + selector + "." + validator, id: selector, name: name, expiresAt: expiresAt }

    // `verify(token)` -- `{ ok: true, value: user }` or `{ ok: false, error }`.
    //
    // **One refusal for a token that is malformed, unknown, revoked, wrong or expired**, because
    // telling them apart tells whoever is guessing which half they have right. **Expired is in that
    // list for a reason that is not secrecy**: the store is handed the same lifetime as its ttl, so a
    // store that expires entries itself has forgotten the token by the time it would be read as
    // expired here -- and a message that depended on which store a program used would be one no
    // client could rely on.
    async verify(token: string) -> object
        val held = if startsWith(token, prefix) then splitToken(token[prefix.length..]) else null

        if held == null then return Invalid

        val entry = await store.get(held.selector)

        if entry == null then return Invalid

        if !timingSafeEqual(toBytes(digestOf(held.validator)), toBytes(entry.hash)) then return Invalid

        if entry.expiresAt != null && entry.expiresAt <= clock()
            // **The store's own ttl may not have run**, or the store may not keep one at all, so the
            // expiry is checked here and the entry is taken away on sight.
            await store.delete(held.selector)

            return Invalid

        if load == null then return { ok: true, value: entry.user }

        val user = await load(entry.user)

        if user == null then return Invalid

        { ok: true, value: user }

    // `revoke(id)` -- the token is gone, at once. **It takes the `id` `issue` answered, or the whole
    // token**, so an application can revoke from a listing and a client can revoke the one it holds.
    async revoke(which: string) -> null
        val held = if startsWith(which, prefix) then splitToken(which[prefix.length..]) else null
        val selector = if held == null then which else held.selector

        await store.delete(selector)

        null

    { issue: issue, verify: verify, revoke: revoke }

val Invalid = { ok: false, error: "that token is not valid" }
