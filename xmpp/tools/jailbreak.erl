#!/usr/bin/env escript

jailbreak(Dep) when is_atom(Dep) -> Dep;
jailbreak({Dep, _}) -> Dep;
jailbreak({Dep, _, _}) -> Dep.

unconsult(Filename, Terms) ->
    file:write_file(Filename, [io_lib:format("~tp.~n", [T]) || T <- Terms]).

main([]) ->
    case file:consult("rebar.config") of
        {ok, Cfg} ->
            Deps = proplists:get_value(deps, Cfg, []),
            NewDeps = [jailbreak(D) || D <- Deps],
            NewCfg = lists:keyreplace(deps, 1, Cfg, {deps, NewDeps}),
            Result = lists:keydelete(deps_dir, 1, NewCfg),
            unconsult("rebar.config", Result);
        {error, _} -> ok
    end.
