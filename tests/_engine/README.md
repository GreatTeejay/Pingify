The engine's Go tests.

They are here rather than beside the code because the code is not in this
repository, and the directory begins with an underscore so the Go tool walks
past it rather than trying to build a package out of test files alone - Pingify.sh carries it, and build.sh embeds every Go file except
these. Put the tree back and lay these over it:

    PINGIFY_NO_MAIN=1 bash -c '. ./Pingify.sh; write_core_sources .'
    cp -r tests/_engine/internal tests/_engine/cmd . 2>/dev/null
    go test -race ./...

That is what the release workflow does, so what runs in CI is the code a
server would extract and compile, with these tests laid over it.
