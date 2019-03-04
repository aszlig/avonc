#!/usr/bin/env escript
get_pkgdesc(Path) ->
    {ok, Target} = file:read_link(Path),
    [Pkg, Ver] = string:split(filename:basename(Target), "-"),
    PkgBin = list_to_binary(Pkg),
    VerBin = list_to_binary(Ver),
    [{{PkgBin, VerBin}, [[], <<"">>, [<<"rebar3">>]]}, {PkgBin, [[VerBin]]}].

gather_packages(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:flatten([get_pkgdesc(filename:join(Path, F)) || F <- Names]);
        {error, _} ->
            []
    end.

main([]) ->
    Pkgs = gather_packages("_build/default/lib")
        ++ gather_packages("_build/default/plugins"),
    ets:new(hex_registry, [named_table, public]),
    ets:insert(hex_registry, Pkgs),
    ets:tab2file(hex_registry, ".cache/rebar3/hex/default/registry").
