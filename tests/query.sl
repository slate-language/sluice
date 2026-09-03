// `query(Shape)` -- the same check over the query string, which is already an object of strings.

import { api, query, request } from "../sluice.sl"
import { doc, status } from "./support.sl"

type Paging = { page: string, size?: string }
type Counted = { n: integer }

made() -> object
    val app = api()

    app.get("/notes", query(Paging, (req) -> req.query.page))

    app

@test
async A_QUERY_THAT_FITS_REACHES_THE_HANDLER_UNCHANGED()
    val app = made()

    assertEq(await app.handle(request("GET", "/notes", { query: { page: "2" } })), "2")
    assertEq(await app.handle(request("GET", "/notes", { query: { page: "2", size: "10" } })), "2")

@test
async A_QUERY_THAT_DOES_NOT_FIT_IS_A_400_PROBLEM_CARRYING_THE_MISMATCH()
    val app = made()
    val r = await app.handle(request("GET", "/notes"))

    assertEq(status(r), 400)
    assertEq(doc(r).detail, "the query string does not fit Paging")
    assertEq(doc(r).mismatch, [{ path: "page", wanted: "string", got: "nothing" }])

@test
async A_QUERY_IS_TEXT_AND_A_SHAPE_ASKING_FOR_A_NUMBER_NEVER_FITS()
    // Nothing is parsed here and nothing is replaced, which is the difference from `body`. A shape
    // that asks for an `integer` is asking for something a query string cannot carry.
    val app = api()

    app.get("/count", query(Counted, (req) -> "reached"))

    val r = await app.handle(request("GET", "/count", { query: { n: 3 } }))

    assertEq(status(r), 400)
    assertEq(doc(r).mismatch, [{ path: "n", wanted: "integer", got: "string" }])
