open Ppxlib
open Asttypes
open Parsetree
open Ast_helper

module Ast_mapper = Ocaml_common.Ast_mapper

module From_current = Ppxlib_ast.Selected_ast.Of_ocaml
module To_current = Ppxlib_ast.Selected_ast.To_ocaml

let raise_errorf = Ppx_deriving.raise_errorf

let dynlink ?(loc=Location.none) filename =
  let filename = Dynlink.adapt_filename filename in
  try
    Dynlink.loadfile filename
  with Dynlink.Error error ->
    raise_errorf ~loc "Cannot load %s: %s" filename (Dynlink.error_message error)

let init_findlib = lazy (
  Findlib.init ();
  Findlib.record_package Findlib.Record_core "ppx_deriving.api";
)

let load_ocamlfind_package ?loc pkg =
  Lazy.force init_findlib;
  try
    Fl_dynload.load_packages [pkg]
  with Dynlink.Error error ->
    raise_errorf ?loc "Cannot load %s: %s" pkg (Dynlink.error_message error)

let load_plugin ?loc plugin =
  let len = String.length plugin in
  let pkg_prefix = "package:" in
  let pkg_prefix_len = String.length pkg_prefix in
  if len >= pkg_prefix_len &&
     String.sub plugin 0 pkg_prefix_len = pkg_prefix then
    let pkg = String.sub plugin pkg_prefix_len (len - pkg_prefix_len) in
    load_ocamlfind_package ?loc pkg
  else
    dynlink ?loc plugin

let get_plugins () =
  match Ast_mapper.get_cookie "ppx_deriving" with
  | None -> []
  | Some expr ->
      match From_current.copy_expression expr with
      | { pexp_desc = Pexp_tuple exprs } ->
        exprs |> List.map (fun expr ->
          match expr with
          | { pexp_desc = Pexp_constant (Pconst_string (file, None)) } -> file
          | _ -> assert false)
      | _ -> assert false

let add_plugins plugins =
  let loaded  = get_plugins () in
  let plugins = List.filter (fun file -> not (List.mem file loaded)) plugins in
  List.iter load_plugin plugins;
  let loaded  = loaded @ plugins in
  Ast_mapper.set_cookie "ppx_deriving"
    (To_current.copy_expression
       (Exp.tuple (List.map (fun file ->
          Exp.constant (Pconst_string (file, None))) loaded)))

let run_as_ast_mapper =
  Ppxlib.Driver.run_as_ppx
    ~signature:(fun sg ->
      let config = initial_state () in
      rewrite_signature config (module OCaml_current) sg
      |> migrate_some_signature (module OCaml_current)
    )
    ~structure:(fun str ->
      let config = initial_state () in
      rewrite_structure config (module OCaml_current) str
      |> migrate_some_structure (module OCaml_current)
    )

let mapper argv =
  get_plugins () |> List.iter load_plugin;
  add_plugins argv;
  let copy_structure_item item =
    match From_current.copy_structure [item] with
    | [item] -> item
    | _ -> failwith "Ppx_deriving_main.copy_structure_item" in
  let module Current_ast = Ppxlib.Import_for_core.Ocaml in
  let omp_mapper = Migrate_parsetree.Driver.run_as_ast_mapper [] in
  let structure mapper s =
    match s with
    | [] -> []
    | hd :: tl ->
        match
          try Some (copy_structure_item hd)
          with Migrate_parsetree.Def.Migration_error (_, _) -> None
        with
        | Some ([%stri [@@@findlib.ppxopt [%e? { pexp_desc = Pexp_tuple (
            [%expr "ppx_deriving"] :: elems) }]]]) ->
            elems |>
            List.map (fun elem ->
              match elem with
              | { pexp_desc = Pexp_constant (Pconst_string (file, None))} ->
                  file
              | _ -> assert false) |>
            add_plugins;
            mapper.Current_ast.Ast_mapper.structure mapper tl
        | _ -> omp_mapper.Current_ast.Ast_mapper.structure mapper s in
  { omp_mapper with Current_ast.Ast_mapper.structure }

let () =
  Ast_mapper.register "ppx_deriving"
    ~preprocess_impl:map_structure
    ~preprocess_intf:map_signature

let () =
  Ppxlib.Driver.run_as_ppx_rewriter
