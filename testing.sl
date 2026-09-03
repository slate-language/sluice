// Building a request by hand, which is how everything here is tested and how a consumer tests a
// handler of its own.
//
// **`await api.handle(request(…))` needs no port, no server and no client.** A request is a value
// and a handler is a function of it, so a suite that binds nothing cannot flake under load, cannot
// collide with a development server on 8080, and needs no watchdog to notice a reply that never
// came.

import { encodeComponent } from slate:http

// `request(method, path, options)` -- a request value, filled in the way a server would fill it.
//
// | option | |
// |---|---|
// | `headers` | an object; the names are lowercased, which is how they arrive over a socket |
// | `body` | a string as it stands, anything else encoded as JSON |
// | `query` | an object, which also becomes `search` |
// | `search` | the raw text after the `?`, where a test means to write it itself |
// | `cookies` | an object |
//
// **`params` is `{}` here and is filled in by `handle`**, a route's `:name` being something only a
// route knows about.
export request(method: string, path: string, options: object = {}) -> object
    val given = if has(options, "headers") then options.headers else {}
    var headers = {}

    for [k, v] in entries(given)
        headers[lower(k)] = v

    // **Every query value is text, because that is the only thing a query string can carry.** A
    // helper that let `{ n: 3 }` through as an integer would let a shape asking for one fit here and
    // never fit over a socket, which is a suite agreeing with itself rather than with HTTP.
    val query = asText(if has(options, "query") then options.query else {})
    val search = if has(options, "search") then options.search else asSearch(query)

    var req = { method: method,
                path: path,
                search: search,
                headers: headers,
                query: query,
                cookies: if has(options, "cookies") then options.cookies else {},
                params: {},
                keepAlive: true,
                upgrade: false }

    if !has(options, "body") then return req

    val body = options.body

    if body is string then req with { body: body } else req with { body: toJSON(body) }

// Every value of an object rendered as the text a query string would have held.
asText(query: object) -> object
    var out = {}

    for [k, v] in entries(query)
        out[k] = string(v)

    out

// A query object as the text that would have carried it.
asSearch(query: object) -> string
    var parts = []

    for [k, v] in entries(query)
        push(parts, encodeComponent(k) + "=" + encodeComponent(string(v)))

    join(parts, "&")
