#!/usr/bin/env escript
-include_lib("xmerl/include/xmerl.hrl").

-spec make_dep_xml(binary(), integer(), list(#xmlElement{})) -> #xmlElement{}.
make_dep_xml(Name, Level, Content) ->
    #xmlElement{name=dependency, attributes=[
        #xmlAttribute{name=name, value=binary_to_list(Name)},
        #xmlAttribute{name=level, value=Level}
    ], content=Content}.

-spec expand_locks(list(), list()) -> list().
expand_locks([{Name, {git, Url, {ref, Rev}}, Level} | Locks], Hashes) ->
    XmlGit = #xmlElement{name=git, attributes=[
        #xmlAttribute{name=url, value=Url},
        #xmlAttribute{name=revision, value=Rev}
    ]},
    [make_dep_xml(Name, Level, [XmlGit]) | expand_locks(Locks, Hashes)];
expand_locks([{Name, {pkg, PkgName, Vsn}, Level} | Locks], Hashes) ->
    Hash = proplists:get_value(Name, Hashes),
    XmlPkg = #xmlElement{name=pkg, attributes=[
        #xmlAttribute{name=name, value=binary_to_list(PkgName)},
        #xmlAttribute{name=version, value=binary_to_list(Vsn)},
        #xmlAttribute{name=hash, value=binary_to_list(Hash)}
    ]},
    [make_dep_xml(Name, Level, [XmlPkg]) | expand_locks(Locks, Hashes)];
expand_locks([], _) -> [].

-spec extract_pkg_hashes(list()) -> [binary()].
extract_pkg_hashes(Attrs) ->
    Props = case Attrs of
                [First|_] -> First;
                [] -> []
            end,
    proplists:get_value(pkg_hash, Props, []).

-spec expand(list()) -> list().
expand([{"1.1.0", Locks}|Attrs]) ->
    expand_locks(Locks, extract_pkg_hashes(Attrs)).

main([LockFile]) ->
    {ok, LFData} = file:consult(LockFile),
    Xml = #xmlElement{name=locks, content=expand(LFData)},
    Export = xmerl:export_simple([Xml], xmerl_xml),
    io:format("~s~n", [lists:flatten(Export)]).
