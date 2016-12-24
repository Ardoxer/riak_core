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
%% @doc Internal Job Management Service.
%%
%% Processes:
%%
%%  ===Manager===
%%
%%    * Module {@link riak_core_job_manager}
%%
%%    * Public API - ALL external interaction is through this module.
%%
%%    * Owned by the `riak_core' application supervisor.
%%
%%    * Calls into the Service and active Runners.
%%
%%  ===Service===
%%
%%    * Module {@link riak_core_job_service}
%%
%%    * Private Runner service, called ONLY by the Manager.
%%
%%    * Owned by the `riak_core' application supervisor.
%%
%%    * Calls into the Supervisor and active/idle Runners.
%%
%%  ===Supervisor===
%%
%%    * Module {@link riak_core_job_sup}
%%
%%    * Owner of Runner processes, called ONLY by the Service.
%%
%%    * Owned by the `riak_core' application supervisor.
%%
%%    * Creates and destroys Runner processes.
%%
%%  ===Runner===
%%
%%    * Module {@link riak_core_job_runner}
%%
%%    * Process that actually executes submitted Jobs.
%%
%%    * Owned by the Supervisor.
%%
%%    * Lifecycle managed by the Service.
%%
%%    * Work submitted by the Manager.
%%
%% The unidirectional dependency model is strictly adhered to!
%%
-module(riak_core_job_service).
-behaviour(gen_server).

% Private API
-export([
    app_config/1,
    app_config/2,
    app_config/3,
    app_config/4,
    config/0,
    default_app/0,
    release/1,
    runner/0,
    stats/0
]).

% Private Types
-export_type([
    cfg_idle_max/0,
    cfg_idle_min/0,
    cfg_mult/0,
    cfg_prop/0,
    config/0,
    runner/0,
    stat/0,
    stat_key/0,
    stat_val/0
]).

% Gen_server API
-export([
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    init/1,
    start_link/0,
    terminate/2
]).

-include("riak_core_job_internal.hrl").

%% ===================================================================
%% Types
%% ===================================================================

-define(StatsDict,  orddict).
-type stats()   ::  ?orddict_t(stat_key(), stat_val()).

% Idle Runner.
-record(rrec, {
    ref     ::  rkey(),
    pid     ::  runner()
}).

% Make sure icnt/idle are kept in sync!
-record(state, {
    icnt        = 0                         ::  non_neg_integer(),
    imin        = 0                         ::  non_neg_integer(),
    imax        = 0                         ::  non_neg_integer(),
    recycle     = ?JOB_SVC_DEFAULT_RECYCLE  ::  boolean(),
    pending     = false                     ::  boolean(),
    shutdown    = false                     ::  boolean(),
    idle        = queue:new()               ::  idle(),
    stats       = ?StatsDict:new()          ::  stats()
}).

-type cfg_idle_max()    ::  {?JOB_SVC_IDLE_MAX, non_neg_integer() | cfg_mult()}.
-type cfg_idle_min()    ::  {?JOB_SVC_IDLE_MIN, non_neg_integer() | cfg_mult()}.
-type cfg_recycle()     ::  {?JOB_SVC_RECYCLE,  boolean()}.

-type cfg_mult()    ::  {concur | cores | scheds, non_neg_integer()}.
-type cfg_prop()    ::  cfg_idle_max() | cfg_idle_min() | cfg_recycle().
-type config()      ::  [cfg_prop()].
-type idle()        ::  ?queue_t(#rrec{}).
-type rkey()        ::  reference().
-type runner()      ::  pid().
-type stat()        ::  {stat_key(), stat_val()}.
-type stat_key()    ::  atom() | tuple().
-type stat_val()    ::  term().
-type state()       ::  #state{}.

%% ===================================================================
%% Private API
%% ===================================================================

-spec app_config(Key :: atom()) -> non_neg_integer().
%% @private
%% @doc Returns the configured value for Key in the default application scope.
%%
%% @equiv app_config(default_app(), Key)
%%
app_config(Key) ->
    app_config(default_app(), Key).

-spec app_config(App :: atom(), Key :: atom()) -> term().
%% @private
%% @doc Returns the configured value for Key in the specified application scope.
%%
%% @see app_config/4
%%
app_config(App, ?JOB_SVC_CONCUR_LIMIT = Key) ->
    app_config(App, Key, 0, ?JOB_SVC_DEFAULT_CONCUR);

app_config(App, ?JOB_SVC_IDLE_MIN = Key) ->
    Cur = app_config(App, ?JOB_SVC_CONCUR_LIMIT),
    Def = if
        Cur > 0 ->
            erlang:min(Cur, erlang:max(Cur div 8, 3));
        ?else ->
            % Don't fire up a bunch of idle processes that'll never be used.
            0
    end,
    app_config(App, Key, 0, Def);

app_config(App, ?JOB_SVC_IDLE_MAX = Key) ->
    Min = app_config(App, ?JOB_SVC_IDLE_MIN),
    Def = erlang:max((Min * 2), (resolve_config_val(App, {scheds, 1}) - 1)),
    app_config(App, Key, Min, Def);

app_config(App, ?JOB_SVC_RECYCLE = Key) ->
    % Special handling, it's a simple boolean().
    case application:get_env(App, Key) of
        {ok, Bool} when erlang:is_boolean(Bool) ->
            Bool;
        _ ->
            Def = ?JOB_SVC_DEFAULT_RECYCLE,
            _ = application:set_env(App, Key, Def),
            Def
    end;

app_config(App, Key) ->
    app_config(App, Key, 0, 0).

-spec app_config(
    Key :: atom(),
    Min :: non_neg_integer(),
    Def :: non_neg_integer() | cfg_mult()) -> term().
%%
%% @doc Returns the configured or default value for Key in the default
%%      application scope.
%%
%% @equiv app_config(default_app(), Key, Min, Def)
%%
app_config(Key, Min, Def) ->
    app_config(default_app(), Key, Min, Def).

-spec app_config(
    App :: atom(),
    Key :: atom(),
    Min :: non_neg_integer(),
    Def :: non_neg_integer() | cfg_mult()) -> term().
%%
%% @doc Returns the configured or default value for Key in the specified
%%      application scope.
%%
%% Min is used to range check the value from the environment; if the check is
%% not satisfied, the Default value is used.
%%
%% Multipliers are handled as described in the riak_core_job_manager module
%% documentation.
%%
%% Default (and ONLY Default) is allowed be a multiplier.
%%
app_config(App, Key, Min, Def) ->
    EnvVal = case application:get_env(App, Key) of
        undefined ->
            undefined;
        {ok, EV} ->
            EV
    end,
    CalcVal = case EnvVal of
        Val when erlang:is_integer(Val) andalso Val >= Min ->
            Val;
        Val when erlang:is_integer(Val) ->
            DefVal = resolve_config_val(App, Def),
            _ = lager:warning(
                "~s.~s: out of range: ~p, using default ~p",
                [App, Key, EnvVal, Def]),
            DefVal;
        {concur, CV} when Key == ?JOB_SVC_CONCUR_LIMIT
                andalso ?is_non_neg_int(CV) ->
            resolve_config_val(App, {scheds, CV});
        undefined ->
            resolve_config_val(App, Def);
        _ ->
            case resolve_config_val(App, EnvVal) of
                einval ->
                    CalcDef = resolve_config_val(App, Def),
                    _ = lager:warning(
                        "~s.~s: invalid: ~p, using default ~p",
                        [App, Key, EnvVal, Def]),
                    CalcDef;
                Calc when Calc >= Min ->
                    Calc;
                _ ->
                    DefCalc = resolve_config_val(App, Def),
                    _ = lager:warning(
                        "~s.~s: out of range: ~p, using default ~p",
                        [App, Key, EnvVal, Def]),
                    DefCalc
            end
    end,
    case EnvVal of
        CalcVal ->
            CalcVal;
        _ ->
            _ = application:set_env(App, Key, CalcVal),
            CalcVal
    end.

-spec config() -> config() | {error, term()}.
%%
%% @doc Return the current effective Jobs Management configuration.
%%
config() ->
    gen_server:call(?JOBS_SVC_NAME, config).

-spec default_app() -> atom().
%%
%% @doc Returns the current or default application name.
%%
default_app() ->
    case application:get_application() of
        undefined ->
            riak_core;
        {ok, AppName} ->
            AppName
    end.

-spec release(Runner :: runner()) -> ok.
%% @private
%% @doc Release use of a Runner process.
%%
release(Runner) ->
    gen_server:cast(?JOBS_SVC_NAME, {release, Runner}).

-spec runner() -> runner() | {error, term()}.
%% @private
%% @doc Acquire use of a Runner process.
%%
runner() ->
    gen_server:call(?JOBS_SVC_NAME, runner).

-spec stats() -> [stat()] | {error, term()}.
%%
%% @doc Return statistics from the Jobs Management system.
%%
stats() ->
    gen_server:call(?JOBS_SVC_NAME, stats).

%% ===================================================================
%% Gen_server API
%% ===================================================================

-spec code_change(OldVsn :: term(), State :: state(), Extra :: term())
        -> {ok, state()}.
%% @private
%
% we don't care, just carry on
%
code_change(_, State, _) ->
    {ok, State}.

-spec handle_call(Msg :: term(), From :: {pid(), term()}, State :: state())
        -> {reply, term(), state()} | {stop, term(), term(), state()}.
%% @private
%
% config() -> config() | {'error', term()}.
%
handle_call(config, _, State) ->
    {reply, [
        {?JOB_SVC_IDLE_MIN, State#state.imin},
        {?JOB_SVC_IDLE_MAX, State#state.imax},
        {?JOB_SVC_RECYCLE,  State#state.recycle}
    ], State};
%
% runner() -> runner() | {'error', term()}.
%
handle_call(runner, _, #state{icnt = 0} = State) ->
    case create() of
        Runner when erlang:is_pid(Runner) ->
            {reply, Runner, check_pending(State)};
        {error, _} = Error ->
            {stop, Error, inc_stat(service_errors, State)}
    end;

handle_call(runner, _, #state{idle = IdleIn, icnt = ICnt} = State) ->
    {{value, #rrec{ref = Ref, pid = Runner}}, Idle} = queue:out(IdleIn),
    _ = erlang:demonitor(Ref, [flush]),
    {reply, Runner, check_pending(State#state{idle = Idle, icnt = (ICnt - 1)})};
%
% stats() -> [stat()] | {'error', term()}.
%
handle_call(stats, _, State) ->
    Status = if State#state.shutdown -> stopping; ?else -> active end,
    Result = [
        {status,    Status},
        {idle,      State#state.icnt},
        {maxidle,   State#state.imax},
        {minidle,   State#state.imin},
        {recycling, State#state.recycle}
        | ?StatsDict:to_list(State#state.stats) ],
    {reply, Result, State};
%
% unrecognized message
%
handle_call(Msg, {Who, _}, State) ->
    _ = lager:error(
        "~s received unhandled call from ~p: ~p", [?JOBS_SVC_NAME, Who, Msg]),
    {reply, {error, {badarg, Msg}}, inc_stat(unhandled, State)}.

-spec handle_cast(Msg :: term(), State :: state())
        -> {noreply, state()} | {stop, term(), state()}.
%% @private
%
% release(Runner :: runner()) -> 'ok'.
%
handle_cast({release, Runner}, State) when erlang:is_pid(Runner) ->
    % Use the Runner's private 'confirm' handler to ensure that this is,
    % in fact, a Runner process.
    Service = erlang:self(),
    Nonce   = erlang:phash2(os:timestamp()),
    Expect  = erlang:phash2({Nonce, ?job_run_ctl_token, Runner}),
    _ = erlang:send(Runner, {confirm, Service, Nonce}),
    receive
        {confirm, Nonce, Expect} ->
            if
                State#state.recycle ->
                    Ref = erlang:monitor(process, Runner),
                    Rec = #rrec{ref = Ref, pid = Runner},
                    {noreply, check_pending(State#state{
                        idle = queue:in(Rec, State#state.idle),
                        icnt = (State#state.icnt + 1) })};
                ?else ->
                    _ = riak_core_job_sup:stop_runner(Runner),
                    {noreply, State}
            end
    after
        ?CONFIRM_MSG_TIMEOUT ->
            _ = lager:warning(
                "~s received 'release' for unknown process ~p",
                [?JOBS_SVC_NAME, Runner]),
            {noreply, inc_stat({unknown_proc, ?LINE}, State)}
    end;
%
% internal 'pending' message
%
% State#state.pending MUST be 'true' at the time when we encounter a 'pending'
% message - if it's not the State is invalid.
%
handle_cast(pending, #state{pending = Flag} = State) when Flag /= true ->
    _ = lager:error("~s:~b: invalid state: ~p", [?JOBS_SVC_NAME, ?LINE, State]),
    {stop, invalid_state, State};

handle_cast(pending, State) ->
    pending(State#state{pending = false});
%
% configuration message
%
handle_cast(?job_svc_cfg_token,
        #state{imin = IMin, imax = IMax, recycle = RMode} = State) ->
    App     = default_app(),
    IdleMin = app_config(App, ?JOB_SVC_IDLE_MIN),
    IdleMax = app_config(App, ?JOB_SVC_IDLE_MAX),
    Recycle = app_config(App, ?JOB_SVC_RECYCLE),
    if
        IdleMin /= IMin orelse IdleMax /= IMax orelse Recycle /= RMode ->
            _ = lager:info(
                "Updating configuration from {~b, ~b, ~s} to {~b, ~b, ~s}",
                [IMin, IMax, RMode, IdleMin, IdleMax, Recycle]),
            {noreply, check_pending(State#state{
                imin = IdleMin, imax = IdleMax, recycle = Recycle})};
        ?else ->
            {noreply, State}
    end;
%
% unrecognized message
%
handle_cast(Msg, State) ->
    _ = lager:error("~s received unhandled cast: ~p", [?JOBS_SVC_NAME, Msg]),
    {noreply, inc_stat(unhandled, State)}.

-spec handle_info(Msg :: term(), State :: state())
        -> {noreply, state()} | {stop, term(), state()}.
%% @private
%
% An idle runner crashed or was killed.
% It's ok for this to be an inefficient operation, because it *really*
% shouldn't ever happen.
%
handle_info({'DOWN', Ref, _, Pid, Info}, #state{icnt = ICnt} = State) ->
    List = queue:to_list(State#state.idle),
    case lists:keytake(Ref, #rrec.ref, List) of
        {value, #rrec{pid = Pid}, Idle} ->
            _ = lager:warning(
                "~s received 'DOWN' message from idle runner ~p: ~p",
                [?JOBS_SVC_NAME, Pid, Info]),
            {noreply, inc_stat(crashed, check_pending(State#state{
                idle = queue:from_list(Idle), icnt = (ICnt - 1)}))};

        {value, #rrec{pid = Runner}, Idle} ->
            _ = lager:error("~s:~b: Ref/Runner/Pid mismatch: ~p ~p ~p",
                [?JOBS_SVC_NAME, ?LINE, Ref, Runner, Pid]),
            % Even though it's bad, it still needs to be removed from the
            % queue so terminate/2 doesn't have to wrestle with it.
            {stop, invalid_state, State#state{
                idle = queue:from_list(Idle), icnt = (ICnt - 1)}};

        false ->
            % With luck it was just a spurious message, though that's unlikely.
            _ = lager:error("~s received 'DOWN' message from "
            "unrecognized process ~p: ~p", [?JOBS_SVC_NAME, Pid, Info]),
            {noreply, inc_stat({unknown_proc, ?LINE}, State)}
    end;
%
% unrecognized message
%
handle_info(Msg, State) ->
    _ = lager:error("~s received unhandled info: ~p", [?JOBS_SVC_NAME, Msg]),
    {noreply, inc_stat(unhandled, State)}.

-spec init(?MODULE) -> {ok, state()} | {stop, {error, term()}}.
%% @private
%
% initialize from the application environment
%
init(?MODULE) ->
    App = default_app(),
    {ok, #state{
        imin = app_config(App, ?JOB_SVC_IDLE_MIN),
        imax = app_config(App, ?JOB_SVC_IDLE_MAX),
        recycle = app_config(App, ?JOB_SVC_RECYCLE)
    }}.

-spec start_link() -> {ok, pid()}.
%% @private
%
% start named service
%
start_link() ->
    gen_server:start_link({local, ?JOBS_SVC_NAME}, ?MODULE, ?MODULE, []).

-spec terminate(Why :: term(), State :: state()) -> ok.
%% @private
%
% No matter why we're terminating, de-monitor all of our idle runners and send
% each an appropriate exit message - they should all stop immediately.
%
terminate(invalid_state, State) ->
    _ = lager:error(
        "~s terminated due to invalid state: ~p", [?JOBS_SVC_NAME, State]),
    terminate(shutdown, State);

terminate(_, #state{icnt = 0}) ->
    ok;

terminate(Why, State) ->
    terminate(Why, cull_idle(State)).

%% ===================================================================
%% Internal
%% ===================================================================

-spec check_pending(State :: state()) -> state().
%
% Ensure that there's a 'pending' message in the inbox if there's background
% work to be done.
%
check_pending(#state{icnt = ICnt, imin = IMin, imax = IMax} = State)
        when ICnt >= IMin andalso IMax >= ICnt ->
    State;
check_pending(State) ->
    set_pending(State).

-spec create() -> runner() | {error, term()}.
%
% Creates a new Runner process.
%
create() ->
    case riak_core_job_sup:start_runner() of
        {ok, Runner} when erlang:is_pid(Runner) ->
            Runner;
        {error, What} = Error ->
            _ = lager:error(
                "~s: error creating runner: ~p", [?JOBS_SVC_NAME, What]),
            Error
    end.

-spec cull_idle(State :: state()) -> state().
%
% Removes and de-monitors the Runner at the head of the idle queue.
%
cull_idle(#state{icnt = 0} = State) ->
    State;
cull_idle(#state{idle = IdleIn, icnt = ICnt} = State) ->
    {{value, #rrec{ref = Ref, pid = Runner}}, Idle} = queue:out(IdleIn),
    _ = erlang:demonitor(Ref, [flush]),
    _ = riak_core_job_sup:stop_runner(Runner),
    inc_stat(culled, State#state{idle = Idle, icnt = (ICnt - 1)}).

-spec inc_stat(stat_key() | [stat_key()], state()) -> state()
        ;     (stat_key() | [stat_key()], stats()) -> stats().
%
% Increment one or more statistics counters.
%
inc_stat(Stat, #state{stats = Stats} = State) ->
    State#state{stats = inc_stat(Stat, Stats)};
inc_stat(Stat, Stats) ->
    ?StatsDict:update_counter(Stat, 1, Stats).
%%inc_stat(Stat, Stats) when not erlang:is_list(Stat) ->
%%    ?StatsDict:update_counter(Stat, 1, Stats);
%%inc_stat([Stat], Stats) ->
%%    inc_stat(Stat, Stats);
%%inc_stat([Stat | More], Stats) ->
%%    inc_stat(More, inc_stat(Stat, Stats));
%%inc_stat([], Stats) ->
%%    Stats.

-spec pending(State :: state())
        ->  {noreply, state()}
        |   {stop, shutdown | {error, term()}, state()}.
%
% Perform background tasks, one operation per invocation. If there are more
% operations to be done, ensure that there's a 'pending' message in the inbox
% on completion.
%
% Result is as specified for gen_server:handle_cast/2.
%
pending(#state{shutdown = true} = State) ->
    {stop, shutdown, State};

pending(#state{icnt = ICnt, imax = IMax} = State) when ICnt > IMax ->
    {noreply, check_pending(cull_idle(State))};

pending(#state{icnt = ICnt, imin = IMin} = State) when ICnt < IMin ->
    case create() of
        Runner when erlang:is_pid(Runner) ->
            Ref = erlang:monitor(process, Runner),
            Rec = #rrec{ref = Ref, pid = Runner},
            {noreply, check_pending(State#state{
                idle = queue:in(Rec, State#state.idle), icnt = (ICnt + 1) })};
        {error, _} = Error ->
            {stop, Error, inc_stat(service_errors, State)}
    end;

pending(State) ->
    {noreply, State}.

-spec resolve_config_val(App :: atom(), Val :: non_neg_integer() | cfg_mult())
        -> einval | non_neg_integer().
%
% Returns the computed and/or validated value of Val.
%
% Val may be either an integer or a multiplier tuple.
%
% Multipliers are handled as described in the riak_core_job_manager module
% documentation.
%
% If Val is neither a non-negative integer nor a valid multiplier tuple,
% `einval' is returned.
%
resolve_config_val(_App, Val) when ?is_non_neg_int(Val) ->
    Val;

resolve_config_val(App, {concur, Mlt}) when ?is_non_neg_int(Mlt) ->
    (app_config(App, ?JOB_SVC_CONCUR_LIMIT) * Mlt);

resolve_config_val(App, {cores, Mlt}) when ?is_non_neg_int(Mlt) ->
    case erlang:system_info(logical_processors) of
        Cores when ?is_non_neg_int(Cores) ->
            (Cores * Mlt);
        _ ->
            resolve_config_val(App, {scheds, Mlt})
    end;

resolve_config_val(_App, {scheds, Mlt}) when ?is_non_neg_int(Mlt) ->
    (erlang:system_info(schedulers) * Mlt);

resolve_config_val(_, _) ->
    einval.

-spec set_pending(State :: state()) -> state().
%
% Ensure that there's a 'pending' message in the inbox.
%
set_pending(#state{pending = false} = State) ->
    gen_server:cast(erlang:self(), pending),
    State#state{pending = true};
set_pending(State) ->
    State.
