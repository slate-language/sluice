// Routing: what matches, in what order, and what a request that matches nothing is told.

import { api, request } from "../sluice.sl"
import { doc, status, header } from "./support.sl"

@test
async A_ROUTE_IS_MATCHED_BY_ITS_METHOD_AND_ITS_PATH()
    val app = api()

    app.get("/notes", (req) -> "the notes")
    app.post("/notes", (req) -> "a new note")

    assertEq(await app.handle(request("GET", "/notes")), "the notes")
    assertEq(await app.handle(request("POST", "/notes")), "a new note")

@test
async A_COLON_PARAMETER_BINDS_ONE_SEGMENT_AND_IS_PERCENT_DECODED()
    val app = api()

    app.get("/notes/:id", (req) -> req.params.id)

    assertEq(await app.handle(request("GET", "/notes/7")), "7")
    assertEq(await app.handle(request("GET", "/notes/caf%C3%A9")), "café")

@test
async A_STAR_PARAMETER_TAKES_THE_WHOLE_OF_THE_REST_SLASHES_INCLUDED()
    val app = api()

    app.get("/files/*rest", (req) -> req.params.rest)

    assertEq(await app.handle(request("GET", "/files/a/b/c.txt")), "a/b/c.txt")

@test
async ROUTES_ARE_TRIED_IN_THE_ORDER_THEY_WERE_ADDED()
    // The rule every router has and the only one a reader can predict: a more specific route
    // written second does not win.
    val app = api()

    app.get("/notes/:id", (req) -> "the parameter")
    app.get("/notes/new", (req) -> "the literal")

    assertEq(await app.handle(request("GET", "/notes/new")), "the parameter")

@test
async A_TRAILING_SLASH_IS_THE_SAME_PATH()
    val app = api()

    app.get("/notes", (req) -> "the notes")
    app.get("/", (req) -> "the root")

    assertEq(await app.handle(request("GET", "/notes/")), "the notes")
    assertEq(await app.handle(request("GET", "/")), "the root")

@test
async any_TAKES_WHATEVER_METHOD_ARRIVED()
    val app = api()

    app.any("/health", (req) -> req.method)

    assertEq(await app.handle(request("GET", "/health")), "GET")
    assertEq(await app.handle(request("DELETE", "/health")), "DELETE")

@test
async NOTHING_THERE_IS_A_404_PROBLEM_DOCUMENT()
    val app = api()

    app.get("/notes", (req) -> "the notes")

    val r = await app.handle(request("GET", "/nowhere"))

    assertEq(status(r), 404)
    assertEq(header(r, "content-type"), "application/problem+json")
    assertEq(doc(r).status, 404)
    assertEq(doc(r).title, "Not Found")
    assertEq(doc(r).instance, "/nowhere")

@test
async A_PATH_THERE_UNDER_ANOTHER_METHOD_IS_405_WITH_AN_Allow()
    // The difference between telling a client what to send and telling it the thing is not there.
    val app = api()

    app.get("/notes", (req) -> "the notes")
    app.post("/notes", (req) -> "a new note")

    val r = await app.handle(request("DELETE", "/notes"))

    assertEq(status(r), 405)
    assertEq(header(r, "Allow"), "GET, POST")
    assertEq(doc(r).title, "Method Not Allowed")
    assertEq(doc(r).instance, "/notes")

@test
async notFound_REPLACES_THE_404_AND_SEES_THE_REQUEST()
    val app = api()

    app.get("/notes", (req) -> "the notes")
    app.notFound((req) -> { status: 404, body: "no " + req.path })

    assertEq(await app.handle(request("GET", "/gone")), { status: 404, body: "no /gone" })

@test
async A_405_IS_STILL_A_405_WHERE_A_notFound_IS_SET()
    // The fallback is for a path that is not there, and this one is.
    val app = api()

    app.get("/notes", (req) -> "the notes")
    app.notFound((req) -> "the fallback")

    assertEq(status(await app.handle(request("PUT", "/notes"))), 405)

@test
async handle_DOES_NOT_TOUCH_THE_REQUEST_IT_WAS_GIVEN()
    // A request is a value. The same one handed over twice answers twice, and nothing a route bound
    // is left on it.
    val app = api()

    app.get("/notes/:id", (req) -> req.params.id)

    val req = request("GET", "/notes/7")

    assertEq(await app.handle(req), "7")
    assertEq(await app.handle(req), "7")
    assertEq(keys(req.params), [])

@test
async A_ROUTE_NEEDS_SOMETHING_TO_CALL()
    val app = api()
    var said = null

    app.get("/notes", "not a handler") catch e ->
        said = e.message

    assertEq(said, "a route needs a function to call, and this is not one")
