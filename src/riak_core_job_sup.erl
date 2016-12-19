%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private
%% @doc Internal Job Runner Supervisor.
%%
%% Refer to the {@link riak_core_job_service} module for the process model.
%%
-module(riak_core_job_sup).
-behaviour(supervisor).

% Private API
-export([
    start_runner/0,
    stop_runner/1
]).

% Supervisor API
-export([
    init/1,
    start_link/0
]).

-ifdef(TEST).
-export([
    start_test_sup/0,
    stop_test_sup/1
]).
-endif.

-include("riak_core_job_internal.hrl").
-include("riak_core_sup_internal.hrl").

-define(RUNNER_SUP,
    {{'simple_one_for_one', 30, 60}, [
        {'job_runner',
            {'riak_core_job_runner', 'start_link', []},
            'temporary', ?WORK_RUN_SHUTDOWN_TIMEOUT,
            'worker', ['riak_core_job_runner']} ]}).

%% ===================================================================
%% Private API
%% ===================================================================

-spec start_runner() -> {'ok', pid()} | {'error', term()}.
%% @private
%% @doc Start a new job runner process.
%%
start_runner() ->
    case supervisor:start_child(?MODULE, []) of
        {'ok', _} = Ret ->
            Ret;
        {'error', _} = Error ->
            Error
    end.

-spec stop_runner(Runner :: pid()) -> 'ok' | {'error', term()}.
%% @private
%% @doc Stop a job runner process.
%%
stop_runner(Runner) ->
    case supervisor:terminate_child(?MODULE, Runner) of
        'ok' ->
            'ok';
        {'error', 'not_found'} ->
            'ok';
        {'error', _} = Error ->
            Error
    end.

%% ===================================================================
%% Supervisor API
%% ===================================================================

-spec start_link() -> {'ok', pid()}.
%% @private
%% @doc Creates the singleton job runner supervisor.
%%
start_link() ->
    supervisor:start_link({'local', ?WORK_SUP_NAME}, ?MODULE, ?MODULE).

-spec init(atom())
        -> {'ok', {
            {supervisor:strategy(), pos_integer(), pos_integer()},
            [supervisor:child_spec()] }}.
%% @private
%% @doc Initializes the job runner supervisor.
%%
-ifdef(TEST).

init('riak_core_job_test_sup') ->
    Children = [
        % Verbatim copy of the relevant specs from riak_core_sup:init/1.
        ?CHILD(riak_core_job_sup, supervisor, ?JOBS_SUP_SHUTDOWN_TIMEOUT),
        ?CHILD(riak_core_job_service, worker, ?JOBS_SVC_SHUTDOWN_TIMEOUT),
        ?CHILD(riak_core_job_manager, worker, ?JOBS_MGR_SHUTDOWN_TIMEOUT)
    ],
    {ok, {{one_for_one, 10, 10}, Children}};

init(?MODULE) ->
    {'ok', ?RUNNER_SUP}.

-else.

init(?MODULE) ->
    {'ok', ?RUNNER_SUP}.

-endif.

%% ===================================================================
%% Test API
%% ===================================================================

-ifdef(TEST).

-spec start_test_sup() -> {'ok', pid()}.
%% @private
%% @doc Starts a supervisor containing the job services for testing.
%%
start_test_sup() ->
    supervisor:start_link(?MODULE, 'riak_core_job_test_sup').

-spec stop_test_sup(pid()) -> 'ok' | {'error', term()}.
%% @private
%% @doc Stops a supervisor created by {@link start_test_sup/0} synchronously.
%%
stop_test_sup(Pid) ->
    Mon = erlang:monitor('process', Pid),
    _ = erlang:unlink(Pid),
    _ = erlang:exit(Pid, 'shutdown'),
    receive
        {'DOWN', Mon, _, _, _} ->
            'ok'
    after
        (?JOBS_MGR_SHUTDOWN_TIMEOUT + 500) ->
            {'error', 'timeout'}
    end.

-endif.
