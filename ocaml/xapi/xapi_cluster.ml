(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xapi_clustering

module D=Debug.Make(struct let name="xapi_cluster" end)
open D

(* TODO: update allowed_operations on boot/toolstack-restart *)

let validate_params ~token_timeout ~token_timeout_coefficient =
  let invalid_value x y = raise (Api_errors.(Server_error (invalid_value, [ x; y ]))) in
  if token_timeout < 1.0 then invalid_value "token_timeout" (string_of_float token_timeout);
  if token_timeout_coefficient < 0.65 then invalid_value "token_timeout_coefficient" (string_of_float token_timeout_coefficient)

let create ~__context ~pIF ~cluster_stack ~pool_auto_join ~token_timeout ~token_timeout_coefficient =
  assert_cluster_stack_valid ~cluster_stack;

  (* Currently we only support corosync. If we support more cluster stacks, this
   * should be replaced by a general function that checks the given cluster_stack *)
  Pool_features.assert_enabled ~__context ~f:Features.Corosync;
  with_clustering_lock __LOC__(fun () ->
      let dbg = Context.string_of_task __context in
      validate_params ~token_timeout ~token_timeout_coefficient;
      let cluster_ref = Ref.make () in
      let cluster_host_ref = Ref.make () in
      let cluster_uuid = Uuidm.to_string (Uuidm.create `V4) in
      let cluster_host_uuid = Uuidm.to_string (Uuidm.create `V4) in
      (* For now we assume we have only one pool
         TODO: get master ref explicitly passed in as parameter*)
      let host = Helpers.get_master ~__context in

      let pifrec = Db.PIF.get_record ~__context ~self:pIF in
      assert_pif_prerequisites (pIF,pifrec);
      let ip = ip_of_pif (pIF,pifrec) in

      let token_timeout_ms = Int64.of_float(token_timeout*.1000.0) in
      let token_timeout_coefficient_ms = Int64.of_float(token_timeout_coefficient*.1000.0) in
      let init_config = {
        Cluster_interface.local_ip = ip;
        token_timeout_ms = Some token_timeout_ms;
        token_coefficient_ms = Some token_timeout_coefficient_ms;
        name = None
      } in

      Xapi_clustering.Daemon.enable ~__context;
      let result = Cluster_client.LocalClient.create (rpc ~__context) dbg init_config in
      match result with
      | Result.Ok cluster_token ->
        D.debug "Got OK from LocalClient.create";
        Db.Cluster.create ~__context ~ref:cluster_ref ~uuid:cluster_uuid ~cluster_token ~cluster_stack ~pending_forget:[]
          ~pool_auto_join ~token_timeout ~token_timeout_coefficient ~current_operations:[] ~allowed_operations:[] ~cluster_config:[]
          ~other_config:[];
        Db.Cluster_host.create ~__context ~ref:cluster_host_ref ~uuid:cluster_host_uuid ~cluster:cluster_ref ~host ~enabled:true ~pIF
          ~current_operations:[] ~allowed_operations:[] ~other_config:[] ~joined:true;
        Xapi_cluster_host_helpers.update_allowed_operations ~__context ~self:cluster_host_ref;
        D.debug "Created Cluster: %s and Cluster_host: %s" (Ref.string_of cluster_ref) (Ref.string_of cluster_host_ref);
        set_ha_cluster_stack ~__context;
        cluster_ref
      | Result.Error error ->
        D.warn "Error occurred during Cluster.create";
        handle_error error
    )

let destroy ~__context ~self =
  let cluster_hosts = Db.Cluster.get_cluster_hosts ~__context ~self in
  let cluster_host = match cluster_hosts with
    | [] -> None
    | [ cluster_host ] -> Some (cluster_host)
    | _ ->
      let n = List.length cluster_hosts in
      raise Api_errors.(Server_error(cluster_does_not_have_one_node, [string_of_int n]))
  in
  Xapi_stdext_monadic.Opt.iter (fun ch ->
    assert_cluster_host_has_no_attached_sr_which_requires_cluster_stack ~__context ~self:ch;
    Xapi_cluster_host.force_destroy ~__context ~self:ch
  ) cluster_host;
  Db.Cluster.destroy ~__context ~self;
  D.debug "Cluster destroyed successfully";
  set_ha_cluster_stack ~__context;
  Xapi_clustering.Daemon.disable ~__context

let get_network ~__context ~self =
  get_network_internal ~__context ~self

(* helper function; concurrency checks are done in implementation of Cluster.create and Cluster_host.create *)
let pool_create ~__context ~network ~cluster_stack ~token_timeout ~token_timeout_coefficient =
  validate_params ~token_timeout ~token_timeout_coefficient;
  let master = Helpers.get_master ~__context in
  let slave_hosts = Xapi_pool_helpers.get_slaves_list ~__context in
  let pIF,_ = pif_of_host ~__context network master in
  let cluster = Helpers.call_api_functions ~__context (fun rpc session_id ->
      Client.Client.Cluster.create ~rpc ~session_id ~pIF ~cluster_stack
        ~pool_auto_join:true ~token_timeout ~token_timeout_coefficient)
  in

  List.iter (fun host ->
      (* Cluster.create already created cluster_host on master, so we only need to iterate through slaves *)
      Helpers.call_api_functions ~__context (fun rpc session_id ->
          let pifref,_ = pif_of_host ~__context network host in
          let cluster_host_ref = Client.Client.Cluster_host.create ~rpc ~session_id ~cluster ~host ~pif:pifref in
          D.debug "Created Cluster_host: %s" (Ref.string_of cluster_host_ref);
        )) slave_hosts;

  cluster

(* Helper function; if opn is None return all, else return those not equal to it *)
let filter_on_option opn xs =
  match opn with
  | None -> xs
  | Some x -> List.filter ((<>) x) xs

(* Helper function; concurrency checks are done in implementation of Cluster.destroy and Cluster_host.destroy *)
let pool_force_destroy ~__context ~self =
  (* For now we assume we have only one pool, and that the cluster is the same as the pool.
     This means that the pool master must be a member of this cluster. *)
  let master = Helpers.get_master ~__context in
  let master_cluster_host =
    Xapi_clustering.find_cluster_host ~__context ~host:master
  in
  let slave_cluster_hosts =
    Db.Cluster.get_cluster_hosts ~__context ~self |> filter_on_option master_cluster_host
  in
  debug "Destroying cluster_hosts in pool";
  (* First try to destroy each cluster_host - if we can do so safely then do *)
  List.iter
    (fun cluster_host ->
      (* We need to run this code on the slave *)
      (* We ignore failures here, we'll try a force_destroy after *)
      log_and_ignore_exn (fun () ->
        Helpers.call_api_functions ~__context (fun rpc session_id ->
            Client.Client.Cluster_host.destroy ~rpc ~session_id ~self:cluster_host)
      )
    )
    slave_cluster_hosts;
  (* We expect destroy to have failed for some, we'll try to force destroy those *)
  (* Note we include the master here, we should attempt to force destroy it *)
  let all_remaining_cluster_hosts =
    Db.Cluster.get_cluster_hosts ~__context ~self
  in
  (* Now try to force_destroy, keep track of any errors here *)
  let exns = List.fold_left
    (fun exns_so_far cluster_host ->
      Helpers.call_api_functions ~__context (fun rpc session_id ->
        try
          Client.Client.Cluster_host.force_destroy ~rpc ~session_id ~self:cluster_host;
          exns_so_far
        with e ->
          Backtrace.is_important e;
          let uuid = Client.Client.Cluster_host.get_uuid ~rpc ~session_id ~self:cluster_host in
          debug "Ignoring exception while trying to force destroy cluster host %s: %s" uuid (ExnHelper.string_of_exn e);
          e :: exns_so_far
      )
    )
    [] all_remaining_cluster_hosts
    in

    begin match exns with
      | [] -> D.debug "Successfully destroyed all cluster_hosts in pool, now destroying cluster %s" (Ref.string_of self)
      | e :: _ -> raise Api_errors.(Server_error (cluster_force_destroy_failed, [Ref.string_of self]))
    end;

    Helpers.call_api_functions ~__context (fun rpc session_id ->
      Client.Client.Cluster.destroy ~rpc ~session_id ~self);
    debug "Cluster_host.force_destroy was successful"

(* Helper function; concurrency checks are done in implementation of Cluster.destroy and Cluster_host.destroy *)
let pool_destroy ~__context ~self =
  (* For now we assume we have only one pool, and that the cluster is the same as the pool.
     This means that the pool master must be a member of this cluster. *)
  let master = Helpers.get_master ~__context in
  let master_cluster_host =
    Xapi_clustering.find_cluster_host ~__context ~host:master
    |> Xapi_stdext_monadic.Opt.unbox
  in
  let slave_cluster_hosts =
    Db.Cluster.get_cluster_hosts ~__context ~self |> List.filter ((<>) master_cluster_host)
  in
  (* First destroy the Cluster_host objects of the slaves *)
  List.iter
    (fun cluster_host ->
       (* We need to run this code on the slave *)
       Helpers.call_api_functions ~__context (fun rpc session_id ->
           Client.Client.Cluster_host.destroy ~rpc ~session_id ~self:cluster_host)
    )
    slave_cluster_hosts;
  (* Then destroy the Cluster_host of the pool master and the Cluster itself *)
  Helpers.call_api_functions ~__context (fun rpc session_id ->
      Client.Client.Cluster.destroy ~rpc ~session_id ~self)

let pool_resync ~__context ~(self : API.ref_Cluster) =
  List.iter
    (fun host -> log_and_ignore_exn
        (fun () ->
           Xapi_cluster_host.create_as_necessary ~__context ~host;
           Xapi_cluster_host.resync_host ~__context ~host;
           if is_clustering_disabled_on_host ~__context host
           then raise Api_errors.(Server_error (no_compatible_cluster_host, [Ref.string_of host]))
            (* If host.clustering_enabled then resync_host should successfully
               find or create a matching cluster_host which is also enabled *)
        )
    ) (Xapi_pool_helpers.get_master_slaves_list ~__context)
