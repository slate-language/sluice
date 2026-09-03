// The problem document, and the two other answers this package can build.

import { problem, json, response } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

@test
THE_MEDIA_TYPE_IS_THE_REGISTERED_ONE_AND_NOT_application_json()
    // That is the whole point of the registration: a client can tell an error document from the
    // document it asked for without reading either.
    assertEq(header(problem(418, "I'm a teapot"), "content-type"), "application/problem+json")

@test
A_PROBLEM_CARRIES_type_title_AND_status()
    val r = problem(404, "Not Found")

    assertEq(status(r), 404)
    assertEq(doc(r), { type: "about:blank", title: "Not Found", status: 404 })

@test
A_MEMBER_WITH_NOTHING_IN_IT_IS_LEFT_OUT_RATHER_THAN_WRITTEN_null()
    // RFC 9457 makes both optional, and a client reading `"detail": null` has to test for two
    // absences where it should test for one.
    assert(!has(doc(problem(404, "Not Found")), "detail"))
    assert(!has(doc(problem(404, "Not Found")), "instance"))
    assertEq(doc(problem(404, "Not Found", "there is nothing at /x")).detail, "there is nothing at /x")

@test
AN_EXTENSION_MEMBER_GOES_AT_THE_TOP_LEVEL()
    // A problem document is a document about one failure, not an envelope with a payload inside it.
    val r = problem(409, "Conflict", "that title is taken", { instance: "/notes", taken: "first" })

    assertEq(doc(r).instance, "/notes")
    assertEq(doc(r).taken, "first")

@test
AN_EXTENSION_MAY_NOT_QUIETLY_REPLACE_A_STANDARD_MEMBER()
    // `{ title: … }` on a `Conflict` really does turn the title into the name of the thing that
    // conflicted, which is how this refusal came to be written.
    var said = null

    problem(409, "Conflict", null, { title: "first" }) catch e ->
        said = e.message

    assertEq(said, "`title` is a standard member of a problem document, so it is an argument rather than an extension")

    problem(409, "Conflict", null, { status: 200 }) catch e ->
        said = e.message

    assertEq(said, "`status` is a standard member of a problem document, so it is an argument rather than an extension")

@test
AN_APPLICATION_WITH_A_URI_OF_ITS_OWN_SAYS_SO_IN_extra()
    val r = problem(402, "Payment Required", null, { type: "https://example.com/probs/out-of-credit" })

    assertEq(doc(r).type, "https://example.com/probs/out-of-credit")

@test
json_IS_HOW_A_HANDLER_SAYS_IT_MEANS_A_DOCUMENT_AND_NOT_AN_ENVELOPE()
    // A bare object answer is a response envelope to `slate:http`, so `{ status: 201 }` would be a
    // note with a `status` field in it rather than a created note.
    val r = json({ id: 1, status: 9 }, 201)

    assertEq(status(r), 201)
    assertEq(header(r, "content-type"), "application/json")
    assertEq(doc(r), { id: 1, status: 9 })

@test
response_READS_A_STRING_A_BYTE_ARRAY_AND_AN_ENVELOPE_ALIKE()
    assertEq(response("hello"), { status: 200, headers: {}, body: "hello" })
    assertEq(response([72, 105]), { status: 200, headers: {}, body: [72, 105] })
    assertEq(response({ status: 204 }), { status: 204, headers: {}, body: "" })
    assertEq(response({ body: "x" }), { status: 200, headers: {}, body: "x" })

@test
response_DOES_NOT_WRITE_INTO_THE_ANSWER_IT_WAS_GIVEN()
    val given = { status: 201, headers: { "X-Kind": "note" } }
    val read = response(given)

    assertEq(read.body, "")
    assert(!has(given, "body"), "the handler's own answer is still what it was")
