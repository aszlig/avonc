#!/usr/bin/env escript
-include_lib("xmerl/include/xmerl.hrl").

-spec fetch_names(list()) -> list(#xmlElement{}).
fetch_names([]) -> [];
fetch_names([Name | Deps]) when is_atom(Name) -> [Name | fetch_names(Deps)];
fetch_names([{Name, _}| Deps]) -> [Name | fetch_names(Deps)];
fetch_names([{Name, _, _}| Deps]) -> [Name | fetch_names(Deps)].

main([ConfFile]) ->
    {ok, CFData} = file:consult(ConfFile),
    Deps = proplists:get_value(deps, CFData, []),
    DepNames = [atom_to_list(D) || D <- fetch_names(Deps)],
    DepsXml = [#xmlElement{name=dep, content=[#xmlText{value=D}]}
               || D <- DepNames],
    Xml = #xmlElement{name=deps, content=DepsXml},
    Export = xmerl:export_simple([Xml], xmerl_xml),
    io:format("~s~n", [lists:flatten(Export)]).
