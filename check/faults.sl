// A defect in a handler, with nothing configured to catch it.
//
// **Run by hand — see `check/README.md`.** It must print the 500 the client was given and then stop
// the program with `the note store is not there`.

import { api, request, response } from "../sluice.sl"

breaking(req)
    throw "the note store is not there"

async main()
    val app = api()

    app.get("/notes", breaking)

    val r = response(await app.handle(request("GET", "/notes")))

    print("the client was told:", r.status, r.body)
    print("and the fault is on the loop now")

main()
