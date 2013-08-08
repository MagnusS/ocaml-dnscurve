open Dns_resolver
open Dnscurve
module Crypto = Sodium.Make(Sodium.Serialize.String)

type env = { mutable streamlined : bool option; mutable txt : bool option; }

let new_env () = { streamlined = None; txt = None; }
let reset_env env = env.streamlined <- None; env.txt <- None; ()

let between inside outside keyf env server_pk zone =
  let module O = (val outside : RESOLVER) in
  let module I = (val inside : RESOLVER) in
  let module M = struct
    type context =
    | Streamlined of env * I.context * channel
    | Txt of env * I.context * channel * O.context

    let get_id () =
      let s = Crypto.random 2 in
      ((int_of_char s.[0]) lsl 8) lor (int_of_char s.[1])

    let marshal pkt =
      let keyring, ident = keyf () in
      let streamlined () =
        List.rev_map
          (fun (ictxt, buf) ->
            let chan, buf = encode_streamlined_query ?keyring ident
              server_pk buf in
            Streamlined (env, ictxt, chan), buf)
          (I.marshal pkt)
      in
      let txt () =
        let id = get_id () in
        List.fold_left
          (fun xs (ictxt,buf) ->
            let chan, pkt = encode_txt_query ?keyring ~id ident
              server_pk zone buf in
            List.fold_left
              (fun xs (octxt,buf) ->
                (Txt (env, ictxt, chan, octxt), buf)::xs
              ) xs (O.marshal pkt)
          ) [] (I.marshal pkt)
      in
      match env with (* TODO: factor streamlined+txt in DNSCurve *)
      | { streamlined=None; txt=None }             -> (streamlined ())@(txt ())
      | { streamlined=(None | Some true) }         -> streamlined ()
      | { txt=(None | Some true) }                 -> txt ()
      | { streamlined=Some false; txt=Some false } -> []

    let parse chan buf = try begin match chan with
      | Streamlined (env,ictxt,chan) ->
        let pkt = I.parse ictxt (decode_streamlined_response chan buf) in
        env.streamlined <- Some true;
        pkt
      | Txt (env,ictxt,chan,octxt) ->
        begin match O.parse octxt buf with
        | None -> None (* TODO: tag context for timeout callback *)
        | Some txt ->
          let pkt = I.parse ictxt (decode_txt_response chan txt) in
          env.txt <- Some true;
          pkt
        end
    end with exn ->
      Printf.eprintf "Exception: %s\nBacktrace:\n%!" (Printexc.to_string exn);
      Printexc.print_backtrace stderr;
      None (* TODO: tag context for timeout callback *)

    let timeout = function
      | Streamlined (env,_,_) ->
        env.streamlined <- Some false; Dns_resolve_timeout
      | Txt (env,_,_,_) ->
        env.txt <- Some false; Dns_resolve_timeout
  end in
  (module M : RESOLVER)

let fallback resolver keyf env server_pk zone =
  let dnscurve = between resolver resolver keyf env server_pk zone in
  let module D = (val resolver : RESOLVER) in
  let module M = struct
    module C = (val dnscurve : RESOLVER)
    type context = Curve of C.context | Clear of D.context

    let get_id = C.get_id

    let marshal pkt =
      List.(rev_append
              (rev_map (fun (ctxt,buf) -> Clear ctxt, buf) (D.marshal pkt))
              (rev_map (fun (ctxt,buf) -> Curve ctxt, buf) (C.marshal pkt))
      )

    let parse ctxt buf = try begin match ctxt with
      | Curve c -> C.parse c buf
      | Clear c -> D.parse c buf
    end with _ -> None

    let timeout = function
      | Curve c -> C.timeout c
      | Clear c -> D.timeout c
  end in
  (module M : RESOLVER)
