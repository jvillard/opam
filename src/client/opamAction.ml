(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2014 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

let log fmt = OpamGlobals.log "ACTION" fmt
let slog = OpamGlobals.slog

open OpamTypes
open OpamFilename.OP
open OpamState.Types
open OpamProcess.Job.Op

module PackageActionGraph = OpamSolver.ActionGraph

(* Install the package files *)
let install_package t nv =
  if !OpamGlobals.dryrun then
      OpamGlobals.msg "Installing %s.\n" (OpamPackage.to_string nv)
  else
  let build_dir = OpamPath.Switch.build t.root t.switch nv in
  if OpamFilename.exists_dir build_dir then OpamFilename.in_dir build_dir (fun () ->

      log "Installing %s.\n" (OpamPackage.to_string nv);
      let name = OpamPackage.name nv in
      let config_f = OpamPath.Switch.build_config t.root t.switch nv in
      let config = OpamFile.Dot_config.safe_read config_f in
      let install_f = OpamPath.Switch.build_install t.root t.switch nv in
      let install = OpamFile.Dot_install.safe_read install_f in

      (* .install *)
      let install_f = OpamPath.Switch.install t.root t.switch name in
      OpamFile.Dot_install.write install_f install;

      (* .config *)
      let dot_config = OpamPath.Switch.config t.root t.switch name in
      OpamFilename.mkdir (OpamFilename.dirname dot_config);
      OpamFile.Dot_config.write dot_config config;

      let warnings = ref [] in
      let check ~src ~dst base =
        let src_file = OpamFilename.create src base.c in
        if base.optional && not (OpamFilename.exists src_file) then
          log "Not installing %a is not present and optional."
            (slog OpamFilename.to_string) src_file;
        if not base.optional && not (OpamFilename.exists src_file) then (
          warnings := (dst, base.c) :: !warnings
        );
        OpamFilename.exists src_file in

      (* Install a list of files *)
      let install_files exec dst_fn files_fn =
        let dst_dir = dst_fn t.root t.switch name in
        let files = files_fn install in
        if not (OpamFilename.exists_dir dst_dir) then (
          log "creating %a" (slog OpamFilename.Dir.to_string) dst_dir;
          OpamFilename.mkdir dst_dir;
        );
        List.iter (fun (base, dst) ->
            let src_file = OpamFilename.create build_dir base.c in
            let dst_file = match dst with
              | None   -> OpamFilename.create dst_dir (OpamFilename.basename src_file)
              | Some d -> OpamFilename.create dst_dir d in
            if check ~src:build_dir ~dst:dst_dir base then
              OpamFilename.install ~exec ~src:src_file ~dst:dst_file ();
          ) files in

      (* bin *)
      install_files true (fun r s _ -> OpamPath.Switch.bin r s) OpamFile.Dot_install.bin;

      (* sbin *)
      install_files true (fun r s _ -> OpamPath.Switch.sbin r s) OpamFile.Dot_install.sbin;

      (* lib *)
      install_files false OpamPath.Switch.lib OpamFile.Dot_install.lib;

      (* toplevel *)
      install_files false (fun r s _ -> OpamPath.Switch.toplevel r s)
        OpamFile.Dot_install.toplevel;

      install_files true (fun r s _ -> OpamPath.Switch.stublibs r s)
        OpamFile.Dot_install.stublibs;

      (* Man pages *)
      install_files false (fun r s _ -> OpamPath.Switch.man_dir r s) OpamFile.Dot_install.man;

      (* Shared files *)
      install_files false OpamPath.Switch.share OpamFile.Dot_install.share;
      install_files false (fun r s _ -> OpamPath.Switch.share_dir r s)
        OpamFile.Dot_install.share_root;

      (* Etc files *)
      install_files false OpamPath.Switch.etc OpamFile.Dot_install.etc;

      (* Documentation files *)
      install_files false OpamPath.Switch.doc OpamFile.Dot_install.doc;

      (* misc *)
      List.iter
        (fun (src, dst) ->
          let src_file = OpamFilename.create (OpamFilename.cwd ()) src.c in
          if OpamFilename.exists dst
          && OpamGlobals.confirm "Overwriting %s ?" (OpamFilename.to_string dst) then
            OpamFilename.install ~src:src_file ~dst ()
          else begin
            OpamGlobals.msg "Installing %s to %s.\n"
              (OpamFilename.Base.to_string src.c) (OpamFilename.to_string dst);
            if OpamGlobals.confirm "Continue ?" then
              OpamFilename.install ~src:src_file ~dst ()
          end
        ) (OpamFile.Dot_install.misc install);

      if !warnings <> [] then (
        let print (dir, base) =
          Printf.sprintf "  - %s to %s\n"
            (OpamFilename.to_string (OpamFilename.create build_dir base))
            (OpamFilename.Dir.to_string dir) in
        OpamGlobals.error "Installation of %s failed"
          (OpamPackage.to_string nv);
        let msg =
          Printf.sprintf
            "Some files in %s couldn't be installed:\n%s"
            (OpamFilename.prettify install_f)
            (String.concat "" (List.map print !warnings))
        in
        failwith msg
      )
    );
  if not (!OpamGlobals.keep_build_dir || !OpamGlobals.debug) then
    OpamFilename.rmdir build_dir

(* Prepare the package build:
   * apply the patches
   * substitute the files *)
let prepare_package_build t nv =
  let opam = OpamState.opam t nv in

  (* Substitute the patched files.*)
  let patches = OpamFile.OPAM.patches opam in

  let iter_patches f =
    List.fold_left (fun acc (base, filter) ->
        if OpamState.eval_filter t ~opam OpamVariable.Map.empty filter then
          try f base; acc
          with e -> OpamMisc.fatal e; OpamFilename.Base.to_string base :: acc
        else acc
      ) [] patches in

  if !OpamGlobals.dryrun || !OpamGlobals.fake then
    ignore (iter_patches (fun base ->
        log "%s: applying %s.\n" (OpamPackage.name_to_string nv)
          (OpamFilename.Base.to_string base)))
  else

  let p_build = OpamPath.Switch.build t.root t.switch nv in

  OpamFilename.mkdir p_build;
  OpamFilename.in_dir p_build (fun () ->
    let all = OpamFile.OPAM.substs opam in
    let patches =
      OpamMisc.filter_map (fun (f,_) ->
        if List.mem f all then Some f else None
      ) patches in
    List.iter (OpamState.substitute_file t ~opam OpamVariable.Map.empty) patches
  );

  (* Apply the patches *)
  let patching_errors =
    iter_patches (fun base ->
      let root = OpamPath.Switch.build t.root t.switch nv in
      let patch = root // OpamFilename.Base.to_string base in
      log "%s: applying %s.\n" (OpamPackage.name_to_string nv)
        (OpamFilename.Base.to_string base);
      OpamFilename.patch patch p_build)
  in

  (* Substitute the configuration files. We should be in the right
     directory to get the correct absolute path for the
     substitution files (see [substitute_file] and
     [OpamFilename.of_basename]. *)
  OpamFilename.in_dir p_build (fun () ->
    List.iter (OpamState.substitute_file t ~opam OpamVariable.Map.empty)
      (OpamFile.OPAM.substs opam)
  );
  if patching_errors <> [] then (
    let msg =
      Printf.sprintf "These patches didn't apply at %s:\n  - %s\n"
        (OpamFilename.Dir.to_string (OpamPath.Switch.build t.root t.switch nv))
        (String.concat "\n  - " patching_errors)
    in
    failwith msg
  )

let download_package t nv =
  log "download_package: %a" (slog OpamPackage.to_string) nv;
  let name = OpamPackage.name nv in
  if !OpamGlobals.dryrun || !OpamGlobals.fake then Done (`Successful None) else
  let dir =
    try match OpamPackage.Name.Map.find name t.pinned with
      | Version _ -> Some (OpamPath.dev_package t.root nv)
      | _ -> Some (OpamPath.Switch.dev_package t.root t.switch name)
    with Not_found -> None
  in
  let of_dl = function
    | Some (Up_to_date f | Result f) -> `Successful (Some f)
    | Some (Not_available _) -> `Error ()
    | None -> `Successful None
  in
  let job = match dir with
    | Some dir ->
      OpamState.download_upstream t nv dir @@| of_dl
    | None ->
      OpamState.download_archive t nv @@+ function
      | Some f ->
        assert (f = OpamPath.archive t.root nv);
        Done (`Successful (Some (F f)))
      | None ->
        let dir = OpamPath.dev_package t.root nv in
        OpamState.download_upstream t nv dir @@| of_dl
  in
  OpamProcess.Job.ignore_errors ~default:(`Error ()) job @@| function
  | `Error () ->
    OpamGlobals.error "Could not get source of %s" (OpamPackage.to_string nv);
    `Error ()
  | success -> success

let extract_package t source nv =
  log "extract_package: %a from %a"
    (slog OpamPackage.to_string) nv
    (slog (OpamMisc.Option.to_string OpamTypesBase.string_of_generic_file))
    source;
  if !OpamGlobals.dryrun then () else
  let build_dir = OpamPath.Switch.build t.root t.switch nv in
  OpamFilename.rmdir build_dir;
  let () =
    match source with
    | None -> ()
    | Some (D dir) -> OpamFilename.copy_dir ~src:dir ~dst:build_dir
    | Some (F archive) -> OpamFilename.extract archive build_dir
  in
  let is_repackaged_archive =
    Some (F (OpamPath.archive t.root nv)) = source
  in
  if not is_repackaged_archive then OpamState.copy_files t nv build_dir;
  prepare_package_build t nv

let string_of_commands commands =
  let commands_s = List.map (fun cmd -> String.concat " " cmd)  commands in
  "  "
  ^ if commands_s <> [] then
    String.concat "\n  " commands_s
  else
    "Nothing to do."

let compilation_env t opam =
  let env0 = OpamState.get_full_env ~opam ~force_path:true t in
  let env1 = [
    ("MAKEFLAGS", "");
    ("MAKELEVEL", "");
    ("OPAM_PACKAGE_NAME", OpamPackage.Name.to_string (OpamFile.OPAM.name opam));
    ("OPAM_PACKAGE_VERSION", OpamPackage.Version.to_string (OpamFile.OPAM.version opam))
  ] @ env0 in
  OpamState.add_to_env t ~opam env1 (OpamFile.OPAM.build_env opam)

let get_metadata t =
  let compiler =
    if t.compiler = OpamCompiler.system then
      let system_version = match OpamCompiler.Version.system () with
        | None   -> "<none>"
        | Some v -> OpamCompiler.Version.to_string v in
      Printf.sprintf "system (%s)" system_version
    else
      OpamCompiler.to_string t.compiler in
  [
    ("compiler", compiler);
  ]

let update_metadata t ~installed ~installed_roots ~reinstall =
  let installed_roots = OpamPackage.Set.inter installed_roots installed in
  let reinstall = OpamPackage.Set.inter installed_roots reinstall in (* XXX why _roots ? *)
  if not !OpamGlobals.dryrun then (
  OpamFile.Installed.write
    (OpamPath.Switch.installed t.root t.switch)
    installed;
  OpamFile.Installed_roots.write
    (OpamPath.Switch.installed_roots t.root t.switch)
    installed_roots;
  OpamFile.Reinstall.write
    (OpamPath.Switch.reinstall t.root t.switch)
    reinstall
  );
  {t with installed; installed_roots; reinstall}

let removal_needs_download t nv =
  match OpamState.opam_opt t nv with
  | None ->
    OpamGlobals.warning
      "No opam file found to remove package %s. Stale files may remain."
      (OpamPackage.to_string nv);
    false
  | Some opam ->
    if List.mem LightUninstall (OpamFile.OPAM.flags opam) then true
    else
    let commands =
      OpamState.filter_commands t ~opam
        OpamVariable.Map.empty (OpamFile.OPAM.remove opam) in
    (* We use a small hack: if the remove command is simply
       'ocamlfind remove xxx' then, no need to extract the archive
       again. *)
    let use_ocamlfind = function
      | [] -> true
      | "ocamlfind" :: _ -> true
      | _ -> false in
    not (List.for_all use_ocamlfind commands)

(* Remove a given package *)
(* This will be done by the parent process, so theoritically we are
   allowed to modify the global state of OPAM here. However, for
   consistency reasons, this is done in the main function only. *)
let remove_package_aux t ~metadata ?(keep_build=false) ?(silent=false) nv =
  log "Removing %a (%b)" (slog OpamPackage.to_string) nv metadata;
  let name = OpamPackage.name nv in

  (* Run the remove script *)
  let opam = OpamState.opam_opt t nv in

  let dot_install = OpamPath.Switch.install t.root t.switch name in

  let remove_job =
    match opam with
    | None      -> OpamGlobals.msg "No OPAM file has been found!\n"; Done ()
    | Some opam ->
      let env = compilation_env t opam in
      let p_build = OpamPath.Switch.build t.root t.switch nv in
      (* We try to run the remove scripts in the folder where it was
         extracted If it does not exist, we try to download and
         extract the archive again, if that fails, we don't really
         care. *)
      let remove = OpamState.filter_commands t ~opam
          OpamVariable.Map.empty (OpamFile.OPAM.remove opam) in
      let name = OpamPackage.Name.to_string name in
      let exec_dir, nameopt =
        if OpamFilename.exists_dir p_build
        then p_build, Some name
        else t.root , None in
      (* if remove <> [] || not (OpamFilename.exists dot_install) then *)
      (*   OpamGlobals.msg "%s\n" (string_of_commands remove); *)
      let metadata = get_metadata t in
      if !OpamGlobals.dryrun then Done ()
      else
      let commands =
        OpamMisc.filter_map (function
            | [] -> None
            | cmd::args ->
              let text = OpamProcess.make_command_text name ~args cmd in
              Some
                (OpamSystem.make_command ?name:nameopt ~metadata ~text cmd args
                   ~env:(OpamFilename.env_of_list env)
                   ~dir:(OpamFilename.Dir.to_string exec_dir)))
          remove
      in
      OpamProcess.Job.of_list ~keep_going:true commands
      @@+ function
      | Some (_,err) ->
        if not silent then
          OpamGlobals.warning
            "failure in package uninstall script, some files may remain:\n%s"
            (OpamProcess.string_of_result err);
        Done ()
      | None -> Done ()
  in

  let install =
    OpamFile.Dot_install.safe_read dot_install in

  let remove_files dst_fn files =
    let files = files install in
    let dst_dir = dst_fn t.root t.switch in
    List.iter (fun (base, dst) ->
        let dst_file = match dst with
          | None   -> dst_dir // Filename.basename (OpamFilename.Base.to_string base.c)
          | Some b -> OpamFilename.create dst_dir b in
        OpamFilename.remove dst_file
      ) files in

  let remove_files_and_dir dst_fn files =
    let dir = dst_fn t.root t.switch name in
    remove_files (fun _ _ -> dir) files;
    if OpamFilename.rec_files dir = [] then OpamFilename.rmdir dir
    else if OpamFilename.exists_dir dir then
      OpamGlobals.warning "Directory %s is not empty, not removing"
        (OpamFilename.Dir.to_string dir) in

  let uninstall_files () =
    (* Remove build/<package> *)
    if not (keep_build || !OpamGlobals.keep_build_dir) then
      OpamFilename.rmdir (OpamPath.Switch.build t.root t.switch nv);

    (* Remove .config and .install *)
    log "Removing config and install files";
    OpamFilename.remove (OpamPath.Switch.install t.root t.switch name);
    OpamFilename.remove (OpamPath.Switch.config t.root t.switch name);

    log "Removing files from .install";
    remove_files OpamPath.Switch.sbin OpamFile.Dot_install.sbin;
    remove_files OpamPath.Switch.bin OpamFile.Dot_install.bin;
    remove_files_and_dir OpamPath.Switch.lib OpamFile.Dot_install.lib;
    remove_files OpamPath.Switch.stublibs OpamFile.Dot_install.stublibs;
    remove_files_and_dir OpamPath.Switch.share OpamFile.Dot_install.share;
    remove_files OpamPath.Switch.share_dir OpamFile.Dot_install.share_root;
    remove_files_and_dir OpamPath.Switch.etc OpamFile.Dot_install.etc;
    remove_files OpamPath.Switch.man_dir OpamFile.Dot_install.man;
    remove_files_and_dir OpamPath.Switch.doc OpamFile.Dot_install.doc;

    (* Remove the misc files *)
    log "Removing the misc files";
    List.iter (fun (_,dst) ->
        if OpamFilename.exists dst then begin
          OpamGlobals.msg "Removing %s." (OpamFilename.to_string dst);
          if OpamGlobals.confirm "Continue ?" then
            OpamFilename.remove dst
        end
      ) (OpamFile.Dot_install.misc install);

    (* Cleanup if there was any stale overlay (unpinned but left installed
       package) *)
    if not (OpamState.is_pinned t name) then
      OpamState.remove_overlay t name;
  in

  let cleanup_meta () =
    (* Update the metadata *)
    let installed = OpamPackage.Set.remove nv t.installed in
    let installed_roots = OpamPackage.Set.remove nv t.installed_roots in
    let reinstall = OpamPackage.Set.remove nv t.reinstall in
    ignore (update_metadata t ~installed ~installed_roots ~reinstall)
  in
  remove_job @@+ fun () ->
  if not !OpamGlobals.dryrun then uninstall_files ();
  if metadata then cleanup_meta ();
  if not silent then
    OpamGlobals.msg "%s removed   %s.%s\n"
      (if not !OpamGlobals.utf8 then "->"
       else OpamActionGraph.(action_color `rm (action_strings `rm)))
      (OpamGlobals.colorise `bold (OpamPackage.name_to_string nv))
      (OpamPackage.version_to_string nv);
  Done ()


(* Removes build dir and source cache of package if unneeded *)
let cleanup_package_artefacts t nv =
  log "Cleaning up artefacts of %a" (slog OpamPackage.to_string) nv;

  let build_dir = OpamPath.Switch.build t.root t.switch nv in
  if not !OpamGlobals.keep_build_dir && OpamFilename.exists_dir build_dir then
    OpamFilename.rmdir build_dir;
  let name = OpamPackage.name nv in
  let dev_dir = OpamPath.Switch.dev_package t.root t.switch name in
  if not (OpamState.is_package_installed t nv) then (
    if OpamFilename.exists_dir dev_dir then (
      log "Cleaning-up the switch repository";
      OpamFilename.rmdir dev_dir );
    log "Removing the local metadata";
    OpamState.remove_metadata t (OpamPackage.Set.singleton nv);
  );

  (* Remove the dev archive if no switch uses the package anymore *)
  let dev = OpamPath.dev_package t.root nv in
  if OpamFilename.exists_dir dev &&
     not (OpamPackage.Set.mem nv (OpamState.all_installed t)) then (
    log "Removing %a" (slog OpamFilename.Dir.to_string) dev;
    OpamFilename.rmdir dev;
  )

let sources_needed t g =
  PackageActionGraph.fold_vertex (fun act acc ->
      match act with
      | To_delete nv ->
        if removal_needs_download t nv
        then OpamPackage.Set.add nv acc else acc
      | To_change (None,nv) | To_recompile nv ->
        OpamPackage.Set.add nv acc
      | To_change (Some nv1, nv2) ->
        let acc = OpamPackage.Set.add nv2 acc in
        if removal_needs_download t nv1
        then OpamPackage.Set.add nv1 acc else acc)
    g OpamPackage.Set.empty

let remove_package t ~metadata ?keep_build ?silent nv =
  if !OpamGlobals.fake || !OpamGlobals.show then
    Done (OpamGlobals.msg "Would remove: %s.\n" (OpamPackage.to_string nv))
  else
    remove_package_aux t ~metadata ?keep_build ?silent nv

(* Build and install a package.
   Assumes the package has already been downloaded to its build dir.
*)
let build_and_install_package_aux t ~metadata:save_meta source nv =
  (* OpamGlobals.header_msg "Installing %s" (OpamPackage.to_string nv); *)

  extract_package t source nv;

  let opam = OpamState.opam t nv in
  let commands =
    OpamFile.OPAM.build opam @
    (if !OpamGlobals.build_test then OpamFile.OPAM.build_test opam else []) @
    (if !OpamGlobals.build_doc then OpamFile.OPAM.build_doc opam else []) @
    OpamFile.OPAM.install opam
  in
  let commands =
    OpamState.filter_commands t ~opam OpamVariable.Map.empty commands
  in
  let env = OpamFilename.env_of_list (compilation_env t opam) in
  let name = OpamPackage.name_to_string nv in
  let metadata = get_metadata t in
  let dir = OpamPath.Switch.build t.root t.switch nv in
  let rec run_commands = function
    | (cmd::args)::commands ->
      let text = OpamProcess.make_command_text name ~args cmd in
      let dir = OpamFilename.Dir.to_string dir in
      OpamSystem.make_command ~env ~name ~metadata ~dir ~text cmd args
      @@> fun result ->
      if OpamProcess.is_success result then
        run_commands commands
      else (
        OpamGlobals.error
          "The compilation of %s failed at %S."
          name (String.concat " " (cmd::args));
        remove_package ~metadata:false t ~keep_build:true ~silent:true nv
        @@| fun () -> Some (OpamSystem.Process_error result)
      )
    | []::commands -> run_commands commands
    | [] ->
      try
        install_package t nv;
        if save_meta then (
          let installed = OpamPackage.Set.add nv t.installed in
          let installed_roots = OpamPackage.Set.add nv t.installed_roots in
          let reinstall = OpamPackage.Set.remove nv t.reinstall in
          let t = update_metadata t ~installed ~installed_roots ~reinstall in
          OpamState.install_metadata t nv;
        );
        OpamGlobals.msg "%s installed %s.%s\n"
          (if not !OpamGlobals.utf8 then "->"
           else OpamActionGraph.(action_color `inst (action_strings `inst)))
          (OpamGlobals.colorise `bold name)
          (OpamPackage.version_to_string nv);
        Done None
      with e -> OpamMisc.fatal e; Done (Some e)
  in
  if !OpamGlobals.dryrun then
    Done (OpamProcess.Job.dry_run (run_commands commands))
  else
    run_commands commands

let build_and_install_package t ~metadata source nv =
  if not !OpamGlobals.fake then
    build_and_install_package_aux t ~metadata source nv
  else
    (OpamGlobals.msg "(simulation) Building and installing %s.\n"
       (OpamPackage.to_string nv);
     Done None)
