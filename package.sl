{
    name: "sluice",
    version: "0.2.0",

    // The whole package is one door. `route.sl`, `problem.sl`, `guards.sl` and `testing.sl` are
    // reached from here and are deliberately not listed under `modules` -- what a consumer imports
    // is the framework, and how a path is matched is this package's own business.
    //
    // slate's `export` is a prefix on a declaration and there is no re-export form, so everything
    // public is DECLARED in `sluice.sl` and the files behind it hold the working parts. The
    // declaration is what carries the annotation, and an annotation is the only check a consumer's
    // call gets.
    main: "sluice.sl",
    // `logger` is a DEV dependency: the guard hands a sink a record and the package takes one, and
    // `tests/logging.sl` and `examples/notes.sl` are the only things that use it. A consumer of
    // `sluice` gets neither, so nothing it installs has to carry a logger it did not ask for.
    devDependencies: {
        logger: { git: "github.com/slate-language/logger", version: "0.1.0" },
    },
}
