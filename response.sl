// What a handler's answer is turned into, and the one refusal shape this framework has.

// The media type RFC 9457 gives a problem document. It is not `application/json`, and that is the
// whole point of the registration: a client can tell an error document from the document it asked
// for without reading either.
export val ProblemType = "application/problem+json"

// `problem(status, title, detail, extra)` -- a response carrying an RFC 9457 problem document.
//
// **`type` is `about:blank` unless something says otherwise**, which is what the specification says
// a problem with no further identity is. An application with a URI of its own for a kind of failure
// puts it in `extra`.
//
// **A member with nothing in it is left out rather than written `null`.** `detail` and `instance`
// are both optional in the specification, and a client reading `"detail": null` has to test for two
// absences where it should test for one.
//
// **`extra` is merged at the top level**, because that is where RFC 9457 puts an extension member:
// a problem document is a document about one failure, not an envelope with a payload inside it.
export problemResponse(status: integer, title: string, detail: string | null, extra: object) -> object
    var doc = { type: "about:blank", title: title, status: status }

    if detail != null then doc["detail"] = detail

    for [k, v] in entries(extra)
        // **An extension member may not quietly replace one this call was given.** `extra` is where
        // `type` and `instance` are said, there being no parameter for either; `title`, `status`
        // and `detail` have one, so a document that named them again would answer with whichever
        // won -- and a `{ title: … }` extension on a `Conflict` really does turn the title into the
        // name of the thing that conflicted. That was written here before it was caught.
        if k == "title" || k == "status" || k == "detail"
            throw "`" + k + "` is a standard member of a problem document, so it is an argument rather than an extension"

        doc[k] = v

    { status: status, headers: { "Content-Type": ProblemType }, body: toJSON(doc) }

// `json(value, status)` -- a value as a JSON response.
//
// **A bare object answer is a response ENVELOPE and not a document**, which is `slate:http`'s rule
// and is kept: `{ status: 201, body: … }` would otherwise be a note with a `status` field in it.
// So an API answering data says which it means, and this is the short way of saying it.
export jsonResponse(value, status: integer) -> object =
    { status: status, headers: { "Content-Type": "application/json" }, body: toJSON(value) }

// Whether an answer is a response envelope rather than a body.
//
// **The test is `slate:http`'s own**: it reads `status`, `headers` and `body` off an object and
// nothing else, so an object carrying any of the three is one.
export isEnvelope(v) -> boolean =
    v is object && (has(v, "status") || has(v, "headers") || has(v, "body"))

// An answer as `{ status, headers, body }`, so that a guard wrapping a handler has one shape to add
// a header to. **A string, a byte array and a number are bodies**, exactly as they are to `serve`.
//
// **EVERY OTHER MEMBER THE ANSWER CARRIED IS KEPT, AND THAT IS NOT TIDINESS.** This rebuilt an
// envelope from three names, so anything else on it was dropped the moment a guard touched the
// response -- and `slate:http`'s `sse` puts `heartbeat` on one. An event stream behind `cors`,
// `logger` or `session` lost its keep-alive and died quietly on the first proxy with an idle
// timeout, and nothing here would have noticed, this suite never reaching a socket.
//
// **So the rule is CARRY WHAT WAS THERE rather than enumerate what is known**, which is also what
// makes the next member `slate:http` grows arrive here for free instead of being lost until somebody
// reports it.
export asResponse(v) -> object
    if !isEnvelope(v) then return { status: 200, headers: {}, body: v }

    var out = {}

    for [k, hv] in entries(v)
        if k != "status" && k != "headers" && k != "body" then out[k] = hv

    out["status"] = if has(v, "status") then v.status else 200
    out["headers"] = if has(v, "headers") then v.headers else {}
    out["body"] = if has(v, "body") then v.body else ""

    out

// A response with more headers on it. **The answer is a new object**: a guard that wrote into the
// response a handler built would be mutating a value the handler may still hold.
//
// **A HEADER THAT MAY REPEAT IS APPENDED AND NOT REPLACED, AND `Set-Cookie` IS WHY.** This merged by
// name, so a response already carrying a session cookie lost it the moment anything added a second
// one -- silently, and the first thing anybody writes is a login that sets a session and a CSRF
// token together. `slate:http` takes an ARRAY for a name that repeats, which is the shape 0.0.27
// gave it for exactly this, and both back ends write one line per element.
//
// **`Set-Cookie` is the only name this is true of, and that is the specification's own note.** RFC
// 9110 excludes it from the rule that repeated fields may be joined with commas, because a cookie
// carries commas inside itself -- `Expires=Wed, 21 Oct 2026` -- so two joined with `", "` cannot be
// taken apart again by anything. Every other repeated header keeps the last, which is what a guard
// adding a `Content-Type` or a `Vary` means.
export withHeaders(v, extra: object) -> object
    val r = asResponse(v)
    var headers = {}

    for [k, hv] in entries(r.headers)
        headers[k] = hv

    for [k, hv] in entries(extra)
        if repeats(k) && has(headers, k)
            headers[k] = joined(headers[k], hv)
        else
            headers[k] = hv

    r with { headers: headers }

// Whether two of this header are two lines rather than the second replacing the first.
//
// **Compared without case**, a header name being case-insensitive and a handler writing whichever
// spelling it likes.
repeats(name: string) -> boolean = name.lower() == "set-cookie"

// Both values as one, whatever shapes they arrived in. A header's value is a string or an array of
// them, so this is four cases and no cleverness.
joined(had, added) -> array
    var out = []

    if had is array
        for one in had
            push(out, one)
    else
        push(out, had)

    if added is array
        for one in added
            push(out, one)
    else
        push(out, added)

    out
