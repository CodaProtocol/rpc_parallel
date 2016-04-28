open Core.Std
open Async.Std

module Worker_type_id = Unique_id.Int ()
module Worker_id      = Unique_id.Int ()

(* All processes start a "master" rpc server. This is a server that has two
   implementations:

   (1) Register - Spawned workers say hello to the spawner
   (2) Handle_exn - Spawned workers send exceptions to the spawner

   Processes can also start "worker" rpc servers (in process using [serve] or out of
   process using [spawn]). A "worker" rpc server has all the user defined implementations
   as well as:

   (1) Init_worker_state - Spawner sends the worker init argument
   (2) Init_connection_state - Connector sends the connection state init argument
   (3) Shutdown, Close_server, Async_log, etc.

   The handshake protocol for spawning a worker:

   (Master) - SSH and start running executable
   (Worker) - Start server, send [Register_rpc] with its host and port
   (Master) - Connect to worker, send [Init_worker_state_rpc]
   (Worker) - Do initialization (ensure we have daemonized first)
   (Master) - Finally, return a [Worker.t] to the caller
*)

module Rpc_settings = struct
  type t =
    { max_message_size  : int option
    ; handshake_timeout : Time.Span.t option
    ; heartbeat_config  : Rpc.Connection.Heartbeat_config.t option
    } [@@deriving sexp, bin_io]

  let create ?max_message_size ?handshake_timeout ?heartbeat_config () =
    { max_message_size; handshake_timeout; heartbeat_config }
end

(* Functions that are implemented by all workers *)
module Shutdown_rpc = struct
  let rpc =
    Rpc.One_way.create
      ~name:"shutdown_rpc"
      ~version:0
      ~bin_msg:Unit.bin_t
end

module Close_server_rpc = struct
  let rpc =
    Rpc.One_way.create
      ~name:"close_server_rpc"
      ~version:0
      ~bin_msg:Unit.bin_t
end

module Async_log_rpc = struct
  let rpc =
    Rpc.Pipe_rpc.create
      ~name:"async_log_rpc"
      ~version:0
      ~bin_query:Unit.bin_t
      ~bin_response:Log.Message.Stable.V2.bin_t
      ~bin_error:Error.bin_t
      ()
end

module Function = struct
  module Rpc_id = Unique_id.Int ()

  module Function_piped = struct
    type ('worker, 'query, 'response) t = ('query, 'response, Error.t) Rpc.Pipe_rpc.t

    let make_impl ~monitor ~f protocol =
      Rpc.Pipe_rpc.implement protocol
        (fun ((_conn : Rpc.Connection.t), internal_conn_state) arg ->
           let { Utils.Internal_connection_state.conn_state; worker_state; _ } =
             Set_once.get_exn internal_conn_state in
           Utils.try_within ~monitor (fun () -> f ~worker_state ~conn_state arg))

    let make_proto ?name ~bin_input ~bin_output () =
      let name = match name with
        | None -> sprintf "rpc_parallel_piped_%s" (Rpc_id.to_string (Rpc_id.create ()))
        | Some n -> n
      in
      Rpc.Pipe_rpc.create
        ~name
        ~version:0
        ~bin_query:bin_input
        ~bin_response:bin_output
        ~bin_error:Error.bin_t
        ()
  end

  module Function_plain = struct
    type ('worker, 'query, 'response) t = ('query, 'response) Rpc.Rpc.t

    let make_impl ~monitor ~f protocol =
      Rpc.Rpc.implement protocol
        (fun ((_conn : Rpc.Connection.t), internal_conn_state) arg ->
           let { Utils.Internal_connection_state.conn_state; worker_state; _ } =
             Set_once.get_exn internal_conn_state in
           (* We want to raise any exceptions from [f arg] to the current monitor (handled
              by Rpc) so the caller can see it. Additional exceptions will be handled by the
              specified monitor *)
           Utils.try_within_exn ~monitor
             (fun () -> f ~worker_state ~conn_state arg))

    let make_proto ?name ~bin_input ~bin_output () =
      let name = match name with
        | None -> sprintf "rpc_parallel_plain_%s" (Rpc_id.to_string (Rpc_id.create ()))
        | Some n -> n
      in
      Rpc.Rpc.create
        ~name
        ~version:0
        ~bin_query:bin_input
        ~bin_response:bin_output
  end

  module Function_one_way = struct
    type ('worker, 'query) t = 'query Rpc.One_way.t

    let make_impl ~monitor ~f protocol =
      Rpc.One_way.implement protocol
        (fun ((_conn : Rpc.Connection.t), internal_conn_state) arg ->
           let { Utils.Internal_connection_state.conn_state; worker_state; _ } =
             Set_once.get_exn internal_conn_state in
           don't_wait_for
             (* Even though [f] returns [unit], we want to use [try_within_exn] so if it
                starts any background jobs we won't miss the exceptions *)
             (Utils.try_within_exn ~monitor (fun () ->
                f ~worker_state ~conn_state arg |> return)))

    let make_proto ?name ~bin_input () =
      let name = match name with
        | None -> sprintf "rpc_parallel_one_way_%s" (Rpc_id.to_string (Rpc_id.create ()))
        | Some n -> n
      in
      Rpc.One_way.create
        ~name
        ~version:0
        ~bin_msg:bin_input
  end

  type ('worker, 'query, 'response) t =
    | Plain of ('worker, 'query, 'response) Function_plain.t
    | Piped
      :  ('worker, 'query, 'response) Function_piped.t
         *  ('r, 'response Pipe.Reader.t) Type_equal.t
      -> ('worker, 'query, 'r) t
    | One_way
      : ('worker, 'query) Function_one_way.t
      -> ('worker, 'query, unit) t

  let create_rpc ~monitor ?name ~f ~bin_input ~bin_output () =
    let proto = Function_plain.make_proto ?name ~bin_input ~bin_output () in
    let impl = Function_plain.make_impl ~monitor ~f proto in
    Plain proto, impl

  let create_pipe ~monitor ?name ~f ~bin_input ~bin_output () =
    let proto = Function_piped.make_proto ?name ~bin_input ~bin_output () in
    let impl = Function_piped.make_impl ~monitor ~f proto in
    Piped (proto, Type_equal.T), impl

  let create_one_way ~monitor ?name ~f ~bin_input () =
    let proto = Function_one_way.make_proto ?name ~bin_input () in
    let impl = Function_one_way.make_impl ~monitor ~f proto in
    One_way proto, impl

  let of_async_rpc ~monitor ~f proto =
    let impl = Function_plain.make_impl ~monitor ~f proto in
    Plain proto, impl

  let of_async_pipe_rpc ~monitor ~f proto =
    let impl = Function_piped.make_impl ~monitor ~f proto in
    Piped (proto, Type_equal.T), impl

  let of_async_one_way_rpc ~monitor ~f proto =
    let impl = Function_one_way.make_impl ~monitor ~f proto in
    One_way proto, impl

  let run (type response) (t : (_, _, response) t) connection ~arg
    : response Or_error.t Deferred.t =
    match t with
    | Plain proto -> Rpc.Rpc.dispatch proto connection arg
    | Piped (proto, Type_equal.T) ->
      Rpc.Pipe_rpc.dispatch proto connection arg
      >>| fun result ->
      Or_error.join result
      |> Or_error.map ~f:(fun (reader, _) -> reader)
    | One_way proto ->
      Rpc.One_way.dispatch proto connection arg |> return

  let shutdown     = One_way Shutdown_rpc.rpc
  let async_log    = Piped (Async_log_rpc.rpc, Type_equal.T)
  let close_server = One_way Close_server_rpc.rpc
end

module Heartbeater = struct
  type t = Host_and_port.t * Rpc_settings.t [@@deriving bin_io]

  let connect_and_wait_for_disconnect_exn (hp, rpc_settings) =
    let {Rpc_settings.handshake_timeout; heartbeat_config; _} = rpc_settings in
    Rpc.Connection.client
      ~host:(Host_and_port.host hp) ~port:(Host_and_port.port hp)
      ?handshake_timeout ?heartbeat_config ()
    >>| function
    | Error e -> raise e
    | Ok conn ->
      `Connected (Rpc.Connection.close_finished conn
                  >>| fun () ->
                  `Disconnected)
  ;;

  let connect_and_shutdown_on_disconnect_exn heartbeater =
    connect_and_wait_for_disconnect_exn heartbeater
    >>= fun (`Connected wait_for_disconnect) ->
    (wait_for_disconnect
     >>> fun `Disconnected ->
     Shutdown.shutdown 254);
    return `Connected
  ;;

  let if_spawned f = function
    | `Served -> return `No_parent
    | `Spawned t -> f t
end

(* Well this sucks that I need to copy all the module types into here. Factoring out
   everything into a parallel_intf.ml file didn't work because of dependencies with the
   module types and [Heartbeater]/[Function]. *)
module type Worker = sig

  type t [@@deriving bin_io, sexp_of]

  type worker = t

  type 'a functions

  val functions : t functions

  type worker_state_init_arg
  type connection_state_init_arg

  module Id : Identifiable
  val id : t -> Id.t

  val serve
    :  ?max_message_size  : int
    -> ?handshake_timeout : Time.Span.t
    -> ?heartbeat_config  : Rpc.Connection.Heartbeat_config.t
    -> worker_state_init_arg
    -> worker Deferred.t

  module Connection : sig
    type t

    val run
      :  t
      -> f : (worker, 'query, 'response) Function.t
      -> arg : 'query
      -> 'response Or_error.t Deferred.t

    val run_exn
      :  t
      -> f : (worker, 'query, 'response) Function.t
      -> arg : 'query
      -> 'response Deferred.t

    val client : worker -> connection_state_init_arg -> t Or_error.t Deferred.t
    val client_exn : worker -> connection_state_init_arg -> t Deferred.t

    val with_client
      :  worker
      -> connection_state_init_arg
      -> f: (t -> 'a Deferred.t)
      -> 'a Or_error.t Deferred.t

    val close : t -> unit Deferred.t
    val close_finished : t -> unit Deferred.t
    val is_closed : t -> bool
  end

  type 'a with_spawn_args
    =  ?where : Executable_location.t
    -> ?env : (string * string) list
    -> ?rpc_max_message_size  : int
    -> ?rpc_handshake_timeout : Time.Span.t
    -> ?rpc_heartbeat_config : Rpc.Connection.Heartbeat_config.t
    -> ?connection_timeout:Time.Span.t
    -> ?cd : string
    -> ?umask : int
    -> redirect_stdout : Fd_redirection.t
    -> redirect_stderr : Fd_redirection.t
    -> on_failure : (Error.t -> unit)
    -> worker_state_init_arg
    -> 'a

  val spawn : t Or_error.t Deferred.t with_spawn_args

  val spawn_exn : t Deferred.t with_spawn_args

  val spawn_and_connect
    : (connection_state_init_arg : connection_state_init_arg
       -> (t * Connection.t) Or_error.t Deferred.t) with_spawn_args

  val spawn_and_connect_exn
    : (connection_state_init_arg : connection_state_init_arg
       -> (t * Connection.t) Deferred.t) with_spawn_args
end

module type Functions = sig
  type worker

  type worker_state_init_arg
  type worker_state

  type connection_state_init_arg
  type connection_state

  type 'worker functions
  val functions : worker functions

  val init_worker_state
    :  parent_heartbeater : [ `Spawned of Heartbeater.t | `Served ]
    -> worker_state_init_arg
    -> worker_state Deferred.t

  val init_connection_state
    :  connection   : Rpc.Connection.t
    -> worker_state : worker_state
    -> connection_state_init_arg
    -> connection_state Deferred.t
end

module type Creator = sig
  type worker

  type worker_state
  type worker_state_init_arg
  type connection_state
  type connection_state_init_arg

  val create_rpc
    :  ?name : string
    -> f
       : (worker_state : worker_state
          -> conn_state : connection_state
          -> 'query
          -> 'response Deferred.t)
    -> bin_input : 'query Bin_prot.Type_class.t
    -> bin_output : 'response Bin_prot.Type_class.t
    -> unit
    -> (worker, 'query, 'response) Function.t

  val create_pipe
    :  ?name : string
    -> f
       : (worker_state  : worker_state
          -> conn_state : connection_state
          -> 'query
          -> 'response Pipe.Reader.t Deferred.t)
    -> bin_input : 'query Bin_prot.Type_class.t
    -> bin_output : 'response Bin_prot.Type_class.t
    -> unit
    -> (worker, 'query, 'response Pipe.Reader.t) Function.t

  val create_one_way
    :  ?name : string
    -> f
       : (worker_state  : worker_state
          -> conn_state : connection_state
          -> 'query
          ->  unit)
    -> bin_input : 'query Bin_prot.Type_class.t
    -> unit
    -> (worker, 'query, unit) Function.t

  val of_async_rpc
    :  f
       : (worker_state  : worker_state
          -> conn_state : connection_state
          -> 'query
          -> 'response Deferred.t)
    -> ('query, 'response) Rpc.Rpc.t
    -> (worker, 'query, 'response) Function.t

  val of_async_pipe_rpc
    :  f
       : (worker_state  : worker_state
          -> conn_state : connection_state
          -> 'query
          -> 'response Pipe.Reader.t Deferred.t)
    -> ('query, 'response, Error.t) Rpc.Pipe_rpc.t
    -> (worker, 'query, 'response Pipe.Reader.t) Function.t

  val of_async_one_way_rpc
    :  f
       : (worker_state  : worker_state
          -> conn_state : connection_state
          -> 'query
          -> unit)
    -> 'query Rpc.One_way.t
    -> (worker, 'query, unit) Function.t
end


module type Worker_spec = sig

  type 'worker functions

  module Worker_state : sig
    type t
    type init_arg [@@deriving bin_io]
  end

  module Connection_state : sig
    type t
    type init_arg [@@deriving bin_io]
  end

  module Functions
      (C : Creator
       with type worker_state = Worker_state.t
        and type worker_state_init_arg = Worker_state.init_arg
        and type connection_state = Connection_state.t
        and type connection_state_init_arg = Connection_state.init_arg)
    : Functions
      with type worker := C.worker
       and type 'a functions := 'a functions
       and type worker_state := Worker_state.t
       and type worker_state_init_arg := Worker_state.init_arg
       and type connection_state := Connection_state.t
       and type connection_state_init_arg := Connection_state.init_arg
end

(* Applications of the [Make()] functor have the side effect of populating
   an [implementations] list which subsequently adds an entry for that worker type id to
   the [worker_start_server_funcs]. *)
let worker_start_server_funcs = Worker_type_id.Table.create ~size:1 ()

(* All global state that is needed for a process to act as a master *)
type master_state =
  {(* The [Host_and_port.t] corresponding to one's own master Rpc server. *)
    my_server: Host_and_port.t Deferred.t lazy_t
  ; my_rpc_settings : Rpc_settings.t
  (* Used to facilitate timeout of connecting to a spawned worker *)
  ; pending: Host_and_port.t Ivar.t Worker_id.Table.t
  (* Arguments used when spawning a new worker *)
  ; worker_command_args : string list
  (* Callbacks for spawned worker exceptions along with the monitor that was current
     when [spawn] was called *)
  ; on_failures: ((Error.t -> unit) * Monitor.t) Worker_id.Table.t;
  }

(* All global state that is not specific to worker types is collected here *)
type worker_state =
  {(* Currently running worker servers in this process *)
    my_worker_servers: (Socket.Address.Inet.t, int) Tcp.Server.t Utils.Port.Table.t
  (* We make sure that if this process was spawned, it has daemonized before starting
     to run any user code. *)
  ; has_daemonized: unit Ivar.t }

type global_state =
  { as_master : master_state
  ; as_worker : worker_state }

(* Each running instance has the capability to work as a master. This state includes
   information needed to spawn new workers (my_server, my_rpc_settings, pending,
   worker_command_args), information to handle existing spawned workerd (on_failures), and
   information to handle worker servers that are running in process. *)
let global_state : global_state Set_once.t = Set_once.create ()

let get_state_exn () =
  match Set_once.get global_state with
  | None -> failwith "State should have been set already"
  | Some state -> state

let get_master_state_exn () = (get_state_exn ()).as_master
let get_worker_state_exn () = (get_state_exn ()).as_worker

let start_server ?max_message_size ?handshake_timeout ?heartbeat_config
      ~where_to_listen ~implementations ~initial_connection_state () =
  let implementations =
    Rpc.Implementations.create_exn ~implementations
      ~on_unknown_rpc:`Close_connection
  in
  Rpc.Connection.serve ~implementations ~initial_connection_state
    ?max_message_size ?handshake_timeout
    ?heartbeat_config ~where_to_listen ()

module Worker_config = struct
  type t =
    { worker_type           : Worker_type_id.t
    ; master                : Host_and_port.t * Rpc_settings.t
    ; rpc_settings          : Rpc_settings.t
    ; cd                    : string option
    ; umask                 : int option
    ; redirect_stdout       : Fd_redirection.t
    ; redirect_stderr       : Fd_redirection.t
    ; worker_command_args   : string list
    } [@@deriving sexp]
end

(* Rpcs implemented by master *)
module Register_rpc = struct
  type t = Worker_id.t * Host_and_port.t [@@deriving bin_io]

  type response = [`Shutdown | `Registered] [@@deriving bin_io]

  let rpc =
    Rpc.Rpc.create
      ~name:"register_worker_rpc"
      ~version:0
      ~bin_query:bin_t
      ~bin_response:bin_response

  let implementation =
    Rpc.Rpc.implement rpc (fun () (id, worker_hp) ->
      let global_state = get_master_state_exn () in
      match Hashtbl.find global_state.pending id with
      | None ->
        (* We already returned a failure to the [spawn_worker] caller *)
        return `Shutdown
      | Some ivar ->
        Ivar.fill ivar worker_hp;
        return `Registered)
end

module Handle_exn_rpc = struct
  type t = Worker_id.t * Error.t [@@deriving bin_io]

  let rpc =
    Rpc.Rpc.create
      ~name:"handle_worker_exn_rpc"
      ~version:0
      ~bin_query:bin_t
      ~bin_response:Unit.bin_t

  let implementation =
    Rpc.Rpc.implement rpc (fun () (id, error) ->
      let global_state = get_master_state_exn () in
      let on_failure, monitor = Hashtbl.find_exn global_state.on_failures id in
      (* We can't just run [on_failure error] because this will be caught by the Rpc
         monitor for this implementation. *)
      Scheduler.within ~monitor (fun () -> on_failure error);
      return ())
end

(* In order to spawn other workers, you must have an rpc server implementing
   [Register_rpc] and [Handle_exn_rpc] *)
let master_implementations = [Register_rpc.implementation; Handle_exn_rpc.implementation]

(* Setup some global state necessary to act as a master (i.e. spawn workers). This
   includes starting an Rpc server with [master_implementations] *)
let init_master_state ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
      ~worker_command_args =
  match Set_once.get global_state with
  | Some _state -> failwith "Master state must not be set up twice"
  | None ->
    let my_rpc_settings =
      Rpc_settings.create ?max_message_size:rpc_max_message_size
        ?handshake_timeout:rpc_handshake_timeout
        ?heartbeat_config:rpc_heartbeat_config ()
    in
    (* Use [size:1] so there is minimal top-level overhead linking with Rpc_parallel *)
    let pending = Worker_id.Table.create ~size:1 () in
    let on_failures = Worker_id.Table.create ~size:1 () in
    let my_worker_servers = Utils.Port.Table.create ~size:1 () in
    (* Lazily start our master rpc server *)
    let my_server = lazy begin
      start_server ?max_message_size:rpc_max_message_size
        ?handshake_timeout:rpc_handshake_timeout
        ?heartbeat_config:rpc_heartbeat_config
        ~where_to_listen:Tcp.on_port_chosen_by_os
        ~implementations:master_implementations
        ~initial_connection_state:(fun _ _ -> ()) ()
      >>| fun server ->
      Host_and_port.create ~host:(Unix.gethostname ())
        ~port: (Tcp.Server.listening_on server)
    end in
    let as_master =
      { my_server; my_rpc_settings; pending; worker_command_args; on_failures }
    in
    let as_worker =
      { my_worker_servers; has_daemonized = Ivar.create () }
    in
    Set_once.set_exn global_state {as_master; as_worker};

module Make (S : Worker_spec) = struct

  module Id = Uuid

  type t =
    { host_and_port : Host_and_port.t
    ; rpc_settings  : Rpc_settings.t
    ; id            : Worker_id.t
    }
  [@@deriving bin_io, sexp_of]

  type worker = t

  (* Internally we use [Worker_id.t] for all worker ids, but we want to expose an [Id]
     module that is specific to each worker. *)
  let id t = Worker_id.to_string t.id |> Id.of_string

  type worker_state =
    {
      (* A unique identifier for each application of the [Make] functor.
         Because we are running the same executable and this is supposed to run at the
         top level, the master and the workers agree on these ids *)
      type_  : Worker_type_id.t
    (* Persistent states associated with instances of this worker server *)
    ; states : S.Worker_state.t Utils.Port.Table.t
    (* Build up a list of all implementations for this worker type *)
    ; mutable implementations :
        (S.Worker_state.t, S.Connection_state.t) Utils.Internal_connection_state.t
          Rpc.Implementation.t list
    }

  let worker_state =
    { type_ = Worker_type_id.create ()
    ; states = Utils.Port.Table.create ~size:1 ()
    ; implementations = [] }

  (* Schedule all worker implementations in [Monitor.main] so no exceptions are lost.
     Async log automatically throws its exceptions to [Monitor.main] so we can't make
     our own local monitor. We detach [Monitor.main] and send exceptions back to the
     master. *)
  let monitor = Monitor.main

  (* Rpcs implemented by this worker type. The implementations for some must be below
     because User_functions is defined below (by supplying a [Creator] module) *)
  module Init_worker_state_rpc = struct
    type query =
      { master : Heartbeater.t    (* The heartbeater of the process that called [spawn] *)
      ; worker : Utils.Port.t    (* The process that got spawned *)
      ; arg    : S.Worker_state.init_arg
      } [@@deriving bin_io]

    let rpc =
      Rpc.Rpc.create
        ~name:(sprintf "worker_init_rpc_%s"
                 (Worker_type_id.to_string worker_state.type_))
        ~version:0
        ~bin_query
        ~bin_response:Unit.bin_t
  end

  module Init_connection_state_rpc = struct
    type query =
      { server : Utils.Port.t
      ; arg    : S.Connection_state.init_arg}
    [@@deriving bin_io]

    let rpc =
      Rpc.Rpc.create
        ~name:(sprintf "set_connection_state_rpc_%s"
                 (Worker_type_id.to_string worker_state.type_))
        ~version:0
        ~bin_query
        ~bin_response:Unit.bin_t
  end

  (* The workers fork. This causes the standard file descriptors to remain open once the
     process has exited. We close them here to avoid a file descriptor leak. *)
  let cleanup_standard_fds process =
    Process.wait process
    >>> fun (exit_or_signal : Unix.Exit_or_signal.t) ->
    (Reader.contents (Process.stderr process) >>> fun s ->
     Writer.write (Lazy.force Writer.stderr) s;
     don't_wait_for (Reader.close (Process.stderr process)));
    don't_wait_for (Writer.close (Process.stdin  process));
    don't_wait_for (Reader.close (Process.stdout process));
    match exit_or_signal with
    | Ok () -> ()
    | Error _ -> eprintf "Worker process %s\n"
                   (Unix.Exit_or_signal.to_string_hum exit_or_signal)

  let run_executable where ~env ~id ~worker_command_args ~input =
    Utils.create_worker_env ~extra:env ~id |> return
    >>=? fun env ->
    match where with
    | Executable_location.Local ->
      Utils.our_binary ()
      >>= fun binary ->
      Process.create ~prog:binary ~args:worker_command_args ~env:(`Extend env) ()
      >>|? fun p ->
      (* It is important that we start waiting for the child process here. The
         worker it forks daemonizes, thus this process ends. This will happen before
         the worker process quits or closes his RPC connection. If we only [wait]
         once the RPC connection is closed, we will have zombie processes hanging
         around until then. *)
      cleanup_standard_fds p;
      Writer.write_sexp (Process.stdin p) input
    | Executable_location.Remote exec ->
      Remote_executable.run exec ~env ~args:worker_command_args
      >>|? fun p ->
      cleanup_standard_fds p;
      Writer.write_sexp (Process.stdin p) input

  module Function_creator = struct
    type nonrec worker = worker

    type connection_state_init_arg = S.Connection_state.init_arg
    type connection_state = S.Connection_state.t
    type worker_state_init_arg = S.Worker_state.init_arg
    type worker_state = S.Worker_state.t

    let with_add_impl f =
      let func, impl = f () in
      worker_state.implementations <-
        impl::worker_state.implementations;
      func

    let create_rpc ?name ~f ~bin_input ~bin_output () =
      with_add_impl (fun () ->
        Function.create_rpc ~monitor ?name ~f
          ~bin_input ~bin_output ())

    let create_pipe ?name ~f ~bin_input ~bin_output () =
      with_add_impl (fun () ->
        Function.create_pipe ~monitor ?name ~f
          ~bin_input ~bin_output ())

    let create_one_way ?name ~f ~bin_input () =
      with_add_impl (fun () ->
        Function.create_one_way ~monitor ?name ~f
          ~bin_input ())

    let of_async_rpc ~f proto =
      with_add_impl (fun () ->
        Function.of_async_rpc ~monitor ~f proto)

    let of_async_pipe_rpc ~f proto =
      with_add_impl (fun () ->
        Function.of_async_pipe_rpc ~monitor ~f proto)

    let of_async_one_way_rpc ~f proto =
      with_add_impl (fun () ->
        Function.of_async_one_way_rpc ~monitor ~f proto)
  end

  module User_functions = S.Functions(Function_creator)

  let functions = User_functions.functions

  let serve ?max_message_size ?handshake_timeout ?heartbeat_config
        worker_state_init_arg =
    match Hashtbl.find worker_start_server_funcs worker_state.type_ with
    | None ->
      failwith
        "Worker could not find RPC implementations. Make sure the \
         Parallel.Make () functor is applied in the worker. \
         It is suggested to make this toplevel."
    | Some start_server ->
      start_server ?max_message_size ?handshake_timeout ?heartbeat_config
        ~where_to_listen:Tcp.on_port_chosen_by_os ()
      >>= fun server ->
      let host = Unix.gethostname () in
      let port = Tcp.Server.listening_on server in
      let global_state = get_worker_state_exn () in
      Hashtbl.add_exn global_state.my_worker_servers ~key:port ~data:server;
      User_functions.init_worker_state ~parent_heartbeater:`Served worker_state_init_arg
      >>| fun state ->
      Hashtbl.add_exn worker_state.states ~key:port ~data:state;
      let rpc_settings =
        Rpc_settings.create ?max_message_size ?handshake_timeout
          ?heartbeat_config ()
      in
      { host_and_port = Host_and_port.create ~host ~port
      ; rpc_settings
      ; id = Worker_id.create () }

  module Connection = struct
    type t = Rpc.Connection.t

    let close t        = Rpc.Connection.close t
    let close_finished = Rpc.Connection.close_finished
    let is_closed      = Rpc.Connection.is_closed

    let client { host_and_port; rpc_settings; id = _ } init_arg =
      let {Rpc_settings.max_message_size; handshake_timeout; heartbeat_config} =
        rpc_settings in
      Rpc.Connection.client
        ?max_message_size
        ?handshake_timeout
        ?heartbeat_config
        ~host:(Host_and_port.host host_and_port)
        ~port:(Host_and_port.port host_and_port)
        ()
      >>= function
      | Error exn -> return (Error (Error.of_exn exn))
      | Ok conn ->
        Rpc.Rpc.dispatch Init_connection_state_rpc.rpc conn
          { server = Host_and_port.port host_and_port; arg = init_arg }
        >>|? Fn.const conn

    let client_exn worker init_arg = client worker init_arg >>| Or_error.ok_exn

    let with_client worker init_arg ~f =
      client worker init_arg
      >>=? fun conn ->
      Monitor.try_with (fun () -> f conn)
      >>= fun result ->
      close conn
      >>| fun () ->
      Result.map_error result ~f:(fun exn -> Error.of_exn exn)

    let run t ~f ~arg = Function.run f t ~arg
    let run_exn t ~f ~arg = run t ~f ~arg >>| Or_error.ok_exn
  end

  type 'a with_spawn_args
    =  ?where : Executable_location.t
    -> ?env : (string * string) list
    -> ?rpc_max_message_size  : int
    -> ?rpc_handshake_timeout : Time.Span.t
    -> ?rpc_heartbeat_config : Rpc.Connection.Heartbeat_config.t
    -> ?connection_timeout:Time.Span.t
    -> ?cd : string  (** default / *)
    -> ?umask : int  (** defaults to use existing umask *)
    -> redirect_stdout : Fd_redirection.t
    -> redirect_stderr : Fd_redirection.t
    -> on_failure : (Error.t -> unit)
    -> S.Worker_state.init_arg
    -> 'a

  let spawn
        ?(where=Executable_location.Local) ?(env=[])
        ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
        ?(connection_timeout=(sec 10.)) ?cd ?umask ~redirect_stdout ~redirect_stderr
        ~on_failure worker_state_init_arg =
    begin match Set_once.get global_state with
    | None ->
      Deferred.Or_error.error_string
        "You must initialize this process to run as a master before calling \
         [spawn]. Either use a top-level [start_app] call or use the [Expert] module."
    | Some global_state -> Deferred.Or_error.return global_state.as_master
    end
    >>=? fun global_state ->
    (* generate a unique identifier for this worker *)
    let id = Worker_id.create () in
    let host =
      match where with
      | Executable_location.Local -> "local"
      | Executable_location.Remote exec -> Remote_executable.host exec
    in
    Lazy.force global_state.my_server
    >>= fun master_server ->
    let rpc_settings =
      Rpc_settings.create ?max_message_size:rpc_max_message_size
        ?handshake_timeout:rpc_handshake_timeout
        ?heartbeat_config:rpc_heartbeat_config ()
    in
    let input =
      { Worker_config.
        worker_type = worker_state.type_
      ; master = master_server, global_state.my_rpc_settings
      ; rpc_settings
      ; cd
      ; umask
      ; redirect_stdout
      ; redirect_stderr
      ; worker_command_args = global_state.worker_command_args
      } |> Worker_config.sexp_of_t
    in
    let pending_ivar = Ivar.create () in
    Hashtbl.add_exn global_state.pending ~key:id ~data:pending_ivar;
    run_executable where ~env ~id:(Worker_id.to_string id)
      ~worker_command_args:global_state.worker_command_args ~input
    >>= function
    | Error _ as err ->
      Hashtbl.remove global_state.pending id;
      return err
    | Ok () ->
      (* We have successfully copied over the binary and got it running, now we ensure
         that we got a register from the worker *)
      Clock.with_timeout connection_timeout (Ivar.read pending_ivar)
      >>= function
      | `Timeout ->
        (* Worker didn't register in time *)
        Hashtbl.remove global_state.pending id;
        Deferred.Or_error.errorf "Timed out getting connection from %s process" host
      | `Result worker_host_and_port ->
        Hashtbl.remove global_state.pending id;
        (* Add the on_failure now, before the worker has daemonized or started running any
           user code. This way we are guaranteed any exceptions raised in the worker will
           not be lost *)
        Hashtbl.add_exn global_state.on_failures
          ~key:id ~data:(on_failure, Monitor.current ());
        Rpc.Connection.with_client
          ?max_message_size:rpc_max_message_size
          ?handshake_timeout:rpc_handshake_timeout
          ?heartbeat_config:rpc_heartbeat_config
          ~host:(Host_and_port.host worker_host_and_port)
          ~port:(Host_and_port.port worker_host_and_port) (fun conn ->
          Rpc.Rpc.dispatch Init_worker_state_rpc.rpc conn
            { Init_worker_state_rpc.
              master = master_server, global_state.my_rpc_settings;
              worker = Host_and_port.port worker_host_and_port;
              arg = worker_state_init_arg })
        >>| function
        | Error exn ->
          Hashtbl.remove global_state.on_failures id;
          Error (Error.of_exn exn)
        | Ok (Error e) ->
          Hashtbl.remove global_state.on_failures id;
          Error e
        | Ok (Ok ()) ->
          Ok
            { host_and_port = worker_host_and_port
            ; rpc_settings
            ; id }
  ;;

  let spawn_exn ?where ?env
        ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
        ?connection_timeout ?cd ?umask ~redirect_stdout ~redirect_stderr
        ~on_failure worker_state_init_arg =
    spawn ?where ?env
      ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
      ?connection_timeout ?cd ?umask ~redirect_stdout ~redirect_stderr
      ~on_failure worker_state_init_arg
    >>| Or_error.ok_exn

  let spawn_and_connect ?where ?env
        ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
        ?connection_timeout ?cd ?umask ~redirect_stdout ~redirect_stderr
        ~on_failure worker_state_init_arg ~connection_state_init_arg =
    spawn ?where ?env
      ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
      ?connection_timeout ?cd ?umask ~redirect_stdout ~redirect_stderr
      ~on_failure worker_state_init_arg
    >>=? fun worker ->
    Connection.client worker connection_state_init_arg
    >>| function
    | Error e ->
      Error e
    | Ok conn -> Ok (worker, conn)

  let spawn_and_connect_exn ?where ?env
        ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
        ?connection_timeout ?cd ?umask ~redirect_stdout ~redirect_stderr
        ~on_failure worker_state_init_arg ~connection_state_init_arg =
    spawn_and_connect ?where ~connection_state_init_arg ?env
      ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
      ?connection_timeout ?cd ?umask ~redirect_stdout ~redirect_stderr
      ~on_failure worker_state_init_arg
    >>| Or_error.ok_exn

  let init_worker_state_impl =
    Rpc.Rpc.implement Init_worker_state_rpc.rpc
      (fun _conn_state { Init_worker_state_rpc.master; worker; arg } ->
         (* Make sure we have daemonized before we start running any user code.*)
         let global_state = get_worker_state_exn () in
         Ivar.read global_state.has_daemonized
         >>= fun () ->
         Utils.try_within_exn ~monitor
           (fun () ->
              User_functions.init_worker_state
                ~parent_heartbeater:(`Spawned master) arg)
         >>| fun state ->
         Hashtbl.add_exn worker_state.states ~key:worker ~data:state)

  let init_connection_state_impl =
    Rpc.Rpc.implement Init_connection_state_rpc.rpc
      (fun (connection, internal_conn_state) { server; arg = init_arg } ->
         let worker_state = Hashtbl.find_exn worker_state.states server in
         Utils.try_within_exn ~monitor
           (fun () -> User_functions.init_connection_state ~connection ~worker_state init_arg)
         >>| fun conn_state ->
         Set_once.set_exn internal_conn_state
           { Utils.Internal_connection_state.server; conn_state;  worker_state })

  let shutdown_impl =
    Rpc.One_way.implement Shutdown_rpc.rpc
      (fun _conn_state () ->
         eprintf "Got shutdown rpc...Shutting down.\n";
         Shutdown.shutdown 0)

  let close_server_impl =
    Rpc.One_way.implement Close_server_rpc.rpc (fun (_conn, conn_state) () ->
      let {Utils.Internal_connection_state.server; _} =
        Set_once.get_exn conn_state in
      let global_state = get_worker_state_exn () in
      match Hashtbl.find global_state.my_worker_servers server with
      | None -> ()
      | Some tcp_server ->
        Tcp.Server.close tcp_server
        >>> fun () ->
        Hashtbl.remove global_state.my_worker_servers server;
        Hashtbl.remove worker_state.states server)

  let async_log_impl =
    Rpc.Pipe_rpc.implement Async_log_rpc.rpc (fun _conn_state () ->
      let r, w = Pipe.create () in
      let new_output = Log.Output.create (fun msgs ->
        Queue.iter msgs ~f:(fun msg -> Pipe.write_without_pushback w msg)
        |> return)
      in
      Log.Global.set_output (new_output::Log.Global.get_output ());
      (* Remove this new output upon the pipe closing. Must be careful to flush the log
         before closing the writer. *)
      upon (Pipe.closed w) (fun () ->
        let new_outputs =
          List.filter (Log.Global.get_output ()) ~f:(fun output ->
            not (phys_equal output new_output))
        in
        Log.Global.set_output new_outputs;
        upon (Log.Global.flushed ()) (fun () -> Pipe.close w));
      return (Ok r))

  let () =
    worker_state.implementations <-
      [ init_worker_state_impl
      ; init_connection_state_impl
      ; shutdown_impl
      ; close_server_impl
      ; async_log_impl ]
      @ worker_state.implementations;
    let start_server_func =
      start_server ~implementations:worker_state.implementations
        ~initial_connection_state:(fun _address connection ->
          connection, Set_once.create ())
    in
    Hashtbl.add_exn worker_start_server_funcs ~key:worker_state.type_
      ~data:start_server_func
end

(* Start an Rpc server based on the implementations defined in the [Make] functor
   for this worker type. Return a [Host_and_port.t] describing the server *)
let worker_main ~id ~(config : Worker_config.t) ~release_daemon =
  let master_host_and_port,
      {Rpc_settings.max_message_size; handshake_timeout; heartbeat_config} =
    config.master in
  let register my_host_and_port =
    Rpc.Connection.with_client
      ?max_message_size
      ?handshake_timeout
      ?heartbeat_config
      ~host:(Host_and_port.host master_host_and_port)
      ~port:(Host_and_port.port master_host_and_port) (fun conn ->
        Rpc.Rpc.dispatch Register_rpc.rpc conn (id, my_host_and_port))
    >>| function
    | Error exn -> failwiths "Worker failed to register" exn [%sexp_of: Exn.t]
    | Ok (Error e) -> failwiths "Worker failed to register" e [%sexp_of: Error.t]
    | Ok (Ok `Shutdown) -> failwith "Got [`Shutdown] on register"
    | Ok (Ok `Registered) -> ()
  in
  (* We want the following two things to occur:

     (1) Catch exceptions in workers and report them back to the master
     (2) Write the exceptions to stderr *)
  let setup_exception_handling () =
    Scheduler.within (fun () ->
      Monitor.detach_and_get_next_error Monitor.main
      >>> fun exn ->
      (* We must be careful that this code here doesn't raise *)
      Rpc.Connection.with_client
        ?max_message_size
        ?handshake_timeout
        ?heartbeat_config
        ~host:(Host_and_port.host master_host_and_port)
        ~port:(Host_and_port.port master_host_and_port) (fun conn ->
          Rpc.Rpc.dispatch Handle_exn_rpc.rpc conn (id, Error.of_exn exn))
      >>> fun _ ->
      eprintf !"%{sexp:Exn.t}\n" exn;
      eprintf "Shutting down.\n";
      Shutdown.shutdown 254)
  in
  match Hashtbl.find worker_start_server_funcs config.worker_type with
  | None ->
    failwith
      "Worker could not find RPC implementations. Make sure the Parallel.Make () \
       functor is applied in the worker. It is suggested to make this toplevel."
  | Some start_server ->
    start_server
      ?max_message_size:config.rpc_settings.Rpc_settings.max_message_size
      ?handshake_timeout:config.rpc_settings.Rpc_settings.handshake_timeout
      ?heartbeat_config:config.rpc_settings.Rpc_settings.heartbeat_config
      ~where_to_listen:Tcp.on_port_chosen_by_os
      ()
    >>> fun server ->
    let host = Unix.gethostname () in
    let port = Tcp.Server.listening_on server in
    let global_state = get_worker_state_exn () in
    Hashtbl.add_exn global_state.my_worker_servers ~key:port ~data:server;
    register (Host_and_port.create ~host ~port)
    >>> fun () ->
    (* Careful to setup exception handling before we call [release_daemon] because
       [release_daemon] can fail (e.g. can't redirect stdout/stderr). *)
    setup_exception_handling ();
    release_daemon ();
    Ivar.fill global_state.has_daemonized ()

module Expert = struct
  let run_as_worker_exn () =
    match Utils.whoami () with
    | `Master ->
      failwith "Could not find worker environment. Workers must be spawned by masters"
    | `Worker id_str ->
      Utils.clear_env ();
      let config = Sexp.input_sexp In_channel.stdin |> Worker_config.t_of_sexp in
      let {Rpc_settings.max_message_size; handshake_timeout; heartbeat_config} =
        config.rpc_settings in
      init_master_state
        ?rpc_max_message_size:max_message_size
        ?rpc_handshake_timeout:handshake_timeout
        ?rpc_heartbeat_config:heartbeat_config
        ~worker_command_args:config.worker_command_args;
      let id = Worker_id.of_string id_str in
      (* The worker is started via SSH. We want to go to the background so we can close
         the SSH connection, but not until we've connected back to the master via
         Rpc. This allows us to report any initialization errors to the master via the SSH
         connection. *)
      let redirect_stdout =
        Utils.to_daemon_fd_redirection config.redirect_stdout
      in
      let redirect_stderr =
        Utils.to_daemon_fd_redirection config.redirect_stderr
      in
      let release_daemon =
        Staged.unstage (
          (* This call can fail (e.g. cd to a nonexistent directory). The uncaught
             exception will automatically be written to stderr which is read by the
             master *)
          Daemon.daemonize_wait ~redirect_stdout ~redirect_stderr
            ?cd:config.cd
            ?umask:config.umask
            ()
        )
      in
      worker_main ~id ~config ~release_daemon;
      never_returns (Scheduler.go ())

  let init_master_exn ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
        ~worker_command_args () =
    match Utils.whoami () with
    | `Worker _ -> failwith "Do not call [init_master_exn] in a spawned worker"
    | `Master ->
      init_master_state ?rpc_max_message_size ?rpc_handshake_timeout ?rpc_heartbeat_config
        ~worker_command_args
end

module State = struct
  type t = [ `started ]

  let get () = Option.map (Set_once.get global_state) ~f:(fun _ -> `started)
end

let start_app ?rpc_max_message_size ?rpc_handshake_timeout
      ?rpc_heartbeat_config command =
  match Utils.whoami () with
  | `Worker _ ->
    Expert.run_as_worker_exn ()
  | `Master ->
    Expert.init_master_exn ?rpc_max_message_size ?rpc_handshake_timeout
      ?rpc_heartbeat_config
      ~worker_command_args:[] ();
    Command.run command
;;