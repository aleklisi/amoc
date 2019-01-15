-module(pubsub_simple).

-behavior(amoc_scenario).

-include_lib("exml/include/exml.hrl").
-include_lib("escalus/include/escalus.hrl").

-define(HOST, <<"localhost">>). %% The virtual host served by the server
-define(PUBSUB_ADDR, <<"pubsub.localhost">>).
-define(WAIT_FOR_STANZA_TIMEOUT, 10000).
-define(GROUPNAME, <<"pubsub_test_group_name">>).
-define(DELAY_BETWEEN_MESSAGES, 100).
-define(WAIT_FOR_NODES, 10000).

-define(NODE_CREATE_TIME, [amoc, timers, node_create_time]).
-define(SUBSCRIBE_TIME, [amoc, timers, subscribe_time]).
-define(PUBLISH_TIME, [amoc, timers, publish_time]).

-define(NODE_CREATE_FAILS_COUTER, [amoc, counters, node_create_failed]).
-define(SUBSCRIBE_FAILS_COUTER, [amoc, counters, subscribe_failed]).
-define(PUBLISH_FAILS_COUTER, [amoc, counters, publish_failed]).

-define(NODE_CREATE_SUCCESS_COUTER, [amoc, counters, node_create_success]).
-define(SUBSCRIBE_SUCCESS_COUTER, [amoc, counters, subscribe_success]).
-define(PUBLISH_SUCCESS_COUTER, [amoc, counters, publish_success]).
-define(MESSAGE_TTD_CT, [amoc, times, message_ttd]).


-export([init/0]).
-export([start/1]).

-required_variable({'NUMBER_OF_NODE_CREATORS', <<"Specifies how many users will create node"/utf8>>}).
-required_variable({'PUBLISHERS_RATIO', <<"Specifies the number of publishers per 10 users"/utf8>>}).

-spec init() -> ok.
init() ->
    init_metrics(),
    ok.

-spec start(amoc_scenario:user_id()) -> any().
start(Id) ->
    pg2:create(?GROUPNAME),
    CreatorsNumber = amoc_config:get('NUMBER_OF_NODE_CREATORS', 3),
    Client = connect_amoc_user(Id),
    lager:info("~p~p", [Id, Client]),
    case assign_role(Id, CreatorsNumber) of
        creator ->
            creator_start(Client);
        publisher ->
            publisher_start(Client);
        subscriber ->
            subscriber_start(Client)
    end.

%% --- Metrics ---------------------------------------------------------------------------------------------

init_metrics() ->
    Stats =
    [
        {?NODE_CREATE_FAILS_COUTER, spiral},
        {?SUBSCRIBE_FAILS_COUTER, spiral},
        {?PUBLISH_FAILS_COUTER, spiral},
        {?NODE_CREATE_SUCCESS_COUTER, spiral},
        {?SUBSCRIBE_SUCCESS_COUTER, spiral},
        {?PUBLISH_SUCCESS_COUTER, spiral},
        {?NODE_CREATE_TIME, histogram},
        {?SUBSCRIBE_TIME, histogram},
        {?PUBLISH_TIME, histogram},
        {?MESSAGE_TTD_CT, histogram}
    ],
    [create_stat(Path, GraphType) ||  {Path, GraphType} <- Stats].

create_stat(Path, spiral) ->
    exometer:new(Path, spiral),
    exometer_report:subscribe(exometer_report_graphite, Path, [one, count], 1000);

create_stat(Path, histogram) ->
    exometer:new(Path, histogram),
    exometer_report:subscribe(exometer_report_graphite, Path, [mean, min, max, median, 95, 99, 999], 1000).
%% ----------------------------------------------------------------------------------------------------------

assign_role(Id, CreatorsNumber) when Id < CreatorsNumber ->
    creator;
assign_role(Id, _CreatorsNumber) ->
    Numerator = amoc_config:get('PUBLISHERS_RATIO', 4),
    case Id rem 10 of
        X when X < Numerator ->
            publisher;
        _ ->
            subscriber
    end.
%% --- Creator ----------------------------------------------------------------------------------------------
creator_start(Client) ->
    pg2:join(?GROUPNAME, self()),
    Nodes = [create_pubsub_node(Client)],
    lager:info("Created, node: ~p~n", [Nodes]),
    schedule(start_publishing_items, ?DELAY_BETWEEN_MESSAGES),
    creator_loop(Client, Nodes).

creator_loop(Client, Nodes) ->
    receive
        {message, {what_nodes, PID}} ->
            PID ! {nodes, Nodes};
        {scheduled, start_publishing_items} ->
            schedule(publish_item, ?DELAY_BETWEEN_MESSAGES);
        {scheduled, publish_item} ->
            schedule(publish_item, ?DELAY_BETWEEN_MESSAGES),
            publish(Client, Nodes)
    end,
    creator_loop(Client, Nodes).

%% --- Publisher --------------------------------------------------------------------------------------------
publisher_start(Client) ->
    Nodes = get_nodes(3, Client),
    lager:info("Publisher, node: ~p~n", [Nodes]),
    schedule({publish_item, 1}, ?DELAY_BETWEEN_MESSAGES),
    publisher_loop(Client, Nodes).

publisher_loop(Client, Nodes) ->
    receive
        {scheduled, publish_item} ->
            publish(Client, Nodes),
            schedule(publish_item, ?DELAY_BETWEEN_MESSAGES)
    end,
    publisher_loop(Client, Nodes).

publish(Client, Nodes) ->
    lager:debug("Published ~p ~n", [Nodes]),
    [ publish_pubsub_item(Client, Node) || Node <- Nodes ].

%% --- Subscriber -------------------------------------------------------------------------------------------
subscriber_start(Client) ->
    Nodes = get_nodes(3, Client),
    lager:info("Subscriber, node: ~p~n", [Nodes]),
    [subscribe(Client, Node) || Node <- Nodes],
    subscriber_loop(Client).

subscriber_loop(Client) ->
    try escalus:wait_for_stanza(Client, ?WAIT_FOR_STANZA_TIMEOUT) of
        Stanza ->
            escalus:assert(is_message, Stanza),
            Item = exml_query:path(Stanza, [{element, <<"event">>}, {element, <<"items">>}, {element, <<"item">>}]),
            TimeStampBin = exml_query:attr(Item, <<"id">>),
            TimeStamp = binary_to_integer(TimeStampBin),
            TTD =  os:system_time(microsecond) - TimeStamp,
            exometer:update(?MESSAGE_TTD_CT, TTD),
            lager:info("~n~n~p~n~n", [Stanza])
    catch
        Error:Reason ->
            lager:error("No items received! ~p~n ~p~n", [Error, Reason])
    end,
    subscriber_loop(Client).

%% --- Scheduler --------------------------------------------------------------------------------------------

schedule(Msg, Timeout) ->
    erlang:send_after(Timeout, self(), {scheduled, Msg}).

%% --- Nodes discovery --------------------------------------------------------------------------------------

get_nodes(0, _) ->
    lager:error("Client: NO NODES PROVIDED"),
    [];
get_nodes(Retries, Client) ->
    case erlang:get(nodes_names) of
        {nodes_names, Nodes} ->
            Nodes;
        _ ->
            Member = try_get_member([]),
            Member ! {message, {what_nodes, self()}},
            receive
                {nodes, Nodes} ->
                    erlang:put(nodes_names, {nodes_names, Nodes}),
                    Nodes
            after
                ?WAIT_FOR_NODES ->
                    get_nodes(Retries - 1, Client)
            end
    end.

%% --- User helpers -----------------------------------------------------------------------------------------
connect_amoc_user(Id) ->
    connect_amoc_user(Id, <<"res1">>).

connect_amoc_user(Id, Resource) ->
    Cfg = make_user(Id, Resource),
    {ok, Client, _} = escalus_connection:start(Cfg),
    Client.

user_spec(ProfileId, Password, Res) ->
    ConnectionDetails = pick_server(),
    [ {username, ProfileId},
      {server, ?HOST},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res}
    ] ++ ConnectionDetails.

make_user(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = <<"user_", BinId/binary>>,
    Password = <<"password_", BinId/binary>>,
    user_spec(ProfileId, Password, R).

-spec pick_server() -> [proplists:property()].
pick_server() ->
    Servers = amoc_config:get(xmpp_servers),
    verify(Servers),
    S = length(Servers),
    N = erlang:phash2(self(), S) + 1,
    lists:nth(N, Servers).

verify(Servers) ->
    lists:foreach(
      fun(Proplist) ->
              true = proplists:is_defined(host, Proplist)
      end,
      Servers
     ).

%% ----------------------------------------------------------------------------------------------------------
create_pubsub_node(Client) ->
    Node = pubsub_node(),
    ReqId = id(Client, Node, <<"create">>),
    NodeConfig = [{<<"pubsub#subscribe">>, <<"1">>},
                  {<<"pubsub#access_model">>, <<"open">>},
                  {<<"pubsub#publish_model">>, <<"open">>}],
    Request = escalus_pubsub_stanza:create_node(Client, ReqId,
						Node, NodeConfig),
    escalus:send(Client, Request),
    {CreateNodeTime, CreateNodeResult} = timer:tc(
        fun() ->
            escalus:wait_for_stanza(Client, ?WAIT_FOR_STANZA_TIMEOUT)
        end),

    case escalus_pred:is_iq_result(CreateNodeResult) of
        true ->
            exometer:update(?NODE_CREATE_SUCCESS_COUTER, 1),
            exometer:update(?NODE_CREATE_TIME, CreateNodeTime);
        Error ->
            exometer:update(?NODE_CREATE_FAILS_COUTER, 1),
            lager:error("Error creating node: ~p", [Error]),
            exit(connection_failed)
    end,
    Node.

pubsub_node() ->
    {?PUBSUB_ADDR, pubsub_node_name()}.

rand_name(Prefix) ->
    Suffix = base64:encode(crypto:strong_rand_bytes(5)),
    <<Prefix/binary, "_", Suffix/binary>>.

pubsub_node_name() ->
    Name0 = rand_name(<<"princely_musings">>),
    re:replace(Name0, "/", "_", [global, {return, binary}]).

id(Client, {NodeAddr, NodeName}, Suffix) ->
    UserName = escalus_utils:get_username(Client),
    list_to_binary(io_lib:format("~s-~s-~s-~s",
				 [UserName, NodeAddr, NodeName, Suffix])).

subscribe(Client, Node) ->
    Id = id(Client, Node, <<"subscribe">>),
    Request = escalus_pubsub_stanza:subscribe(Client, Id, Node),
    escalus:send(Client, Request),
    {SubscribeTime, SubscribeResult} = timer:tc(
        fun() ->
            escalus:wait_for_stanza(Client, ?WAIT_FOR_STANZA_TIMEOUT)
        end),
    case escalus_pred:is_iq_result(SubscribeResult) of
        true ->
            exometer:update(?SUBSCRIBE_SUCCESS_COUTER, 1),
            exometer:update(?SUBSCRIBE_TIME, SubscribeTime);
        Error ->
            exometer:update(?SUBSCRIBE_FAILS_COUTER, 1),
            lager:error("Error subscribing node ~p filed: ~p", [Node, Error]),
            exit(connection_failed)
        end.

publish_pubsub_item(Client, Node) ->
    Id = id(Client, Node, <<"publish">>),
    ItemId = integer_to_binary(os:system_time(microsecond)),
    Request = escalus_pubsub_stanza:publish(Client, ItemId, item_content(), Id, Node),
    escalus:send(Client, Request),
    {PublishTime, PublishResult} = timer:tc(
        fun() ->
            escalus:wait_for_stanza(Client, ?WAIT_FOR_STANZA_TIMEOUT)
        end),
    case escalus_pred:is_iq_result(PublishResult) of
        true ->
            exometer:update(?PUBLISH_SUCCESS_COUTER, 1),
            exometer:update(?PUBLISH_TIME, PublishTime);
        Error ->
            exometer:update(?PUBLISH_FAILS_COUTER, 1),
            lager:error("Error subscribing node ~p filed: ~p", [Node, Error]),
            exit(connection_failed)
        end.

item_content() ->
    #xmlel{name = <<"entry">>,
           attrs = [{<<"xmlns">>, <<"http://www.w3.org/2005/Atom">>}]}.

%% --- General Helpers ------------------------------------------------------------------------------------------------

try_get_member([]) ->
    Members = pg2:get_members(?GROUPNAME),
    try_get_member(Members);
try_get_member(Members) ->
    L = length(Members),
    N = erlang:phash2(self(), L) + 1,
    lists:nth(N, Members).
