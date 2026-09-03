// `body(Shape)` -- the declaration is the validator.

import { api, body, request, json } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

type NewNote = { title: string, pinned?: boolean }

made() -> object
    val app = api()

    app.post("/notes", body(NewNote, (req) -> json({ title: req.body.title, raw: req.raw }, 201)))

    app

@test
async A_BODY_THAT_FITS_ARRIVES_PARSED_WITH_THE_TEXT_KEPT_ON_raw()
    val app = made()
    val text = "{\"title\":\"a note\"}"
    val r = await app.handle(request("POST", "/notes", { body: text }))

    assertEq(status(r), 201)
    assertEq(doc(r).title, "a note")
    assertEq(doc(r).raw, text)

@test
async AN_OPTIONAL_KEY_MAY_BE_ABSENT_AND_MUST_FIT_WHERE_IT_IS_THERE()
    val app = made()

    assertEq(status(await app.handle(request("POST", "/notes", { body: { title: "a" } }))), 201)
    assertEq(status(await app.handle(request("POST", "/notes", { body: { title: "a", pinned: true } }))), 201)
    assertEq(status(await app.handle(request("POST", "/notes", { body: { title: "a", pinned: 1 } }))), 400)

@test
async A_FIELD_THE_SHAPE_DOES_NOT_NAME_IS_LET_THROUGH()
    // An object pattern is partial, which is exactly right for a request body: a client sending a
    // field this version does not read is not a client making a mistake.
    val app = made()

    assertEq(status(await app.handle(request("POST", "/notes", { body: { title: "a", colour: "red" } }))), 201)

@test
async A_BODY_THAT_IS_NOT_JSON_IS_A_400_PROBLEM_NAMING_THE_PARSE()
    val app = made()
    val r = await app.handle(request("POST", "/notes", { body: "{ not json" }))

    assertEq(status(r), 400)
    assertEq(header(r, "content-type"), "application/problem+json")
    assertEq(doc(r).title, "Bad Request")
    assertEq(doc(r).detail, "the request body is not JSON")
    assert(doc(r).parse != "", "the parse error is carried as an extension member")

@test
async A_BODY_THAT_DOES_NOT_FIT_CARRIES_EVERY_MISMATCH_AT_ONCE()
    // `mismatch` collects them all rather than stopping at the first, because a client filling in a
    // form wants to be told about all of it at once.
    val app = made()
    val r = await app.handle(request("POST", "/notes", { body: { pinned: 1 } }))

    assertEq(status(r), 400)
    assertEq(doc(r).detail, "the request body does not fit NewNote")
    assertEq(doc(r).instance, "/notes")
    assertEq(doc(r).mismatch, [{ path: "title", wanted: "string", got: "nothing" },
                               { path: "pinned", wanted: "boolean", got: "integer" }])

@test
async A_MISSING_BODY_IS_THE_SAME_REFUSAL_AS_AN_UNPARSEABLE_ONE()
    // A request with no body at all is what a `GET` routed here would be, and it must not fault.
    val app = made()

    assertEq(status(await app.handle(request("POST", "/notes"))), 400)

@test
async THE_GUARD_DOES_NOT_TOUCH_THE_REQUEST_IT_WAS_GIVEN()
    val app = made()
    val req = request("POST", "/notes", { body: { title: "a" } })

    assertEq(status(await app.handle(req)), 201)
    assert(req.body is string, "the request still holds the text it arrived with")
    assert(!has(req, "raw"), "and nothing was added to it")
