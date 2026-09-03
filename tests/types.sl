// The types this package works in terms of, from the outside.
//
// **They are `slate:http`'s and not this package's**, which is the point: a handler written for
// `serve` is a handler here, and one written here is one there. Declaring a `Request` of its own
// would be a second copy of somebody else's contract, kept in step by hand.

import { Request, Response } from slate:http
import { api, request, problem, json, guardOf, nameOf } from "../sluice.sl"

// A declaration built on an imported type, which is the shape a program's own vocabulary takes.
type Handled = { req: Request, at: string }

@test
THE_request_HELPER_BUILDS_WHAT_slate_http_WOULD_HAVE_DELIVERED()
    val plain = request("GET", "/notes")
    val full = request("POST", "/notes", { headers: { "Content-Type": "application/json" },
                                           body: { title: "a" },
                                           query: { page: "2" },
                                           cookies: { session: "abc" } })

    assert(plain is Request)
    assert(full is Request)
    assert({ req: plain, at: "now" } is Handled)

    // The error path, which is what says the two above are asking anything at all.
    assert(!({ method: "GET", path: "/notes" } is Request))
    assert(!("GET /notes" is Request))

@test
A_HEADER_NAME_ARRIVES_LOWERCASED_BECAUSE_THAT_IS_HOW_IT_ARRIVES()
    val r = request("GET", "/notes", { headers: { "Content-Type": "application/json", Authorization: "Bearer x" } })

    assertEq(keys(r.headers), ["content-type", "authorization"])

@test
A_QUERY_OBJECT_ALSO_BECOMES_THE_RAW_search_TEXT()
    val r = request("GET", "/notes", { query: { page: "2", q: "a note" } })

    assertEq(r.search, "page=2&q=a%20note")
    assertEq(r.query, { page: "2", q: "a note" })

@test
A_BODY_THAT_IS_NOT_TEXT_IS_ENCODED_AS_JSON_AND_TEXT_IS_LEFT_ALONE()
    assertEq(request("POST", "/x", { body: { title: "a" } }).body, "{\"title\":\"a\"}")
    assertEq(request("POST", "/x", { body: "already text" }).body, "already text")
    assert(!has(request("POST", "/x"), "body"), "no body at all is a field that is not there")

@test
WHAT_THIS_PACKAGE_BUILDS_IS_A_slate_http_Response()
    assert(problem(404, "Not Found") is Response)
    assert(json({ id: 1 }, 201) is Response)

@test
AN_api_IS_WHAT_serve_ASKS_FOR()
    // `serve` asks an object for its `handle` and calls that. That is the whole of the contract, and
    // it is why `serve(port, app)` needed nothing added to `slate:http`.
    val app = api()

    assert(app is object)
    assert(app.handle is function)

@test
A_GUARD_OF_YOUR_OWN_IS_A_LABEL_AND_A_WRAPPING()
    val timing = guardOf("timing", (h) -> h)

    assertEq(nameOf(timing), "timing")

    // A plain function is a guard too, and prints under a name nobody gave it.
    assertEq(nameOf((h) -> h), "guard")
