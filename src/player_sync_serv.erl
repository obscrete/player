-module(player_sync_serv).
-export([connect/3]).
-export([start_link/5, stop/1]).

-include_lib("apptools/include/log.hrl").
-include_lib("apptools/include/serv.hrl").
-include("../include/player_buffer.hrl").
-include("../include/player_sync_serv.hrl").

%%-define(DSYNC(F,A), io:format((F),(A))).
-define(DSYNC(F,A), ok).
-define(FSYNC(F,A), io:format((F),(A))).

%% Debug: length([erlang:port_info(P)||P <- erlang:ports()]).

-record(state,
        {parent :: pid(),
         options :: #player_sync_serv_options{},
         listen_socket :: inet:socket(),
         acceptors :: [pid()],
	 nodis_serv_pid :: pid() | undefined,
         player_serv_pid = not_set :: pid() | not_set}).

%% Exported: connect

connect(PlayerServPid, NAddr, Options) ->
    Pid = proc_lib:spawn_link(
            fun() -> connect_now(PlayerServPid, NAddr, Options) end),
    {ok, Pid}.

connect_now(PlayerServPid, NAddr, #player_sync_serv_options{
				    sync_address = SyncAddress,
                                    %% ip_address = IpAddress,
                                    connect_timeout = ConnectTimeout,
                                    f = F} = Options) ->
    {_, SrcPort} = SyncAddress,
    {DstIP,DstPort} = NAddr,
    ?DSYNC("Connect: ~p naddr=~p\n", [SyncAddress, NAddr]),
    case gen_tcp:connect(DstIP, DstPort,
                         [{active, false},
			  {nodelay, true},
			  {port,SrcPort+1},
			  binary, {packet, 4}],
                         ConnectTimeout) of
        {ok, Socket} ->
	    %% register_simulator_endpoint(Socket, SyncAddress, Simulated),
            M = erlang:trunc(?PLAYER_BUFFER_MAX_SIZE * F),
            N = erlang:min(M, player_serv:buffer_size(PlayerServPid) * F),
            AdjustedN =
                if N > 0 andalso N < 1 ->
                        1;
                   true ->
                        erlang:trunc(N)
                end,
            case send_messages(PlayerServPid, Socket, AdjustedN, []) of
                ok ->
                    ?dbg_log({connect, send_messages, AdjustedN}),
                    case receive_messages(
                           PlayerServPid, Options, Socket, M, []) of
                        {ok, NewBufferIndices} ->
                            ?dbg_log({connect, receive_messages,
                                      length(NewBufferIndices)}),
                            gen_tcp:close(Socket);
                        {error, closed} ->
                            ok;
                        {error, Reason} ->
                            ok = gen_tcp:close(Socket),
                            ?error_log({connect, receive_message, Reason})
                    end;
                {error, closed} ->
                    %%?error_log({connect, send_messages, premature_socket_close}),
                    ok;
                {error, Reason} ->
                    ok = gen_tcp:close(Socket),
                    ?error_log({connect, send_messages, Reason})
            end;
        {error, eaddrinuse} ->
	    ok;
        {error, Reason} ->
	    ?FSYNC("Connect fail ~p: ~p naddr:~p\n",
		   [Reason, SyncAddress, NAddr]),
            ?error_log({connect, Reason})
    end.

%% Exported: start_link

start_link(Nym, {IpAddress, Port}, F, Keys, Simulated) ->
    ?spawn_server(
       fun(Parent) ->
               init(Parent, Nym, Port,
                    #player_sync_serv_options{simulated=Simulated,
					      ip_address = IpAddress,
                                              f = F,
                                              keys = Keys})
       end,
       fun initial_message_handler/1).

%% Exported: stop

stop(Pid) ->
    serv:call(Pid, stop).

%%
%% Server
%%

init(Parent, Nym, Port,
     #player_sync_serv_options{
        ip_address = IpAddress} = Options) ->
    Family = if tuple_size(IpAddress) =:= 4 -> [inet];
		tuple_size(IpAddress) =:= 8 -> [inet6];
		true -> []
	     end,
    LOptions = Family ++ [{active, false},
			  {ifaddr, IpAddress},
			  binary,
			  {packet, 4},
			  {reuseaddr, true}],
    {ok, ListenSocket} =
        gen_tcp:listen(Port, LOptions),
    self() ! accepted,
    ?daemon_log_tag_fmt(
       system, "Player sync server starting for ~s on ~s:~w",
       [Nym, inet:ntoa(IpAddress), Port]),
    {ok, #state{parent = Parent,
                options = Options,
                listen_socket = ListenSocket,
                acceptors = []}}.

initial_message_handler(State) ->
    receive
        {neighbour_workers, NeighbourWorkers} ->
            case supervisor_helper:get_selected_worker_pids(
		   [player_serv, nodis_serv], NeighbourWorkers) of
		[PlayerServPid, undefined] ->
		    NodisServPid = whereis(nodis_serv);
		[PlayerServPid, NodisServPid] ->
		    ok
	    end,
            {swap_message_handler, fun message_handler/1,
             State#state{player_serv_pid = PlayerServPid,
			 nodis_serv_pid = NodisServPid}}
    end.

message_handler(#state{parent = Parent,
                       options = Options,
                       listen_socket = ListenSocket,
                       acceptors = Acceptors,
                       player_serv_pid = PlayerServPid,
		       nodis_serv_pid = NodisServPid
		      } = State) ->
    receive
        {call, From, stop} ->
            {stop, From, ok};
        accepted ->
            Owner = self(),
            Pid =
                proc_lib:spawn_link(
                  fun() ->
                          acceptor(Owner, PlayerServPid, NodisServPid,
				   Options, ListenSocket)
                  end),
            {noreply, State#state{acceptors = [Pid|Acceptors]}};
        {system, From, Request} ->
            {system, From, Request};
        {'EXIT', PlayerServPid, Reason} ->
            exit(Reason);
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        {'EXIT', Pid, normal} ->
            case lists:member(Pid, Acceptors) of
                true ->
                    {noreply,
                     State#state{acceptors = lists:delete(Pid, Acceptors)}};
                false ->
                    ?error_log({not_an_acceptor, Pid}),
                    noreply
            end;
        UnknownMessage ->
            ?error_log({unknown_message, UnknownMessage}),
            noreply
    end.

acceptor(Owner, PlayerServPid, NodisServPid, Options, ListenSocket) ->
    %% check failure reason of ListenSocket (reload, interface error etc)
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    {ok, SyncAddress} = inet:sockname(Socket),
    %% Node we may fail to lookup correct fake address if
    %% connecting side is not fast enough to register socket!
    {ok, {IP,SrcPort}} = inet:peername(Socket),
    NAddr = {IP,SrcPort-1},  %% this MUSt be the nodis address
    case nodis:get_state(NodisServPid, NAddr) of
	up when SyncAddress < NAddr ->
	    Owner ! accepted,
	    ?DSYNC("Accept: ~p, naddr=~p\n", [SyncAddress,NAddr]),
	    do_receive_messages(PlayerServPid, Options, Socket);
	_State -> %% SyncAddress > NAddr | State != up
	    gen_tcp:close(Socket),
	    ?DSYNC("Reject: ~p, naddr=~p:~s\n", [SyncAddress, NAddr, _State]),
	    acceptor(Owner, PlayerServPid, NodisServPid, Options, ListenSocket)
    end.

do_receive_messages(PlayerServPid,
		    #player_sync_serv_options{f = F} = Options,
		    Socket) ->
    M = erlang:trunc(?PLAYER_BUFFER_MAX_SIZE * F),
    N = erlang:min(M, player_serv:buffer_size(PlayerServPid) * F),
    AdjustedN =
        if N > 0 andalso N < 1 ->
                1;
           true ->
                erlang:trunc(N)
        end,
    case receive_messages(PlayerServPid, Options, Socket, M, []) of
        {ok, NewBufferIndices} ->
            ?dbg_log({acceptor, receive_messages, length(NewBufferIndices)}),
            case send_messages(PlayerServPid, Socket, AdjustedN,
                               NewBufferIndices) of
                ok ->
                    ?dbg_log({acceptor, send_messages, AdjustedN}),
                    gen_tcp:close(Socket);
                {error, closed} ->
                    ok;
                {error, Reason} ->
                    ?error_log({acceptor, send_messages, Reason}),
                    gen_tcp:close(Socket)
            end;
        {error, closed} ->
            %%?error_log({acceptor, premature_socket_close}),
            ok;
        {error, Reason} ->
            ?error_log({acceptor, receive_messages, Reason}),
            gen_tcp:close(Socket)
    end.


%% create a map from socket {IP,Port} to SyncAddress, this
%% is to allow simulator to find the connecting instance!
%% register_simulator_endpoint(Socket, SyncAddress, true) ->
%%    {ok,{IP,Port}} = inet:sockname(Socket),
%%    ets:insert(endpoint_reg, {{IP,Port}, SyncAddress}).

%% lookup_simulator_endpoint(Socket) ->
%%     case inet:peername(Socket) of
%% 	{ok,IPPort} ->
%% 	    %% add a tiny delay, to allow connecting side to
%% 	    %% register its enpoint so we map to the nodis instance!
%% 	    timer:sleep(10),
%% 	    case ets:lookup(endpoint_reg, IPPort) of
%% 		[{_,Sim_IPPort}] -> {ok,Sim_IPPort};
%% 		_ -> {ok,IPPort}
%% 	    end;
%% 	Error ->
%% 	    Error
%%     end.

%% nodis_peer_address(Socket, false) ->
%%     inet:peername(Socket);
%% nodis_peer_address(Socket, true) ->
%%     lookup_simulator_endpoint(Socket).

%% nodis_address({{A,B,C,D},Port}, true) ->
%%     {A,B,C,D,Port};
%%nodis_address({{A,B,C,D,E,F,G,H}, Port}, true) ->
%%    {A,B,C,D,E,F,G,H,Port};
%%nodis_address({Addr,_Port}, false) ->
%%    Addr.

%%
%% Send and receive messages
%%

send_messages(_PlayerServPid, Socket, 0, _SkipBufferIndices) ->
    gen_tcp:send(Socket, <<"\r\n">>);
send_messages(PlayerServPid, Socket, N, SkipBufferIndices) ->
    case player_serv:buffer_pop(PlayerServPid, SkipBufferIndices) of
        {ok, <<MessageId:64/unsigned-integer, EncryptedData/binary>>} ->
            Message = <<MessageId:64/unsigned-integer, EncryptedData/binary>>,
            case gen_tcp:send(Socket, Message) of
                ok ->
                    send_messages(PlayerServPid, Socket, N - 1,
                                  SkipBufferIndices);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, no_more_messages} ->
            gen_tcp:send(Socket, <<"\r\n">>)
    end.

receive_messages(_PlayerServPid, _Options, _Socket, 0, NewBufferIndices) ->
    {ok, NewBufferIndices};
receive_messages(PlayerServPid, #player_sync_serv_options{
                                   recv_timeout = RecvTimeout,
                                   keys = {_Public_key, SecretKey}} = Options,
                 Socket, M, NewBufferIndices) ->
    case gen_tcp:recv(Socket, 0, RecvTimeout) of
        {ok, <<"\r\n">>} ->
            {ok, NewBufferIndices};
        {ok, <<MessageId:64/unsigned-integer,
               EncryptedData/binary>> = Message} ->
            case elgamal:udecrypt(EncryptedData, SecretKey) of
                mismatch ->
                    BufferIndex =
                        player_serv:buffer_push(PlayerServPid, Message),
                    receive_messages(PlayerServPid, Options, Socket, M - 1,
                                     [BufferIndex|NewBufferIndices]);
                {SenderNym, Signature, DecryptedData} ->
                    ok = player_serv:got_message(PlayerServPid, MessageId,
                                                 SenderNym, Signature,
                                                 DecryptedData),
                    receive_messages(PlayerServPid, Options, Socket, M - 1,
                                     NewBufferIndices)
            end;
        {ok, InvalidMessage} ->
            ?error_log({invalid_message, InvalidMessage}),
            receive_messages(PlayerServPid, Options, Socket, M - 1,
                             NewBufferIndices);
        {error, Reason} ->
            {error, Reason}
    end.
