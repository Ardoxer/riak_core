%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016-2017 Basho Technologies, Inc.
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

-ifndef(riak_core_job_internal_included).
-define(riak_core_job_internal_included, true).

%% Macros shared among the processes in the async job management modules.
%% There is little, if anything, here that should be used outside those modules!

-ifdef(PULSE).
-compile([
    export_all,
    {parse_transform,   pulse_instrument},
    {pulse_replace_module, [
        {gen_server,    pulse_gen_server},
        {supervisor,    pulse_supervisor}
    ]}
]).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("riak_core_vnode.hrl").
-include("riak_core_job.hrl").

-ifdef(NO_NAMESPACED_TYPES).
-define(dict_t(K,V),    dict()).
-define(queue_t(T),     queue()).
-else.
-define(dict_t(K,V),    dict:dict(K, V)).
-define(queue_t(T),     queue:queue(T)).
-endif.
-ifdef(NO_ORDDICT_2).
-define(orddict_t(K,V), orddict:orddict()).
-else.
-define(orddict_t(K,V), orddict:orddict(K, V)).
-endif.

-ifdef(EDOC).
-define(opaque, -opaque).
-else.
-define(opaque, -type).
-endif.

-define(JOBS_MGR_NAME,  riak_core_job_manager).
-define(JOBS_SVC_NAME,  riak_core_job_service).
-define(WORK_SUP_NAME,  riak_core_job_sup).

%% Shutdown timeouts should always be in ascending order as listed here.
-define(WORK_RUN_SHUTDOWN_TIMEOUT,  15000).
-define(JOBS_SUP_SHUTDOWN_TIMEOUT,  (?WORK_RUN_SHUTDOWN_TIMEOUT + 1500)).
-define(JOBS_SVC_SHUTDOWN_TIMEOUT,  (?JOBS_SUP_SHUTDOWN_TIMEOUT + 1500)).
-define(JOBS_MGR_SHUTDOWN_TIMEOUT,  (?JOBS_SVC_SHUTDOWN_TIMEOUT + 1500)).

%% I don't dare expose this globally, but in the job management stuff allow
%% something resembling sane if/else syntax.
-define(else,   'true').

%% This is just handy to have around because it's used a lot.
-define(is_non_neg_int(Term),   (erlang:is_integer(Term) andalso Term >= 0)).

%% Specific terms that get mapped between the worker pool facade and the new
%% API services.
%% When we're sure they're stable, it may be worth moving (some of) these to
%% riak_core_job.hrl.
-define(JOB_ERR_CANCELED,       canceled).
-define(JOB_ERR_CRASHED,        crashed).
-define(JOB_ERR_KILLED,         killed).
-define(JOB_ERR_REJECTED,       job_rejected).
-define(JOB_ERR_QUEUE_OVERFLOW, job_queue_full).
-define(JOB_ERR_SHUTTING_DOWN,  service_shutdown).

-define(UNMATCHED_ARGS(Args),
    erlang:error({unmatched, {?MODULE, ?LINE}, Args})).

% Internal magic token - stay away!
% This isn't intended to offer any security, it's mainly to avoid mistakes.
% There may be value in replacing this with some dynamic token at some point
% to enforce the ownership relationship ... or not.
-define(job_run_ctl_token,      '$control$19276$').

-endif. % riak_core_job_internal_included
