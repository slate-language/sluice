// Groups, resources, and the path a named route is built back into.
//
// **None of it is a second router.** A group is a prefix, a list of guards and a name prefix that
// every route added through it is given; a resource is the seven conventional routes added through
// whatever group it was called on; and both end in the one `add` the api has, so a route added any of
// these ways is matched, composed, mapped and printed exactly as one added with `app.get`.

import { encodeComponent } from slate:http

import { within, guardList } from "./compose.sl"
import { segments } from "./route.sl"

// `routesIn(add, prefix, guards, naming)` -- the route-adding half of an api, under a prefix.
//
// **The api is this with nothing in front of it**, and `group` is this again with more: the prefix
// joined on, the group's guards put OUTSIDE everything a route brings with it, and the name prefix
// put in front of every name. A group inside a group is the same call one level deeper, so nesting
// needed no code of its own.
export routesIn(add: function, prefix: string, outer: array, naming: string) -> object
    on(method: string, path: string, h, options: object) =
        add(method, joined(prefix, path), within(outer, h), renamed(options, naming))

    getRoute(path: string, h, options: object = {}) = on("GET", path, h, options)
    postRoute(path: string, h, options: object = {}) = on("POST", path, h, options)
    putRoute(path: string, h, options: object = {}) = on("PUT", path, h, options)
    patchRoute(path: string, h, options: object = {}) = on("PATCH", path, h, options)
    deleteRoute(path: string, h, options: object = {}) = on("DELETE", path, h, options)
    headRoute(path: string, h, options: object = {}) = on("HEAD", path, h, options)
    optionsRoute(path: string, h, options: object = {}) = on("OPTIONS", path, h, options)
    anyRoute(path: string, h, options: object = {}) = on("", path, h, options)

    // `group(prefix, guards, (r) -> …, options)` -- `build` is handed the routes under the group.
    //
    // **`guards` is a list or a `stack(…)`**, and they go outside a route's own: `concat(outer,
    // given)` is outermost first, so an enclosing group's guards stay outside an inner group's.
    groupRoutes(path: string, guards, build: function, options: object = {})
        val inner = routesIn(add,
                             joined(prefix, path),
                             concat(outer, guardList(guards, "`group`")),
                             naming + groupNaming(options))

        build(inner)

        null

    resourceRoutes(path: string, controller: object, options: object = {}) =
        resourceIn(on, path, controller, options)

    { get: getRoute,
      post: postRoute,
      put: putRoute,
      patch: patchRoute,
      delete: deleteRoute,
      head: headRoute,
      options: optionsRoute,
      any: anyRoute,
      group: groupRoutes,
      resource: resourceRoutes }

// A prefix and a path as one path.
//
// **With no prefix the path is left exactly as it was written**, so a route added straight to the api
// prints in `routes()` the way it was spelled.
export joined(prefix: string, path: string) -> string
    if prefix == "" then return path

    "/" + join(concat(segments(prefix), segments(path)), "/")

// A route's options with the group's name prefix put in front of its name.
renamed(options: object, naming: string) -> object
    if naming == "" || !has(options, "name") || !(options.name is string) then return options

    options with { name: naming + options.name }

// What a group puts in front of the names of the routes inside it: `admin.` for `{ name: "admin" }`.
groupNaming(options: object) -> string
    if !has(options, "name") || options.name == null then return ""

    if !(options.name is string) || options.name == ""
        throw "a group's `name` is a non-empty string, and this is not one"

    options.name + "."

// -- resources -------------------------------------------------------------------------------------

// The conventional routes, in the order they are added.
//
// **`create` comes before `show`**, or `/notes/create` would be `show` with an id of `create`. **`PUT`
// and `PATCH` are both `update`**, and only the first carries the name -- one name for two routes is
// what the duplicate check exists to refuse, and both build the same path anyway.
val Actions = [
    { action: "index", method: "GET", member: false, suffix: "", form: false, named: true },
    { action: "create", method: "GET", member: false, suffix: "/create", form: true, named: true },
    { action: "store", method: "POST", member: false, suffix: "", form: false, named: true },
    { action: "show", method: "GET", member: true, suffix: "", form: false, named: true },
    { action: "edit", method: "GET", member: true, suffix: "/edit", form: true, named: true },
    { action: "update", method: "PUT", member: true, suffix: "", form: false, named: true },
    { action: "update", method: "PATCH", member: true, suffix: "", form: false, named: false },
    { action: "destroy", method: "DELETE", member: true, suffix: "", form: false, named: true }
]

val ActionNames = ["index", "create", "store", "show", "edit", "update", "destroy"]

// `resource(path, controller, options)` -- the actions the controller has, at their conventional
// methods and paths, named `<name>.<action>`.
//
// | option | |
// |---|---|
// | `only`, `except` | the actions to add, or to leave out -- one or the other |
// | `apiOnly` | `true` leaves out `create` and `edit`, the two that only an HTML form wants |
// | `guards` | a list or a `stack(…)` for every action, or an object of them keyed by action, `"*"` for all |
// | `param` | the member routes' parameter, `id` unless this says otherwise |
// | `name` | what the names begin with; the path's last part otherwise |
//
// **A controller is an object whose own members are handlers**, so `{ index: list, show: one }` and
// `{ store: body(NewNote, create) }` are both controllers and an action's own guards print in
// `routes()` after the resource's.
resourceIn(on: function, path: string, controller: object, options: object)
    if has(options, "only") && has(options, "except")
        throw "a resource takes `only` or `except`, and this one was given both"

    val only = actionsIn(options, "only")
    val except = actionsIn(options, "except")
    val param = paramOf(options)
    val base = baseName(path, options)
    val shared = sharedGuards(options)
    val byAction = actionGuards(options)
    val forms = !(has(options, "apiOnly") && options.apiOnly == true)

    for a in only
        if !has(controller, a)
            throw "`only` names `" + a + "`, and the controller for " + path + " has no `" + a + "`"

    var added = 0

    for row in Actions
        val wanted = (forms || !row.form) && (only.length == 0 || contains(only, row.action))

        if wanted && !contains(except, row.action) && has(controller, row.action)
            val guards = concat(shared, byAction[row.action] ?? [])
            val at = memberPath(path, row, param)
            val naming = if row.named then { name: base + "." + row.action } else {}

            on(row.method, at, within(guards, controller[row.action]), naming)

            added = added + 1

    // **A resource that adds nothing is a program put together wrong** -- a controller whose actions
    // are methods of a class rather than members of its own is the likely one, and it would otherwise
    // be a quiet 404 on every path the resource was meant to answer.
    if added == 0
        throw "the resource at " + path + " added no routes: its controller has no member named " + join(ActionNames, ", ")

    null

// `only` or `except`, checked against the seven names.
actionsIn(options: object, key: string) -> array
    if !has(options, key) then return []

    val listed = options[key]

    if !(listed is array) then throw "a resource's `" + key + "` is a list of actions"

    for a in listed
        if !contains(ActionNames, a)
            throw "`" + key + "` names `" + string(a) + "`, which is not one of " + join(ActionNames, ", ")

    listed

paramOf(options: object) -> string
    if !has(options, "param") then return "id"

    if !(options.param is string) || options.param == ""
        throw "a resource's `param` is a non-empty string, and this is not one"

    options.param

// The name a resource's routes begin with: `options.name`, or the last fixed part of its path.
baseName(path: string, options: object) -> string
    if has(options, "name")
        if !(options.name is string) || options.name == ""
            throw "a resource's `name` is a non-empty string, and this is not one"

        return options.name

    val fixed = filter(segments(path), (p) -> !startsWith(p, ":") && !startsWith(p, "*"))

    if fixed.length == 0 then throw "the resource at " + path + " needs a `name`, its path having no fixed part to take one from"

    fixed[fixed.length - 1]

// The guards every action is given.
sharedGuards(options: object) -> array
    if !has(options, "guards") then return []

    val g = options.guards

    if !(g is object) || has(g, "wrappers") then return guardList(g, "a resource")

    if has(g, "*") then guardList(g["*"], "a resource") else []

// The guards each action is given beside the shared ones, by action.
actionGuards(options: object) -> object
    var out = {}

    if !has(options, "guards") then return out

    val g = options.guards

    if g is array || !(g is object) || has(g, "wrappers") then return out

    for [k, v] in entries(g)
        if k != "*"
            if !contains(ActionNames, k)
                throw "a resource's `guards` names `" + k + "`, which is not one of " + join(ActionNames, ", ")

            out[k] = guardList(v, "a resource")

    out

memberPath(path: string, row: object, param: string) -> string
    val stem = if row.member then joinedPath(path, ":" + param) else path

    if row.suffix == "" then stem else joinedPath(stem, row.suffix)

// Two pieces of a path with one slash between them.
joinedPath(a: string, b: string) -> string
    val left = if endsWith(a, "/") then a[0..<(a.length - 1)] else a
    val right = if startsWith(b, "/") then b[1..<b.length] else b

    left + "/" + right

// -- building a path back --------------------------------------------------------------------------

// The route's path with `params` put into it, and `query` after a `?`.
//
// **Every value is percent-encoded with `slate:http`'s `encodeComponent`**, so an id with a slash or
// a space in it is one segment that `percentDecode` gives back exactly. A `*rest` keeps its slashes
// and has each piece between them encoded.
export pathFor(pattern: string, name: string, params: object, query: object) -> string
    var out = []

    for p in segments(pattern)
        if startsWith(p, ":")
            push(out, encodeComponent(given(params, p[1..<p.length], name)))
        elif startsWith(p, "*")
            val key = p[1..<p.length]

            if key != ""
                val pieces = map(split(given(params, key, name), "/"), (piece) -> encodeComponent(piece))

                push(out, join(pieces, "/"))
        else
            push(out, p)

    val path = "/" + join(out, "/")
    val q = queryText(query)

    if q == "" then path else path + "?" + q

// A parameter's value as text, or a fault naming the route and the parameter.
//
// **An empty value is refused with a missing one**: `/notes/` is a different route from
// `/notes/:id`, so a link built with `id: ""` would quietly point at the list.
given(params: object, key: string, name: string) -> string
    val v = if has(params, key) then params[key] else null

    if v == null || string(v) == ""
        throw "`url(\"" + name + "\")` needs `" + key + "`, and was not given one"

    string(v)

// A query object as text. A `null` member is left out, and an array is the name once per value.
queryText(query: object) -> string
    var parts = []

    for [k, v] in entries(query)
        if v is array
            for one in v
                push(parts, encodeComponent(k) + "=" + encodeComponent(string(one)))
        elif v != null
            push(parts, encodeComponent(k) + "=" + encodeComponent(string(v)))

    join(parts, "&")
