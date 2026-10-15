// `group` -- a prefix, guards outside a route's own, and a name prefix; and groups inside groups.

import { api, stack, json, logger, guardOf, request } from "../sluice.sl"
import { status, doc } from "./support.sl"

data Failure
    NotYours

answer(f: Failure) = f match
    NotYours -> { status: 403, body: "not yours" }

// A guard that writes its own name onto the request, so a handler can say what it went through and in
// which order.
marking(label: string) -> object = guardOf(label, (h) -> (req) -> h(req with { trail: concat(trailOf(req), [label]) }))

trailOf(req: object) -> array = if has(req, "trail") then req.trail else []

trailed(req: object) -> object = json({ trail: trailOf(req) })

// A guard of the application's own that refuses by returning a failure.
val refusing = guardOf("refusing", (h) -> (req) -> NotYours)

adminRoutes(r: object)
    r.get("/users", trailed, { name: "users" })
    r.group("/v1", [marking("inner")], innerRoutes, { name: "v1" })

innerRoutes(r: object)
    r.get("/stats", stack([marking("own")])(trailed), { name: "stats" })

made() -> object
    val app = api()

    app.group("/admin", [marking("outer")], adminRoutes, { name: "admin" })
    app.get("/open", trailed)

    app

@test
async A_ROUTE_IN_A_GROUP_IS_UNDER_ITS_PREFIX_AND_ITS_GUARDS()
    val r = await made().handle(request("GET", "/admin/users"))

    assertEq(status(r), 200)
    assertEq(doc(r).trail, ["outer"])

@test
async A_GROUP_S_PREFIX_IS_NOT_A_ROUTE_OUTSIDE_IT()
    val app = made()

    // The control: a route outside every group goes through none of their guards.
    assertEq(doc(await app.handle(request("GET", "/open"))).trail, [])
    assertEq(status(await app.handle(request("GET", "/users"))), 404)

@test
async GROUPS_NEST_AND_THE_OUTER_GROUP_S_GUARDS_ARE_OUTERMOST()
    val r = await made().handle(request("GET", "/admin/v1/stats"))

    assertEq(status(r), 200)
    assertEq(doc(r).trail, ["outer", "inner", "own"])

@test
ROUTES_PRINTS_THE_WHOLE_COMPOSITION_AND_THE_NAMES()
    val rows = made().routes()

    assertEq(rows[0].path, "/admin/users")
    assertEq(rows[0].name, "admin.users")
    assertEq(rows[0].guards, ["outer"])
    assertEq(rows[1].path, "/admin/v1/stats")
    assertEq(rows[1].name, "admin.v1.stats")
    assertEq(rows[1].guards, ["outer", "inner", "own"])
    assertEq(rows[2].name, null)

@test
async A_GROUP_TAKES_A_STACK_AS_WELL_AS_A_LIST()
    val app = api()

    app.group("/s", stack([marking("a"), marking("b")]), (r) -> r.get("/x", trailed))

    assertEq(doc(await app.handle(request("GET", "/s/x"))).trail, ["a", "b"])
    assertEq(app.routes()[0].guards, ["a", "b"])

@test
async A_GROUP_WITH_NO_GUARDS_AND_A_ROOT_PATH_IS_JUST_A_PREFIX()
    val app = api()

    app.group("/notes/", [], (r) -> r.get("/", trailed))

    assertEq(app.routes()[0].path, "/notes")
    assertEq(status(await app.handle(request("GET", "/notes"))), 200)

@test
GUARDS_THAT_ARE_NEITHER_A_LIST_NOR_A_STACK_ARE_A_FAULT()
    val app = api()

    assertFaults(() -> app.group("/x", marking("lone"), (r) -> r.get("/", trailed)), "a list or a `stack(…)`")

@test
async A_LOGGER_IN_A_GROUP_ABOVE_A_REFUSING_GUARD_IN_THE_ROUTE_REPORTS_WHAT_THE_CLIENT_GOT()
    // **The mapping is applied between the group's guards and the route's as well**, so the logger the
    // group put outside sees the `403` the failure became, and not the failure value.
    var seen = []
    val app = api()

    app.failures(Failure, answer)
    app.group("/notes", [logger((r) -> push(seen, r))], (r) -> r.get("/:id", stack([refusing])(trailed)))

    assertEq(await app.handle(request("GET", "/notes/7")), { status: 403, body: "not yours" })
    assertEq(seen[0].status, 403)

@test
async A_REFUSING_GUARD_IN_A_GROUP_IS_MAPPED_TOO()
    val app = api()

    app.failures(Failure, answer)
    app.group("/notes", [refusing], (r) -> r.get("/:id", trailed))

    assertEq(await app.handle(request("GET", "/notes/7")), { status: 403, body: "not yours" })
