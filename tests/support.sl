// What every test file here needs and nothing more. **It declares no tests of its own**, so
// `slate test tests` walking this directory finds nothing in it to run.

import { response } from "../sluice.sl"

// The problem document out of a response, as the object it is. **A test reads the document rather
// than the text**, because what this package promises is RFC 9457 members and not a byte order.
export doc(reply) -> object
    val parsed = parseJSON(response(reply).body)

    if !parsed.ok then throw "that response body is not JSON: " + response(reply).body

    parsed.value

// The status of any answer, envelope or not.
export status(reply) -> integer = response(reply).status

// One header, whatever case it was written in.
export header(reply, name: string) -> string | null
    for [k, v] in entries(response(reply).headers)
        if lower(k) == lower(name) then return string(v)

    null
