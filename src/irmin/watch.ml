(*
 * Copyright (c) 2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

let src = Logs.Src.create "irmin.watch" ~doc:"Irmin watch notifications"

module Log = (val Logs.src_log src : Logs.LOG)

module type S = sig
  type key

  type value

  type watch

  type t

  val stats : t -> int * int

  val notify : t -> key -> value option -> unit Lwt.t

  val v : unit -> t

  val clear : t -> unit Lwt.t

  val watch_key :
    t -> key -> ?init:value -> (value Diff.t -> unit Lwt.t) -> watch Lwt.t

  val watch :
    t ->
    ?init:(key * value) list ->
    (key -> value Diff.t -> unit Lwt.t) ->
    watch Lwt.t

  val unwatch : t -> watch -> unit Lwt.t

  val listen_dir :
    t ->
    string ->
    key:(string -> key option) ->
    value:(key -> value option Lwt.t) ->
    (unit -> unit Lwt.t) Lwt.t
end

let none _ _ =
  Printf.eprintf "Listen hook not set!\n%!";
  assert false

let listen_dir_hook = ref none

type hook =
  int -> string -> (string -> unit Lwt.t) -> (unit -> unit Lwt.t) Lwt.t

let set_listen_dir_hook (h : hook) = listen_dir_hook := h

let id () =
  let c = ref 0 in
  fun () ->
    incr c;
    !c

let global = id ()

let workers_r = ref 0

let workers () = !workers_r

let scheduler () =
  let p = ref None in
  let niet () = () in
  let c = ref niet in
  let push elt =
    match !p with
    | Some p -> p elt
    | None ->
        let stream, push = Lwt_stream.create () in
        incr workers_r;
        Lwt.async (fun () ->
            (* FIXME: we would like to skip some updates if more recent ones
             are at the back of the queue. *)
            Lwt_stream.iter_s (fun f -> f ()) stream );
        p := Some push;
        (c := fun () -> push None);
        push elt
  in
  let clean () =
    !c ();
    decr workers_r;
    c := niet;
    p := None
  in
  let enqueue v = push (Some v) in
  (clean, enqueue)

module Make (K : sig
  type t

  val t : t Type.t
end) (V : sig
  type t

  val t : t Type.t
end) =
struct
  type key = K.t

  type value = V.t

  type watch = int

  module KMap = Map.Make (struct
    type t = K.t

    let compare = Type.compare K.t
  end)

  module IMap = Map.Make (struct
    type t = int

    let compare (x : int) (y : int) = compare x y
  end)

  type key_handler = value Diff.t -> unit Lwt.t

  type all_handler = key -> value Diff.t -> unit Lwt.t

  let pp_value = Type.pp V.t

  let equal_opt_values = Type.(equal (option V.t))

  let equal_keys = Type.equal K.t

  type t = {
    id : int;
    (* unique watch manager id. *)
    lock : Lwt_mutex.t;
    (* protect [keys] and [glb]. *)
    mutable next : int;
    (* next id, to identify watch handlers. *)
    mutable keys : (key * value option * key_handler) IMap.t;
    (* key handlers. *)
    mutable glob : (value KMap.t * all_handler) IMap.t;
    (* global handlers. *)
    enqueue : (unit -> unit Lwt.t) -> unit;
    (* enqueue notifications. *)
    clean : unit -> unit;
    (* destroy the notification thread. *)
    mutable listeners : int;
    (* number of listeners. *)
    mutable stop_listening : unit -> unit Lwt.t
        (* clean-up listen resources. *)
  }

  let stats t = (IMap.cardinal t.keys, IMap.cardinal t.glob)

  let to_string t =
    let k, a = stats t in
    Printf.sprintf "[%d: %dk/%dg|%d]" t.id k a t.listeners

  let next t =
    let id = t.next in
    t.next <- id + 1;
    id

  let is_empty t = IMap.is_empty t.keys && IMap.is_empty t.glob

  let clear_unsafe t =
    t.keys <- IMap.empty;
    t.glob <- IMap.empty;
    t.next <- 0

  let clear t =
    Lwt_mutex.with_lock t.lock (fun () ->
        clear_unsafe t;
        Lwt.return_unit )

  let v () =
    let lock = Lwt_mutex.create () in
    let clean, enqueue = scheduler () in
    { lock;
      clean;
      enqueue;
      id = global ();
      next = 0;
      keys = IMap.empty;
      glob = IMap.empty;
      listeners = 0;
      stop_listening = (fun () -> Lwt.return_unit)
    }

  let unwatch_unsafe t id =
    Log.debug (fun f -> f "unwatch %s: id=%d" (to_string t) id);
    let glob = IMap.remove id t.glob in
    let keys = IMap.remove id t.keys in
    t.glob <- glob;
    t.keys <- keys

  let unwatch t id =
    Lwt_mutex.with_lock t.lock (fun () ->
        unwatch_unsafe t id;
        if is_empty t then t.clean ();
        Lwt.return_unit )

  let mk old value =
    match (old, value) with
    | None, None -> assert false
    | Some v, None -> `Removed v
    | None, Some v -> `Added v
    | Some x, Some y -> `Updated (x, y)

  let protect f () =
    Lwt.catch f (fun e ->
        Log.err (fun l ->
            l "watch callback got: %a\n%s" Fmt.exn e
              (Printexc.get_backtrace ()) );
        Lwt.return_unit )

  let notify_all_unsafe t key value =
    let todo = ref [] in
    let glob =
      IMap.fold
        (fun id ((init, f) as arg) acc ->
          let fire old_value =
            Log.debug (fun f ->
                f "notify-all[%d.%d]: firing! (v=%a)" t.id id
                  Fmt.(Dump.option pp_value)
                  old_value );
            todo := protect (fun () -> f key (mk old_value value)) :: !todo;
            let init =
              match value with
              | None -> KMap.remove key init
              | Some v -> KMap.add key v init
            in
            IMap.add id (init, f) acc
          in
          let old_value =
            try Some (KMap.find key init) with Not_found -> None
          in
          if equal_opt_values old_value value then (
            Log.debug (fun f ->
                f "notify-all[%d:%d]: same value, skipping." t.id id );
            IMap.add id arg acc )
          else fire old_value )
        t.glob IMap.empty
    in
    t.glob <- glob;
    match !todo with
    | [] -> ()
    | ts -> t.enqueue (fun () -> Lwt_list.iter_p (fun x -> x ()) ts)

  let notify_key_unsafe t key value =
    let todo = ref [] in
    let keys =
      IMap.fold
        (fun id ((k, old_value, f) as arg) acc ->
          if not (equal_keys key k) then IMap.add id arg acc
          else if equal_opt_values value old_value then (
            Log.debug (fun f ->
                f "notify-key[%d.%d]: same value, skipping." t.id id );
            IMap.add id arg acc )
          else (
            Log.debug (fun f -> f "notify-key[%d:%d] firing!" t.id id);
            todo := protect (fun () -> f (mk old_value value)) :: !todo;
            IMap.add id (k, value, f) acc ) )
        t.keys IMap.empty
    in
    t.keys <- keys;
    match !todo with
    | [] -> ()
    | ts -> t.enqueue (fun () -> Lwt_list.iter_p (fun x -> x ()) ts)

  let notify t key value =
    Lwt_mutex.with_lock t.lock (fun () ->
        if is_empty t then Lwt.return_unit
        else (
          notify_all_unsafe t key value;
          notify_key_unsafe t key value;
          Lwt.return_unit ) )

  let watch_key_unsafe t key ?init f =
    let id = next t in
    Log.debug (fun f -> f "watch-key %s: id=%d" (to_string t) id);
    t.keys <- IMap.add id (key, init, f) t.keys;
    id

  let watch_key t key ?init f =
    Lwt_mutex.with_lock t.lock (fun () ->
        let id = watch_key_unsafe t ?init key f in
        Lwt.return id )

  let kmap_of_alist l =
    List.fold_left (fun map (k, v) -> KMap.add k v map) KMap.empty l

  let watch_unsafe t ?(init = []) f =
    let id = next t in
    Log.debug (fun f -> f "watch %s: id=%d" (to_string t) id);
    t.glob <- IMap.add id (kmap_of_alist init, f) t.glob;
    id

  let watch t ?init f =
    Lwt_mutex.with_lock t.lock (fun () ->
        let id = watch_unsafe t ?init f in
        Lwt.return id )

  let listen_dir t dir ~key ~value =
    let init () =
      if t.listeners = 0 then (
        Log.debug (fun f -> f "%s: start listening to %s" (to_string t) dir);
        !listen_dir_hook t.id dir (fun file ->
            match key file with
            | None -> Lwt.return_unit
            | Some key -> value key >>= notify t key )
        >|= fun f -> t.stop_listening <- f )
      else (
        Log.debug (fun f -> f "%s: already listening on %s" (to_string t) dir);
        Lwt.return_unit )
    in
    init () >|= fun () ->
    t.listeners <- t.listeners + 1;
    function
    | () ->
        if t.listeners > 0 then t.listeners <- t.listeners - 1;
        if t.listeners <> 0 then Lwt.return_unit
        else (
          Log.debug (fun f -> f "%s: stop listening to %s" (to_string t) dir);
          t.stop_listening () )
end
