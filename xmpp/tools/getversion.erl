#!/usr/bin/env escript
read_and_print(Path) ->
    {ok, [{application, _, Attrs}]} = file:consult(Path),
    io:format("~s", [proplists:get_value(vsn, Attrs)]).

main([PkgRoot]) ->
    case filelib:wildcard("src/*.app.src", PkgRoot) of
        [AppInfo] -> read_and_print(PkgRoot ++ "/" ++ AppInfo);
        [] -> [App] = filelib:wildcard("ebin/*.app", PkgRoot),
              read_and_print(PkgRoot ++ "/" ++ App)
    end.
