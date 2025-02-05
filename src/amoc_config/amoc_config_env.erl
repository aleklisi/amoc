%%==============================================================================
%% Copyright 2023 Erlang Solutions Ltd.
%% Licensed under the Apache License, Version 2.0 (see LICENSE file)
%%==============================================================================
%% This module can be used directly only for the readonly env init parameters.
%% do not use it for the scenarios/helpers configuration, amoc_config module
%% must be used instead! This allows to provide configuration via REST API in
%% a JSON format
%%==============================================================================
-module(amoc_config_env).

-export([get/1, get/2]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_PARSER_MODULE, amoc_config_parser).

-callback(parse_value(string()) -> {ok, amoc_config:value()} | {error, any()}).

%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------
-spec get(amoc_config:name()) -> amoc_config:value().
get(Name) ->
    get(Name, undefined).

-spec get(amoc_config:name(), amoc_config:value()) -> amoc_config:value().
get(Name, Default) when is_atom(Name) ->
    get_os_env(Name, Default).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec get_os_env(amoc_config:name(), amoc_config:value()) -> amoc_config:value().
get_os_env(Name, Default) ->
    EnvName = os_env_name(Name),
    Value = os:getenv(EnvName),
    case parse_value(Value, Default) of
        {ok, Term} -> Term;
        {error, Error} ->
            ?LOG_ERROR("cannot parse environment variable, using default value.~n"
                          "  parsing error:  '~p'~n"
                          "  variable name:  '$~s'~n"
                          "  variable value: '~s'~n"
                          "  default value:  '~p'~n",
                       [Error, EnvName, Value, Default]),
            Default
    end.

-spec os_env_name(amoc_config:name()) -> string().
os_env_name(Name) when is_atom(Name) ->
    "AMOC_" ++ string:uppercase(erlang:atom_to_list(Name)).

-spec parse_value(string() | false, any()) -> {ok, amoc_config:value()} | {error, any()}.
parse_value(false, Default) -> {ok, Default};
parse_value("", Default)    -> {ok, Default};
parse_value(String, _) ->
    App = application:get_application(?MODULE),
    Mod = application:get_env(App, config_parser_mod, ?DEFAULT_PARSER_MODULE),
    try Mod:parse_value(String) of
        {ok, Value} -> {ok, Value};
        {error, Error} -> {error, Error};
        InvalidRetValue -> {error, {parser_returned_invalid_value, InvalidRetValue}}
    catch
        Class:Error:Stacktrace ->
            {error, {parser_crashed, {Class, Error, Stacktrace}}}
    end.
