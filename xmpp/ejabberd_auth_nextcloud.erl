%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_nextcloud.erl
%%% Author  : aszlig <aszlig@nix.build>
%%% Purpose : Authentication via Nextcloud XMPP app
%%% Created : 05 Mar 2019 by aszlig <aszlig@nix.build>
%%%----------------------------------------------------------------------

-module(ejabberd_auth_nextcloud).
-author('aszlig@nix.build').

-behaviour(ejabberd_gen_auth).

%% External exports
-export([start/1,
         set_password/3,
         authorize/1,
         try_register/3,
         dirty_get_registered_users/0,
         get_vh_registered_users/1,
         get_vh_registered_users/2,
         get_vh_registered_users_number/1,
         get_vh_registered_users_number/2,
         get_password/2,
         get_password_s/2,
         does_user_exist/2,
         remove_user/2,
         remove_user/3,
         store_type/1,
         stop/1]).

%% Pre-mongoose_credentials API
-export([check_password/3,
         check_password/5]).

-include("mongoose.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec start(binary()) -> ok.
start(_Host) -> ok.

-spec store_type(binary()) -> external.
store_type(_Server) -> external.

-spec authorize(mongoose_credentials:t()) -> {ok, mongoose_credentials:t()}
                                           | {error, any()}.
authorize(Creds) ->
    ejabberd_auth:authorize_with_check_password(?MODULE, Creds).

-spec check_password(jid:luser(), jid:lserver(), binary()) -> boolean().
check_password(LUser, LServer, Password) ->
    case make_req(<<"auth">>, LUser, LServer, Password) of
        {ok, _} -> true;
        _ -> false
    end.

-spec check_password(jid:luser(), jid:lserver(), binary(), binary(), fun()) ->
    boolean().
check_password(LUser, LServer, Password, _Digest, _DigestGen) ->
    case make_req(<<"auth">>, LUser, LServer, Password) of
        {ok, _} -> true;
        _ -> false
    end.

-spec set_password(jid:luser(), jid:lserver(), binary()) ->
    {error, not_allowed}.
set_password(_LUser, _LServer, _Password) -> {error, not_allowed}.

-spec try_register(jid:luser(), jid:lserver(), binary()) ->
    {error, not_allowed}.
try_register(_LUser, _LServer, _Password) -> {error, not_allowed}.

-spec dirty_get_registered_users() -> [].
dirty_get_registered_users() ->
    [].

-spec get_vh_registered_users(jid:lserver()) -> [].
get_vh_registered_users(_Server) ->
    [].

-spec get_vh_registered_users(jid:lserver(), list()) -> [].
get_vh_registered_users(_Server, _Opts) ->
    [].

-spec get_vh_registered_users_number(binary()) -> 0.
get_vh_registered_users_number(_Server) ->
    0.

-spec get_vh_registered_users_number(jid:lserver(), list()) -> 0.
get_vh_registered_users_number(_Server, _Opts) ->
    0.

-spec get_password(jid:luser(), jid:lserver()) -> false.
get_password(_LUser, _LServer) -> false.

-spec get_password_s(jid:luser(), jid:lserver()) -> binary().
get_password_s(_User, _Server) -> <<>>.

-spec does_user_exist(jid:luser(), jid:lserver()) -> boolean().
does_user_exist(LUser, LServer) ->
    case make_req(<<"isuser">>, LUser, LServer, none) of
        {ok, true} -> true;
        _ -> false
    end.

-spec remove_user(jid:luser(), jid:lserver()) ->
    {error, not_allowed}.
remove_user(_LUser, _LServer) ->
    {error, not_allowed}.

-spec remove_user(jid:luser(), jid:lserver(), binary()) ->
    {error, not_allowed}.
remove_user(_LUser, _LServer, _Password) ->
    {error, not_allowed}.

-spec stop(binary()) -> ok.
stop(_Host) -> ok.

%%%----------------------------------------------------------------------
%%% Request maker
%%%----------------------------------------------------------------------

-spec make_req(binary(), binary(), binary(), binary() | none) ->
    {ok, true | false | binary()} |
    {error, invalid_jid | unknown_error | not_authorized}.
make_req(_, LUser, LServer, _) when LUser == error orelse LServer == error ->
    {error, invalid_jid};
make_req(Operation, LUser, LServer, Password) ->
    OperationE = list_to_binary(http_uri:encode(binary_to_list(Operation))),
    LUserE = list_to_binary(http_uri:encode(binary_to_list(LUser))),
    LServerE = list_to_binary(http_uri:encode(binary_to_list(LServer))),

    BaseQuery = <<"operation=", OperationE/binary, "&username=", LUserE/binary,
                  "&domain=", LServerE/binary>>,

    Query = case Password of
        none -> BaseQuery;
        _    -> Encoded = http_uri:encode(binary_to_list(Password)),
                PasswordE = list_to_binary(Encoded),
                <<BaseQuery/binary, "&password=", PasswordE/binary>>
    end,

    ?DEBUG("Making request '~s' for user ~s@~s...",
           [Operation, LUser, LServer]),

    Path = <<"apps/ojsxc/ajax/externalApi.php">>,
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],

    {ok, {Code, RespBody}} =
        mongoose_http_client:post(LServer, auth, Path, Headers, Query),

    Body = jiffy:decode(RespBody, [return_maps]),

    ?DEBUG("Request result: ~s: ~p", [Code, Body]),

    case Body of
        #{<<"result">> := <<"error">>, <<"data">> := #{<<"msg">> := ErrMsg}} ->
            {error, ErrMsg};
        #{<<"result">> := <<"error">>} ->
            {error, unknown_error};
        #{<<"result">> := <<"noauth">>} ->
            {error, not_authorized};
        #{<<"result">> := <<"success">>, <<"data">> := Data} ->
            handle_result(Operation, Data)
    end.

-spec handle_result(binary(), map()) ->
    {ok, true | false | binary()} | {error, invalid_jid}.
handle_result(<<"isuser">>, #{<<"isUser">> := true}) ->
    {ok, true};
handle_result(<<"isuser">>, #{<<"isUser">> := _}) ->
    {ok, false};
handle_result(<<"auth">>, #{<<"uid">> := UserId}) ->
    {ok, UserId};
handle_result(_, _) ->
    {error, invalid_jid}.
