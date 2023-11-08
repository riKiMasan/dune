open Import

(* we need to convince ocamldep that we don't depend on the menhir rules *)
module Menhir = struct end
open Dune_file
open Memo.O

let loc_of_dune_file st_dir =
  (match
     let open Option.O in
     let* dune_file = Source_tree.Dir.dune_file st_dir in
     (* TODO not really correct. we need to know the [(subdir ..)] that introduced this *)
     Source_tree.Dune_file.path dune_file
   with
   | Some s -> s
   | None -> Path.Source.relative (Source_tree.Dir.path st_dir) "_unknown_")
  |> Path.source
  |> Loc.in_file
;;

type t =
  { kind : kind
  ; dir : Path.Build.t
  ; text_files : Filename.Set.t
  ; foreign_sources : Foreign_sources.t Memo.Lazy.t
  ; mlds : (Documentation.t * Path.Build.t list) list Memo.Lazy.t
  ; coq : Coq_sources.t Memo.Lazy.t
  ; ml : Ml_sources.t Memo.Lazy.t
  }

and kind =
  | Standalone
  | Group_root of t list
  | Group_part

let empty kind ~dir =
  { kind
  ; dir
  ; text_files = Filename.Set.empty
  ; ml = Memo.Lazy.of_val Ml_sources.empty
  ; mlds = Memo.Lazy.of_val []
  ; foreign_sources = Memo.Lazy.of_val Foreign_sources.empty
  ; coq = Memo.Lazy.of_val Coq_sources.empty
  }
;;

module Standalone_or_root = struct
  type nonrec standalone_or_root =
    { root : t
    ; subdirs : t Path.Build.Map.t
    ; rules : Rules.t
    }

  type nonrec t =
    { directory_targets : Loc.t Path.Build.Map.t
    ; contents : standalone_or_root Memo.Lazy.t
    }

  let empty ~dir =
    { directory_targets = Path.Build.Map.empty
    ; contents =
        Memo.Lazy.create (fun () ->
          Memo.return
            { root = empty Standalone ~dir
            ; rules = Rules.empty
            ; subdirs = Path.Build.Map.empty
            })
    }
  ;;

  let directory_targets t = t.directory_targets

  let root t =
    let+ contents = Memo.Lazy.force t.contents in
    contents.root
  ;;

  let subdirs t =
    let+ contents = Memo.Lazy.force t.contents in
    Path.Build.Map.values contents.subdirs
  ;;

  let rules t =
    let+ contents = Memo.Lazy.force t.contents in
    contents.rules
  ;;
end

type triage =
  | Standalone_or_root of Standalone_or_root.t
  | Group_part of Path.Build.t

let dir t = t.dir
let coq t = Memo.Lazy.force t.coq
let ocaml t = Memo.Lazy.force t.ml
let artifacts t = Memo.Lazy.force t.ml >>= Ml_sources.artifacts

let dirs t =
  match t.kind with
  | Standalone -> [ t ]
  | Group_root subs -> t :: subs
  | Group_part ->
    Code_error.raise
      "Dir_contents.dirs called on a group part"
      [ "dir", Path.Build.to_dyn t.dir ]
;;

let text_files t = t.text_files
let foreign_sources t = Memo.Lazy.force t.foreign_sources

let mlds t (doc : Documentation.t) =
  let+ map = Memo.Lazy.force t.mlds in
  match
    List.find_map map ~f:(fun (doc', x) -> Option.some_if (Loc.equal doc.loc doc'.loc) x)
  with
  | Some x -> x
  | None ->
    Code_error.raise
      "Dir_contents.mlds"
      [ "doc", Loc.to_dyn_hum doc.loc
      ; ( "available"
        , Dyn.(list Loc.to_dyn_hum)
            (List.map map ~f:(fun ((d : Documentation.t), _) -> d.loc)) )
      ]
;;

let build_mlds_map stanzas ~dir ~files =
  let mlds =
    Memo.lazy_ (fun () ->
      Filename.Set.fold files ~init:Filename.Map.empty ~f:(fun fn acc ->
        (* TODO this doesn't handle [.foo.mld] correctly *)
        match String.lsplit2 fn ~on:'.' with
        | Some (s, "mld") -> Filename.Map.set acc s fn
        | _ -> acc)
      |> Memo.return)
  in
  Memo.parallel_map stanzas ~f:(function
    | Documentation doc ->
      let+ mlds =
        let+ mlds = Memo.Lazy.force mlds in
        Ordered_set_lang.Unordered_string.eval
          doc.mld_files
          ~standard:mlds
          ~key:Fun.id
          ~parse:(fun ~loc s ->
            match String.Map.find mlds s with
            | Some s -> s
            | None ->
              User_error.raise
                ~loc
                [ Pp.textf
                    "%s.mld doesn't exist in %s"
                    s
                    (Path.to_string_maybe_quoted
                       (Path.drop_optional_build_context (Path.build dir)))
                ])
      in
      Some (doc, List.map (Filename.Map.values mlds) ~f:(Path.Build.relative dir))
    | _ -> Memo.return None)
  >>| List.filter_opt
;;

module rec Load : sig
  val get : Super_context.t -> dir:Path.Build.t -> t Memo.t
  val triage : Super_context.t -> dir:Path.Build.t -> triage Memo.t
  val add_sources_to_expander : Super_context.t -> Expander.t -> Expander.t
end = struct
  let add_sources_to_expander sctx expander =
    let f ~dir = Load.get sctx ~dir >>= artifacts in
    Expander.set_lookup_ml_sources expander ~f
  ;;

  let select_deps_files libraries =
    (* Manually add files generated by the (select ...)
       dependencies *)
    List.filter_map libraries ~f:(fun dep ->
      match (dep : Lib_dep.t) with
      | Re_export _ | Direct _ -> None
      | Select s -> Some s.result_fn)
  ;;

  (* As a side-effect, setup user rules and copy_files rules. *)
  let load_text_files sctx st_dir stanzas ~dir ~src_dir =
    (* Interpret a few stanzas in order to determine the list of files generated
       by the user. *)
    let+ generated_files =
      let* expander = Super_context.expander sctx ~dir >>| add_sources_to_expander sctx in
      Memo.parallel_map stanzas ~f:(fun stanza ->
        match (stanza : Stanza.t) with
        | Coq_stanza.Coqpp.T { modules; _ } ->
          Coq_sources.mlg_files ~sctx ~dir ~modules
          >>| List.rev_map ~f:(fun mlg_file ->
            Path.Build.set_extension mlg_file ~ext:".ml" |> Path.Build.basename)
        | Coq_stanza.Extraction.T s ->
          Memo.return (Coq_stanza.Extraction.ml_target_fnames s)
        | Menhir_stanza.T menhir -> Memo.return (Menhir_stanza.targets menhir)
        | Rule rule ->
          Simple_rules.user_rule sctx rule ~dir ~expander
          >>| (function
          | None -> []
          | Some targets ->
            (* CR-someday amokhov: Do not ignore directory targets. *)
            Path.Build.Set.to_list_map targets.files ~f:Path.Build.basename)
        | Copy_files def ->
          Simple_rules.copy_files sctx def ~src_dir ~dir ~expander
          >>| Path.Set.to_list_map ~f:Path.basename
        | Generate_sites_module_stanza.T def ->
          Generate_sites_module_rules.setup_rules sctx ~dir def >>| List.singleton
        | Library { buildable; _ } | Executables { buildable; _ } ->
          let select_deps_files = select_deps_files buildable.libraries in
          let ctypes_files =
            (* Also manually add files generated by ctypes rules. *)
            match buildable.ctypes with
            | None -> []
            | Some ctypes -> Ctypes_field.generated_ml_and_c_files ctypes
          in
          Memo.return (select_deps_files @ ctypes_files)
        | Melange_stanzas.Emit.T { libraries; _ } ->
          Memo.return @@ select_deps_files libraries
        | _ -> Memo.return [])
      >>| List.concat
      >>| Filename.Set.of_list
    in
    Filename.Set.union generated_files (Source_tree.Dir.files st_dir)
  ;;

  module Key = struct
    module Super_context = Super_context.As_memo_key

    type t = Super_context.t * Path.Build.t

    let to_dyn (sctx, path) =
      Dyn.Tuple [ Super_context.to_dyn sctx; Path.Build.to_dyn path ]
    ;;

    let equal = Tuple.T2.equal Super_context.equal Path.Build.equal
    let hash = Tuple.T2.hash Super_context.hash Path.Build.hash
  end

  let lookup_vlib sctx ~current_dir ~loc ~dir =
    match Path.Build.equal current_dir dir with
    | true ->
      User_error.raise
        ~loc
        [ Pp.text
            "Virtual library and its implementation(s) cannot be defined in the same \
             directory"
        ]
    | false -> Load.get sctx ~dir >>= ocaml
  ;;

  module Group_component = struct
    type t =
      { dir : Path.Build.t
      ; path_to_group_root : Filename.t list
      ; source_dir : Source_tree.Dir.t
      ; stanzas : Stanza.t list
      }
  end

  let collect_group =
    let rec walk st_dir ~dir ~local =
      Dir_status.DB.get ~dir
      >>= function
      | Generated | Source_only _ | Standalone _ | Group_root _ ->
        Memo.return Appendable_list.empty
      | Is_component_of_a_group_but_not_the_root { stanzas; group_root = _ } ->
        walk_children st_dir ~dir ~local
        >>| Appendable_list.( @ )
              (Appendable_list.singleton
                 { Group_component.dir
                 ; path_to_group_root = List.rev local
                 ; source_dir = st_dir
                 ; stanzas =
                     (match stanzas with
                      | None -> []
                      | Some d -> d.stanzas)
                 })
    and walk_children st_dir ~dir ~local =
      (* TODO take account of directory targets *)
      Source_tree.Dir.sub_dirs st_dir
      |> Filename.Map.to_list
      |> Memo.parallel_map ~f:(fun (basename, st_dir) ->
        let* st_dir = Source_tree.Dir.sub_dir_as_t st_dir in
        let dir = Path.Build.relative dir basename in
        let local = basename :: local in
        walk st_dir ~dir ~local)
      >>| Appendable_list.concat
    in
    fun ~st_dir ~dir -> walk_children st_dir ~dir ~local:[] >>| Appendable_list.to_list
  ;;

  let extract_directory_targets ~dir stanzas =
    List.fold_left stanzas ~init:Path.Build.Map.empty ~f:(fun acc stanza ->
      match stanza with
      | Rule { targets = Static { targets = l; _ }; loc = rule_loc; _ } ->
        List.fold_left l ~init:acc ~f:(fun acc (target, kind) ->
          let loc = String_with_vars.loc target in
          match (kind : Targets_spec.Kind.t) with
          | File -> acc
          | Directory ->
            (match String_with_vars.text_only target with
             | None ->
               User_error.raise
                 ~loc
                 [ Pp.text "Variables are not allowed in directory targets." ]
             | Some target ->
               let dir_target = Path.Build.relative ~error_loc:loc dir target in
               if Path.Build.is_descendant dir_target ~of_:dir
               then
                 (* We ignore duplicates here as duplicates are detected and
                    reported by [Load_rules]. *)
                 Path.Build.Map.set acc dir_target rule_loc
               else
                 (* This will be checked when we interpret the stanza
                    completely, so just ignore this rule for now. *)
                 acc))
      | _ -> acc)
  ;;

  let human_readable_description dir =
    Pp.textf
      "Computing directory contents of %s"
      (Path.to_string_maybe_quoted (Path.build dir))
  ;;

  let make_standalone sctx st_dir ~dir (d : Dune_file.t) =
    let human_readable_description () = human_readable_description dir in
    { Standalone_or_root.directory_targets = extract_directory_targets ~dir d.stanzas
    ; contents =
        Memo.lazy_ ~human_readable_description (fun () ->
          let include_subdirs = Loc.none, Include_subdirs.No in
          let ctx = Super_context.context sctx in
          let lib_config =
            let+ ocaml = Context.ocaml ctx in
            ocaml.lib_config
          in
          let+ files, rules =
            Rules.collect (fun () ->
              load_text_files sctx st_dir d.stanzas ~src_dir:d.dir ~dir)
          in
          let dirs = [ { Source_file_dir.dir; path_to_root = []; files } ] in
          let ml =
            Memo.lazy_ (fun () ->
              let lookup_vlib = lookup_vlib sctx ~current_dir:dir in
              let loc = loc_of_dune_file st_dir in
              let libs = Scope.DB.find_by_dir dir >>| Scope.libs in
              Ml_sources.make
                d.stanzas
                ~dir
                ~libs
                ~project:d.project
                ~lib_config
                ~loc
                ~include_subdirs
                ~lookup_vlib
                ~dirs)
          in
          { Standalone_or_root.root =
              { kind = Standalone
              ; dir
              ; text_files = files
              ; ml
              ; mlds = Memo.lazy_ (fun () -> build_mlds_map d.stanzas ~dir ~files)
              ; foreign_sources =
                  Memo.lazy_ (fun () ->
                    let+ lib_config = lib_config in
                    let dune_version = Dune_project.dune_version d.project in
                    Foreign_sources.make d.stanzas ~dune_version ~lib_config ~dirs)
              ; coq =
                  Memo.lazy_ (fun () ->
                    Coq_sources.of_dir d.stanzas ~dir ~include_subdirs ~dirs
                    |> Memo.return)
              }
          ; rules
          ; subdirs = Path.Build.Map.empty
          })
    }
  ;;

  let make_group_root sctx st_dir qualif_mode ~dir (d : Dune_file.t) =
    let include_subdirs =
      let loc, qualif_mode = qualif_mode in
      loc, Include_subdirs.Include qualif_mode
    in
    let loc = loc_of_dune_file st_dir in
    let+ subdirs = collect_group ~st_dir ~dir in
    let directory_targets =
      let dirs =
        { Group_component.dir
        ; path_to_group_root = []
        ; source_dir = st_dir
        ; stanzas = d.stanzas
        }
        :: subdirs
      in
      List.fold_left
        dirs
        ~init:Path.Build.Map.empty
        ~f:(fun acc { Group_component.dir; stanzas; _ } ->
          match stanzas with
          | [] -> acc
          | _ :: _ ->
            Path.Build.Map.union
              acc
              (extract_directory_targets ~dir stanzas)
              ~f:(fun _ _ x -> Some x))
    in
    let contents =
      Memo.lazy_
        ~human_readable_description:(fun () -> human_readable_description dir)
        (fun () ->
          let ctx = Super_context.context sctx in
          let+ (files, subdirs), rules =
            Rules.collect (fun () ->
              Memo.fork_and_join
                (fun () -> load_text_files sctx st_dir d.stanzas ~src_dir:d.dir ~dir)
                (fun () ->
                  Memo.parallel_map
                    subdirs
                    ~f:(fun { dir; path_to_group_root; source_dir; stanzas } ->
                      let+ files =
                        match stanzas with
                        | [] -> Memo.return (Source_tree.Dir.files source_dir)
                        | _ :: _ ->
                          load_text_files
                            sctx
                            source_dir
                            stanzas
                            ~src_dir:(Source_tree.Dir.path source_dir)
                            ~dir
                      in
                      { Source_file_dir.dir; path_to_root = path_to_group_root; files })))
          in
          let dirs = { Source_file_dir.dir; path_to_root = []; files } :: subdirs in
          let lib_config =
            let+ ocaml = Context.ocaml ctx in
            ocaml.lib_config
          in
          let ml =
            Memo.lazy_ (fun () ->
              let lookup_vlib = lookup_vlib sctx ~current_dir:dir in
              let libs = Scope.DB.find_by_dir dir >>| Scope.libs in
              let project = d.project in
              Ml_sources.make
                d.stanzas
                ~dir
                ~project
                ~libs
                ~lib_config
                ~loc
                ~lookup_vlib
                ~include_subdirs
                ~dirs)
          in
          let foreign_sources =
            Memo.lazy_ (fun () ->
              let dune_version = Dune_project.dune_version d.project in
              let+ lib_config = lib_config in
              Foreign_sources.make d.stanzas ~dune_version ~lib_config ~dirs)
          in
          let coq =
            Memo.lazy_ (fun () ->
              Coq_sources.of_dir d.stanzas ~dir ~dirs ~include_subdirs |> Memo.return)
          in
          let subdirs =
            List.map subdirs ~f:(fun { Source_file_dir.dir; path_to_root = _; files } ->
              { kind = Group_part
              ; dir
              ; text_files = files
              ; ml
              ; foreign_sources
              ; mlds = Memo.lazy_ (fun () -> build_mlds_map d.stanzas ~dir ~files)
              ; coq
              })
          in
          let root =
            { kind = Group_root subdirs
            ; dir
            ; text_files = files
            ; ml
            ; foreign_sources
            ; mlds = Memo.lazy_ (fun () -> build_mlds_map d.stanzas ~dir ~files)
            ; coq
            }
          in
          { Standalone_or_root.root
          ; rules
          ; subdirs = Path.Build.Map.of_list_map_exn subdirs ~f:(fun x -> x.dir, x)
          })
    in
    { Standalone_or_root.directory_targets; contents }
  ;;

  let get0_impl (sctx, dir) : triage Memo.t =
    let* status = Dir_status.DB.get ~dir in
    match status with
    | Is_component_of_a_group_but_not_the_root { group_root; stanzas = _ } ->
      Memo.return (Group_part group_root)
    | Generated | Source_only _ ->
      Memo.return @@ Standalone_or_root (Standalone_or_root.empty ~dir)
    | Standalone (st_dir, d) ->
      Memo.return @@ Standalone_or_root (make_standalone sctx st_dir ~dir d)
    | Group_root (st_dir, qualif_mode, d) ->
      let+ group_root = make_group_root sctx st_dir qualif_mode ~dir d in
      Standalone_or_root group_root
  ;;

  let memo0 =
    Memo.create
      "dir-contents-get0"
      get0_impl
      ~input:(module Key)
      ~human_readable_description:(fun (_, dir) ->
        Pp.textf
          "Computing directory contents of %s"
          (Path.to_string_maybe_quoted (Path.build dir)))
  ;;

  let get sctx ~dir =
    Memo.exec memo0 (sctx, dir)
    >>= function
    | Standalone_or_root { directory_targets = _; contents } ->
      let+ { root; rules = _; subdirs = _ } = Memo.Lazy.force contents in
      root
    | Group_part group_root ->
      Memo.exec memo0 (sctx, group_root)
      >>= (function
      | Group_part _ -> assert false
      | Standalone_or_root { directory_targets = _; contents } ->
        let+ { root; rules = _; subdirs = _ } = Memo.Lazy.force contents in
        root)
  ;;

  let triage sctx ~dir = Memo.exec memo0 (sctx, dir)
end

include Load

let modules_of_lib sctx lib =
  let info = Lib.info lib in
  match Lib_info.modules info with
  | External modules -> Memo.return modules
  | Local ->
    let dir = Lib_info.src_dir info |> Path.as_in_build_dir_exn in
    let* t = get sctx ~dir in
    let+ ml_sources = ocaml t in
    let name = Lib.name lib in
    Some (Ml_sources.modules ml_sources ~for_:(Library name))
;;
