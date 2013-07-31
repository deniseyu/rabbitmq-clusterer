-module(test).

-export([test/0]).

-include("rabbit_clusterer.hrl").

-record(test, { seed,
                program,
                cluster_state
              }).
-record(cluster, { nodes_state,
                   config
                 }).

-record(node_state, { config,
                      running }).

interpret({seq, []}, State) ->
    State;
interpret({seq, [H|T]}, State) ->
    interpret({seq, T}, interpret(H, State));
interpret({par, []}, State) ->
    State;
interpret({par, P}, State) ->
    Ref = make_ref(),
    Self = self(),
    Fun = fun (Result) -> Self ! {Ref, self(), Result}, ok end,
    PidTasks =
        orddict:from_list(
          [{spawn(fun () -> Fun(interpret(T, State)) end), T} || T <- P]),
    merge_results(gather(PidTasks, Ref), State);
interpret({merge_results, Task, TaskState}, State) ->
    %% todo
    State;
interpret({exec, Fun}, State) ->
    Fun(State).

gather(PidTasks, Ref) ->
    MRefs = [monitor(process, Pid) || Pid <- orddict:fetch_keys(PidTasks)],
    Results = gather(PidTasks, Ref, orddict:new()),
    [demonitor(MRef, [flush]) || MRef <- MRefs],
    Results.

gather(PidTasks, Ref, Results) ->
    case orddict:size(PidTasks) of
        0 -> Results;
        _ -> receive
                 {Ref, Pid, Result} ->
                     gather(orddict:erase(Pid, PidTasks), Ref,
                            orddict:store(orddict:fetch(Pid, PidTasks),
                                          Result, Results));
                 {'DOWN', _MRef, process, Pid, _Info} ->
                     gather(orddict:erase(Pid, PidTasks), Ref,
                            orddict:update(orddict:fetch(Pid, PidTasks),
                                           fun id/1, failed, Results))
             end
    end.

merge_results(TaskResults, State) ->
    interpret(
      {seq, [{merge, T, R} || {T, R} <- orddict:to_list(TaskResults)]}, State).

generate(Seed) ->
    Test = #test { seed          = Seed,
                   program       = [],
                   cluster_state =
                       #cluster { nodes_state = [],
                                  config =
                                      #config { nodes            = [],
                                                shutdown_timeout = infinity,
                                                gospel           = reset,
                                                version          = 0 }
                                }
                 },
    Test1 = generate_program(Test),
    Test1 #test { seed = Seed }.

generate_program(Test = #test { program = Prog, seed = 0 }) ->
    Test #test { program = lists:reverse(Prog) };
generate_program(Test = #test { program       = Prog,
                                cluster_state = CS,
                                seed          = Seed }) ->
    {{Instr, CS1}, Seed1} = choose_one(
                              Seed,
                              lists:append(
                                [change_shutdown_timeout_instructions(CS),
                                 change_gospel_instructions(CS),
                                 add_node_to_cluster_instructions(CS),
                                 remove_node_from_cluster_instructions(CS),
                                 start_node_instructions(CS),
                                 stop_node_instructions(CS),
                                 delete_node_instructions(CS),
                                 await_termination_instructions(CS),
                                 reset_node_instructions(CS)])),
    generate_program(Test #test { program       = [Instr | Prog],
                                  seed          = Seed1,
                                  cluster_state = CS1 }).

choose_one(N, List) ->
    Len = length(List),
    {lists:nth(1 + (N rem Len), List), N div Len}.

change_shutdown_timeout_instructions(CS = #cluster { config = Config = #config { shutdown_timeout = X }}) ->
    InterestingValues = [infinity, 0, 1, 2, 10, 30],
    [{{change_shutdown_timeout, V},
      CS #cluster { config = Config #config { shutdown_timeout = V }}}
     || V <- InterestingValues, V =/= X ].

change_gospel_instructions(CS = #cluster { config = Config = #config { gospel = X, nodes = Nodes }}) ->
    Values = [reset | [N || {N, _} <- Nodes]],
    [{{change_gospel, V},
      CS #cluster { config = Config #config { gospel = V }}}
     || V <- Values, V =/= X ].

add_node_to_cluster_instructions(CS = #cluster { nodes_state = NodesState,
                                                config = Config = #config { nodes = ConfigNodes }}) ->
    NewNode = generate_node(orddict:fetch_keys(NodesState)),
    Nodes = [NewNode | [N || {N, _NodeState} <- NodesState, not orddict:is_key(N, ConfigNodes)]],
    [{{add_node_to_cluster, N},
     CS #cluster { config = Config #config { nodes = [{N, disc} | ConfigNodes] } }} || N <- Nodes].

remove_node_from_cluster_instructions(CS = #cluster { config = Config = #config { nodes = ConfigNodes }}) ->
    [{{remove_node_from_cluster, N},
      CS #cluster { config = Config #config { nodes = orddict:erase(N, ConfigNodes) } }}
     || {N, _} <- ConfigNodes].

start_node_instructions(CS = #cluster { nodes_state = NodesState, config = Config }) ->
    NewNode = generate_node(orddict:fetch_keys(NodesState)),
    Nodes = [{NewNode, #node_state { running = false,
                                     config  = default }}
             | [{N, NS} || {N, NS = #node_state { running = false }} <- NodesState]],
    Update = fun (N, NS = #node_state { config = ConfigOrig }, ApplyConfig) ->
                     NewConfig = #config { nodes = ClusterNodes, shutdown_timeout = T } =
                         case ApplyConfig of
                             true  -> Config;
                             false -> ConfigOrig
                         end,
                     NS #node_state { config = NewConfig,
                                      running = case orddict:is_key(N, ClusterNodes) of
                                                    true  -> true;
                                                    false -> {terminating, T}
                                                end }
             end,
    %% TODO: if ApplyConfig then that will spread via N. Need to track.
    [{{start_node, N, ApplyConfig},
      CS #cluster { nodes_state = orddict:store(N, Update(N, NS, ApplyConfig), NodesState) }
     } || {N, NS} <- Nodes, ApplyConfig <- [true, false]].

stop_node_instructions(CS = #cluster { nodes_state = NodesState }) ->
    Stops = [{{stop_node, N}, N, NS #nodes_state { running = false }}
             || {N, NS = #node_state { running = R }} <- NodesState, R =/= false ],
    case Stops of
        [] ->
            [];
        [{Instr, N, NS}] ->
            [{Instr, CS #cluster { nodes_state = orddict:store(N, NS, NodesState) }}];
        [{AI,A,ANS},{BI,B,BNS}|Ts] -> [A, {par, [A, B]}, {par, Stops}]
    end.

delete_node_instructions(CS = #cluster { nodes_state = NodesState }) ->
    [{{delete_node, N},
      CS #cluster { nodes_state = orddict:erase(N, NodesState) }
     } || {N, #node_state { running = false }} <- NodesState ].

await_termination_instructions(CS = #cluster { nodes_state = NodesState }) ->
    [{{await_termination, N, T},
      CS #cluster { nodes_state =
                        orddict:store(N, NS #node_state { running = false }, NodesState) }
     } || {N, NS = #node_state { running = {terminating, T} }} <- NodesState, T =/= infinity ].
        
reset_node_instructions(CS = #cluster { nodes_state = NodesState,
                                        config = Config = #config { nodes = ConfigNodes } }) ->
    FindConfig = fun (N) ->
                         case orddict:is_key(N, ConfigNodes) of
                             true  -> Config;
                             false -> default
                         end
                 end,
    [{{reset_node, N},
      CS #cluster { nodes_state = orddict:store(
                                    N, NS #node_state { config = FindConfig(N) }, NodesState) }
     } || {N, NS = #node_state { config = C, running = false }} <- NodesState, C =/= default].

id(X) -> X.

test() ->
    case node() of
        'nonode@nohost' ->
            {error, must_be_distributed_node};
        _ ->
            ok
    end.
