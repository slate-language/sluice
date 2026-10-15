// Named routes -- `{ name }` on a route, `url` building its path back, and the mistakes that fault.

import { api, json, request } from "../sluice.sl"
import { status, doc } from "./support.sl"

echo(req: object) -> object = json({ params: req.params })

made() -> object
    val app = api()

    app.get("/notes/:id", echo, { name: "notes.show" })
    app.get("/files/*rest", echo, { name: "files" })
    app.get("/", echo, { name: "home" })
    app.post("/notes", echo)

    app

@test
URL_BUILDS_THE_PATH_OF_A_NAMED_ROUTE()
    val app = made()

    assertEq(app.url("notes.show", { id: 7 }), "/notes/7")
    assertEq(app.url("home"), "/")

@test
async URL_PERCENT_ENCODES_A_PARAMETER_AND_THE_ROUTE_DECODES_IT_BACK()
    val app = made()
    val built = app.url("notes.show", { id: "a b/c?d" })

    assertEq(built, "/notes/a%20b%2Fc%3Fd")
    // The round trip: the path the route matches is the one `url` built, and the id comes back whole.
    assertEq(doc(await app.handle(request("GET", built))).params.id, "a b/c?d")

@test
async A_REST_PARAMETER_KEEPS_ITS_SLASHES_AND_ENCODES_EACH_PIECE()
    val app = made()
    val built = app.url("files", { rest: "docs/my file.txt" })

    assertEq(built, "/files/docs/my%20file.txt")
    assertEq(status(await app.handle(request("GET", built))), 200)

@test
URL_PUTS_THE_QUERY_AFTER_A_QUESTION_MARK()
    val app = made()

    assertEq(app.url("notes.show", { id: 1 }, { page: 2, q: "a&b", gone: null }), "/notes/1?page=2&q=a%26b")
    assertEq(app.url("home", {}, { tag: ["x", "y z"] }), "/?tag=x&tag=y%20z")
    assertEq(app.url("home", {}, {}), "/")

@test
AN_UNKNOWN_NAME_IS_A_FAULT()
    assertFaults(() -> made().url("notes.list"), "no route named `notes.list`")

@test
A_MISSING_PARAMETER_IS_A_FAULT_AND_SO_IS_AN_EMPTY_ONE()
    val app = made()

    assertFaults(() -> app.url("notes.show"), "needs `id`")
    assertFaults(() -> app.url("notes.show", { ID: 7 }), "needs `id`")
    assertFaults(() -> app.url("notes.show", { id: "" }), "needs `id`")
    assertFaults(() -> app.url("files", { rest: null }), "needs `rest`")

@test
A_DUPLICATE_NAME_IS_REFUSED_WHERE_IT_IS_ADDED()
    val app = made()

    assertFaults(() -> app.get("/posts/:id", echo, { name: "notes.show" }), "`notes.show` is taken -- GET /notes/:id")
    // The refused route was not added, so the name still builds the first route's path.
    assertEq(app.url("notes.show", { id: 1 }), "/notes/1")
    assertEq(app.routes().length, 4)

@test
A_NAME_THAT_IS_NOT_A_STRING_IS_A_FAULT()
    assertFaults(() -> api().get("/x", echo, { name: 5 }), "non-empty string")
    assertFaults(() -> api().group("/x", [], (r) -> r.get("/", echo), { name: "" }), "non-empty string")

@test
ROUTES_SHOWS_THE_NAMES_AND_NULL_FOR_A_ROUTE_WITH_NONE()
    assertEq(map(made().routes(), (r) -> r.name), ["notes.show", "files", "home", null])
