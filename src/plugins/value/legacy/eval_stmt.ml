(* Modified by TrustInSoft *)

(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2007-2015                                               *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Cil_types
open Cil_datatype
open Cil
open Locations
open Abstract_interp
open Cvalue
open Value_util
open Eval_exprs

(* Forward reference to [Eval_funs.compute_call] *)
let compute_call_ref = ref (fun _ -> assert false)

(* Fold on all offsets of a given type (i.e. offsets of all fields / indices,
   descending recursively into the type's structure) in the correct order
   (i.e. how they are arranged in memory). *)
let rec fold_typ_offsets (f : 'a -> offset -> 'a) (acc : 'a) (typ : typ) : 'a =
  match typ with

  (* A structure: fold on all the fields... *)
  | TComp ({cstruct=true} as compinfo, _, _) ->
    begin
      let fields : fieldinfo list = compinfo.cfields in
      List.fold_left
        (fun (acc : 'a) (field : fieldinfo) ->
           let field_typ : typ = field.ftype in
           fold_typ_offsets
             (fun acc offset ->
                let offset' = Field(field, offset) in
                f acc offset')
             acc
             field_typ)
        acc
        fields
    end

  (* An array: fold on all the indices... *)
  | TArray (cell_typ, arr_length_exp_option, _, _) ->
    begin
      let arr_length : int =
        try lenOfArray arr_length_exp_option
        with LenOfArray -> 0
      in
      let rec fold_on_indices (acc : 'a) (index : int) =
        if index < arr_length
        then
          let acc =
            fold_typ_offsets
              (fun acc offset ->
                 (* TODO: Find something better than builtinLoc ... *)
                 let offset' =
                   let index_exp =
                     kinteger64 ~loc:builtinLoc (Int.of_int index)
                   in
                   Index(index_exp, offset)
                 in
                 f acc offset')
              acc
              cell_typ
          in
          fold_on_indices acc (index + 1)
        else
          acc
      in
      fold_on_indices acc 0
    end

  (* Any other type: it has no internal structure, so building the offset
     ends here. *)
  | _ -> f acc NoOffset


(* Field's (or padding's) offset and size in bits. *)
type offset_and_size = int * int

type field_or_padding =
  | Field   of offset_and_size
  | Padding of offset_and_size

(* Fold on all fields and paddings between fields (i.e. offsets and sizes of all
   the fields / paddings) of a given type in the order that they are stored in
   memory. *)
let fold_typ_fields_and_paddings
    (f : 'a -> field_or_padding -> 'a) (acc : 'a) (typ : typ) : 'a =

  (* The structure field's offset-and-size-in-bits folding function.
     + The first argument, i.e. the accumulator, is a pair:
       - the top-level (field-and-padding-level) accumulator,
       - one offset after the previously treated field's last offset.
     + The second argument is the first offset and the size of the currently
       treated field.
     + The result is a pair:
       - the new field-and-padding-level accumulator,
       - the offset after the current field's last offset. *)
  let offset_and_size_f
      (acc, prev_after_last_offset        : 'a * int)
      (current_first_offset, current_size : offset_and_size)
    : 'a * int =

    (* The previous field must have ended before the current field begins... *)
    assert (prev_after_last_offset <= current_first_offset);

    (* Compute the first offset and the size of potential padding (i.e padding
       between the previous field and the current one). *)
    let padding_first_offset = prev_after_last_offset in
    let padding_size = current_first_offset - padding_first_offset in
    assert (padding_size >= 0);

    (* Treat padding if it exists. *)
    let acc =
      (* Is there padding between the previous field and the current one? *)
      if padding_size > 0
      then
        (* There is some padding: call the field-and-padding-level
           folding function. *)
        let padding = Padding (padding_first_offset, padding_size) in
        f acc padding
      else
        (* There is no padding: just pass on the field-and-padding-level
           accumulator unchanged. *)
        acc
    in

    (* Treat the current field if it exists. *)
    let acc =
      (* Zero size means it's a dummy field. *)
      if current_size > 0
      then
        let field = Field (current_first_offset, current_size) in
        f acc field
      else
        acc
    in

    (* Pass a pair:
       - the field-and-padding-level accumulator,
       - and the offset after the current field's last offset
       in the offset-and-size-level accumulator. *)
    let current_after_last_offset = current_first_offset + current_size in
    acc, current_after_last_offset
  in

  (* Fold on all the structure fields' offsets-and-sizes. *)
  let (acc, after_last_offset : 'a * int) =
    try
      fold_typ_offsets
        (fun (acc' : 'a * int) (offset : offset) ->
           offset_and_size_f acc' (bitsOffset typ offset))
        (acc, 0)
        typ
    with SizeOfError _ -> assert false (* Should not happen if the assignment
                                          [lval1 = lval2;] was accepted during
                                          typing phase. *)
  in

  (* Finish with an artificial offset-and-size of a dummy field positioned right
     after the structure, so that the potential padding after the structure's
     last field is taken into account. *)
  let (acc, _) : ('a * int) =
    try
      offset_and_size_f (acc, after_last_offset) (bitsSizeOf typ, 0)
    with SizeOfError _ -> assert false (* Should not happen if the assignment
                                          [lval1 = lval2;] was accepted during
                                          typing phase. *)
  in

  (* Folding done! *)
  acc

(* Fold on all paddings between fields (i.e. offsets and sizes of all the
   paddings) of a given type. *)
let fold_typ_paddings (f : 'a -> offset_and_size -> 'a) : 'a -> typ -> 'a =
  fold_typ_fields_and_paddings
    (fun acc -> function
       | Field   _               -> acc
       | Padding offset_and_size -> f acc offset_and_size)

(* Uninitialize all the padding in an offsetmap of the given type. *)
let make_padding_uninitialized (offsetmap : V_Offsetmap.t) (typ : typ) =

  match typ with
  | TComp ({cstruct=true} as _compinfo, _, _) ->

    let uninitialize_offsetmap_on_offset_and_size :
      V_Offsetmap.t -> offset_and_size -> V_Offsetmap.t =

      (* The validity covers the whole offsetmap. *)
      let validity : Base.validity =
        let validity_start : Int.t = Int.zero in
        let validity_end   : Int.t =
          try Int.of_int ((bitsSizeOf typ) - 1)
          with SizeOfError _ -> assert false (* Should not happen if the
                                                assignment [lval1 = lval2;] was
                                                accepted during typing phase.*)
        in
        Base.Known (validity_start, validity_end)
      in

      fun offsetmap (offset, size) ->

        (* Translate the description of the offsetmap's area to uninitialize
           to right types. *)
        let offsets : Ival.t = Ival.of_int offset in
        let size    : Int.t  = Int.of_int size in

        (* Perform the uninitialization. *)
        let _alarm, offsetmap_or_bottom =
          V_Offsetmap.update_uninitialize ~validity ~offsets ~size offsetmap
        in

        (* Post-treatment of the uninitialization result. *)
        match offsetmap_or_bottom with
        | `Bottom        -> assert false (* Should not happen. *)
        | `Map offsetmap -> offsetmap
    in

    fold_typ_paddings uninitialize_offsetmap_on_offset_and_size offsetmap typ

  | _ -> offsetmap

  exception Do_assign_imprecise_copy

  (* Assigns [exp] to [lv] in [state]. [typ_lv] is the type if [lv]. [left_loc]
     is one of the locations [lv] evaluates to. Returns [state] modified by
     the assignment, and whether [left_loc] was at least partially valid.
     If [warn_indeterminate] is [true], indetermine values inside [exp] are
     caught, signaled to the user, and removed. *)
  let do_assign_one_loc ~with_alarms clob ~warn_indeterminate state lv typ_lv exp left_loc =
    let state, left_loc =
      if Locations.is_bottom_loc left_loc then
        Model.bottom, left_loc
      else
        Eval_exprs.warn_reduce_by_accessed_loc ~with_alarms
          ~for_writing:true state left_loc lv
    in
    if not (Cvalue.Model.is_reachable state) then (state, false)
    else
    (* First mode, used when [exp] is not a lval, when a conversion is
       needed between [exp] and [lv], or as backup *)
    let default () =
      let state, _, v =
        Eval_non_linear.eval_expr_with_deps_state ~with_alarms None state exp
      in
      Locals_scoping.remember_if_locals_in_value clob left_loc v;
      Warn.warn_right_exp_imprecision ~with_alarms lv left_loc v;
      if Cvalue.V.is_bottom v ||
        Locations.is_bottom_loc left_loc  ||
        not (Cvalue.Model.is_reachable state)
      then Cvalue.Model.bottom
      else Eval_op.write_abstract_value ~with_alarms state lv typ_lv left_loc v
    in
    (* More precise copy, in case exp is in fact an lval (and has a known size).
       We copy the entire lval in one operation. This is typically useful for
       struct assignment *)
    let right_is_lval exp_lv =
      (* Copy one location to which [exp_lv] points to, in [state] *)
      let aux_one_loc right_loc state =
        let state, right_loc =
          Eval_exprs.warn_reduce_by_accessed_loc ~with_alarms
            ~for_writing:false state right_loc exp_lv
        in
        (* Warn if right_loc is imprecise *)
        Warn.warn_imprecise_lval_read ~with_alarms
          exp_lv right_loc (* Dummy value:*)V.bottom;
        (* Warn if both sides overlap *)
        Warn.warn_overlap ~with_alarms (lv, left_loc) (exp_lv, right_loc);
        if not (Cvalue.Model.is_reachable state)
        then Cvalue.Model.bottom
        else begin
          (* top size is tested before this function is called, in which case
             the imprecise copy mode is used *)
          let size = Int_Base.project right_loc.size in
          Valarms.set_syntactic_context (Valarms.SyMem exp_lv);
          let offsetmap =
            Eval_op.copy_offsetmap ~with_alarms right_loc.loc size state
          in
          let make_volatile = 
            typeHasQualifier "volatile" typ_lv  ||
            typeHasQualifier "volatile" (Cil.typeOfLval exp_lv)
          in
          let offsetmap_state = match offsetmap with
            | `Map o ->
              let o =
                (* TODO: this is the good place to handle partially volatile
                   struct, whether as source or destination *)
                if make_volatile then begin
                  V_Offsetmap.map_on_values
                    (V_Or_Uninitialized.map Eval_op.make_volatile) o
                end else o
              in
              if not (Eval_typ.offsetmap_matches_type typ_lv o) then
                raise Do_assign_imprecise_copy;
              (* Warn for unitialized/escaping addresses. May return bottom
                 when a part of the offsetmap contains no value. *)
              if warn_indeterminate then
                Warn.warn_reduce_indeterminate_offsetmap
                  ~with_alarms typ_lv o (`Loc right_loc) state
              else `Res (o, state)
            | `Top -> Warn.warn_top ();
            | `Bottom -> `Bottom
          in
          match offsetmap_state with
            | `Bottom -> Model.bottom
            | `Res (offsetmap, state) ->
              let offsetmap = make_padding_uninitialized offsetmap typ_lv in
              Locals_scoping.remember_if_locals_in_offsetmap
                clob left_loc offsetmap;
              (match Warn.offsetmap_contains_imprecision offsetmap with
                | Some v ->
                  Warn.warn_right_exp_imprecision ~with_alarms lv left_loc v
                | _ -> ());
              Valarms.set_syntactic_context (Valarms.SyMem lv);
              Eval_op.paste_offsetmap ~reducing:false ~with_alarms
                ~from:offsetmap ~dst_loc:left_loc.loc ~size ~exact:true state
        end
      in
      if Locations.is_bottom_loc left_loc
        || not (Cvalue.Model.is_reachable state)
      then Model.bottom
      else
        let state, p_right_loc, _ =
          lval_to_precise_loc_state ~with_alarms state exp_lv
        in
        if Model.is_reachable state then
          (* Size mismatch between left and right size, or imprecise size.
             This cannot be done by copies, but require a conversion *)
          let size = Precise_locs.loc_size p_right_loc in
          if not (Int_Base.equal size left_loc.size) || Int_Base.is_top size
          then raise Do_assign_imprecise_copy;
          let aux loc acc_state =
            Model.join acc_state (aux_one_loc loc state)
          in
          Precise_locs.fold aux p_right_loc Model.bottom
        else
          Model.bottom
    in
    let state_res =
      try
        if Eval_typ.is_bitfield_or__Bool typ_lv
        then default ()
        else
          (* An lval assignement might be hidden by a dummy cast *)
          let exp_lv = find_lv state exp in
          right_is_lval exp_lv
      with Cannot_find_lv | Do_assign_imprecise_copy -> default ()
    in
    state_res, not (Locations.is_bottom_loc left_loc)

  (* Evaluate a location with the intent of writing in it. Signal an error
     if the lvalue is constant *)
  let lval_to_precise_loc_state_for_writing ~with_alarms state lv =
    let (_, _, typ as r) = lval_to_precise_loc_state ~with_alarms state lv in
    if Value_util.is_const_write_invalid typ then begin
      Valarms.set_syntactic_context (Valarms.SyMem lv);
      Valarms.warn_mem_write with_alarms;
      Model.bottom, Precise_locs.loc_bottom, typ
    end else
      r

  (* Assigns [exp] to [lv] in [state] *)
  let do_assign ~with_alarms kf clob state lv exp =
    assert (Cvalue.Model.is_reachable state);
    let state, precise_left_loc, typ_lv =
      lval_to_precise_loc_state_for_writing ~with_alarms state lv
    in
    let warn_indeterminate = Value_util.warn_indeterminate kf in
    let aux_loc loc (acc_state, acc_non_bottom_loc) =
      let state', non_bottom_loc =
        do_assign_one_loc ~with_alarms
          clob ~warn_indeterminate state lv typ_lv exp loc
      in
      Model.join acc_state state', non_bottom_loc || acc_non_bottom_loc
    in
    let res, non_bottom_loc =
      Precise_locs.fold aux_loc precise_left_loc (Model.bottom, false)
    in
    if not non_bottom_loc then
      Valarms.do_warn with_alarms.CilE.imprecision_tracing
        (fun () -> Kernel.warning ~current:true ~once:true
          "@[<v>@[all target addresses were invalid. This path is \
              assumed to be dead.@]%t@]" pp_callstack
        );
    res

  (* This functions stores the result of call, represented by offsetmap
     [return], into [lv]. It is not trivial because we must handle the
     possibility of casts between the type of the result [rettyp] and the type
     of [lv]. With option [-no-collapse-call-cast], we only need the first part
     of the function. This function handles one possible location in [lv]. *)
  let assign_return_to_lv_one_loc ~with_alarms clob rettype (lv, loc, lvtyp) return state =
    let state, loc =
      Eval_exprs.warn_reduce_by_accessed_loc ~with_alarms
        ~for_writing:true state loc lv
    in
    if Locations.is_bottom_loc loc then
      state
    else
      if not (Eval_typ.is_bitfield lvtyp) &&
         not (Eval_typ.need_cast lvtyp rettype)
      then
        (* Direct paste *)
        let size = Int_Base.project loc.size in
        Valarms.set_syntactic_context (Valarms.SyMem lv);
        let result =
          Eval_op.paste_offsetmap ~with_alarms ~reducing:false
            ~from:return ~dst_loc:loc.loc ~size ~exact:true state
        in
        Locals_scoping.remember_if_locals_in_offsetmap clob loc return;
        result
      else (* Size mismatch. We read then cast the returned value *)
        let size = Int.of_int (bitsSizeOf rettype) in
        let validity = Base.validity_from_size size in
        let alarm, value_with_init =
          V_Offsetmap.find ~validity ~offsets:Ival.zero ~size return
        in
        if alarm then Valarms.warn_mem_read with_alarms;
        let value = V_Or_Uninitialized.get_v value_with_init in
        (* Cf. bts #997 and #1024 for the syntactic context below *)
        Valarms.set_syntactic_context Valarms.SyCallResult;
        let evaled_exp = Eval_op.reinterpret ~with_alarms rettype value in
        ignore (Warn.maybe_warn_indeterminate ~with_alarms value_with_init);
        (* Type of [lv] and [return] might differ, perform a cast (bug #798) *)
        let v_exp =
          let msg fmt =
            Format.fprintf fmt "call result (%a)" V.pretty evaled_exp
          in
          Eval_op.do_promotion ~with_alarms (get_rounding_mode())
            ~src_typ:rettype ~dst_typ:lvtyp evaled_exp msg
        in
        Locals_scoping.remember_if_locals_in_value clob loc v_exp;
        Eval_op.write_abstract_value ~with_alarms state lv lvtyp loc v_exp

  (* Same as function above, but for multiple locations. *)
  let assign_return_to_lv ~with_alarms clob rettype (lv, ploc, lvtyp) return state =
    let aux loc acc_state =
      let state =
        assign_return_to_lv_one_loc ~with_alarms
          clob rettype (lv, loc, lvtyp) return state
      in
      Model.join acc_state state
    in
    Precise_locs.fold aux ploc Model.bottom

  (*  This function unbinds [formals] in [state]. Also, when possible, given
      a formal [f], it reduces the corresponding actual [act_f] to the value
      of [f] in [state]. It it is used after a call to clean up the state,
      and to gain some informations on the actuals.  *)
  let reduce_actuals_by_formals formals actuals state =
    let cleanup acc _exp v =
      let b = Base.of_varinfo v in
      Cvalue.Model.remove_base b acc
    in
    Function_args.fold_left2_best_effort cleanup state actuals formals

  let interp_call ~with_alarms clob stmt lval_to_assign funcexp argl state =
    let cacheable = ref Value_types.Cacheable in
    let call_site_loc = CurrentLoc.get () in
    try
        let functions, _ = resolv_func_vinfo ~with_alarms None state funcexp in
        let caller = current_kf (), stmt in
        (* Remove bottom state from results, assigns result to retlv *)
        let treat_one_result formals res (return, state) =
          if not (Cvalue.Model.is_reachable state)
          then res
          else
            let state = reduce_actuals_by_formals formals argl state in
            match lval_to_assign with
              | None -> state :: res
              | Some lv ->
                let state, ploc, typlv =
                  lval_to_precise_loc_state_for_writing ~with_alarms state lv
                in
                let return = 
		  ( match return with
		    None ->
		      Value_parameters.abort ~current:true ~once:true 
			"Return value expected but none present. Did you misuse a builtin?"
		  | Some return -> return )
		in
                let rettype = getReturnType (typeOf funcexp) in  
                let state =
                  assign_return_to_lv ~with_alarms
                    clob rettype (lv, ploc, typlv) return state
                in
                state :: res
        in
        (* For pointer calls, we retro-propagate which function is being called
           in the abstract state. This may be useful:
           - inside the call for langages with OO (think 'self')
           - everywhere, because we may remove invalid values for the pointer
           - after if enough slevel is available, as states obtained in
             different functions are not merged by default. *)
        let by_ptr = match funcexp.enode with
          | Lval (Var _,NoOffset) -> None
          | Lval (Mem v, NoOffset) -> Some v
          | _ -> assert false
        in
        let treat_one_function f acc_rt_res =
          try
            let state = match by_ptr with
              | None -> state
              | Some exp_f -> (* the call is [( *exp_f)(...)] *)
                let vi_f = Kernel_function.get_vi f in
                (* Build the expression [exp_f == &f] and reduce accordingly *)
                let addr = Cil.mkAddrOfVi vi_f in
                let exp = Cil.mkBinOp ~loc:exp_f.eloc Eq exp_f addr in
                let cond = { exp; positive = true} in
                Eval_exprs.reduce_by_cond state cond
            in
            Value_results.add_kf_caller f ~caller;
            let call_kinstr = Kstmt stmt in
            let recursive = not (Warn.check_no_recursive_call f) in
            (* Warn for arguments that contain uninitialized/escaping if:
               - kf is a non-special leaf function (TODO: should we keep this?)
               - the user asked for this *)
            let warn_indeterminate =
              not
                (Kernel_function.is_definition f (* Should we keep this? *)
                 || let name = Kernel_function.get_name f in
                 (name >= "Frama_C" && name < "Frama_D")
                 || Builtins.mem_builtin name)
              || Value_util.warn_indeterminate f
            in
            let aux_actual e (state, actuals) =
              let offsm, state =
                Function_args.compute_actual
                  ~with_alarms ~warn_indeterminate state e
              in
              state, (e, offsm) :: actuals
            in
            let state, actuals = List.fold_right aux_actual argl (state, []) in
            let res =
              !compute_call_ref f ~recursive ~call_kinstr state actuals in
            CurrentLoc.set call_site_loc; (* Changed by compute_call_ref *)
            if res.Value_types.c_cacheable = Value_types.NoCacheCallers then
              (* Propagate info that callers cannot be cached either *)
              cacheable := Value_types.NoCacheCallers;
            Locals_scoping.remember_bases_with_locals
              clob res.Value_types.c_clobbered;
            (* If the call is recursive, we must not remove the formals: they
               have been restored to their values during the original call. *)
            let formals =
              if recursive then [] else Kernel_function.get_formals f in
            let treat = treat_one_result formals in
            List.fold_left treat acc_rt_res res.Value_types.c_values
	  with
            | Function_args.WrongFunctionType ->
                warning_once_current
                  "Function type must match type at call site: \
                     assert(function type matches)";
                Value_util.stop_if_stop_at_first_alarm_mode ();
                acc_rt_res
        in
        let results =
          Kernel_function.Hptset.fold treat_one_function functions []
        in
        results, !cacheable
      with
        | Function_args.Actual_is_bottom -> (* from compute_actual *)
            CurrentLoc.set call_site_loc;
            [], !cacheable


  exception AlwaysOverlap

  let check_non_overlapping state lvs1 lvs2 =
    let conv lv =
      let loc = lval_to_precise_loc ~with_alarms:CilE.warn_none_mode state lv in
      let for_writing = false in
      let exact =
        lazy (Precise_locs.valid_cardinal_zero_or_one ~for_writing loc)
      in
      let z = Precise_locs.enumerate_valid_bits ~for_writing loc in
      lv, exact, z
    in
    let l1 = List.map conv lvs1 in
    let l2 = List.map conv lvs2 in
    List.iter
      (fun (lv1, exact1, z1) ->
         List.iter
           (fun (lv2, exact2, z2) ->
              if Locations.Zone.intersects z1 z2 then begin
                Valarms.set_syntactic_context (Valarms.SySep(lv1, lv2));
                Valarms.warn_separated warn_all_mode;
                if Lazy.force exact1 && Lazy.force exact2 then
                  raise AlwaysOverlap
              end;
           )
           l2)
      l1

  (* Not currently taking advantage of calls information. But see
     plugin Undefined Order by VP. *)
  let check_unspecified_sequence state seq =
    let rec check_one_stmt ((stmt1,_,writes1,_,_) as my_stmt) = function
        [] -> ()
      | (stmt2,_,_,_,_)::seq when stmt1 == stmt2 -> check_one_stmt my_stmt seq
      | (stmt2,modified2,writes2,reads2,_) :: seq ->
          (* Values that cannot be read, as they are modified in the statement
             (but not by the whole sequence itself) *)
          let unauthorized_reads =
            List.filter
              (fun x -> List.for_all
                 (fun y -> not (LvalStructEq.equal x y)) modified2)
              writes1
          in
          check_non_overlapping state unauthorized_reads reads2;
          if stmt1.sid < stmt2.sid then
            check_non_overlapping state writes1 writes2;
          check_one_stmt my_stmt seq
    in
    List.iter (fun x -> check_one_stmt x seq) seq


  (* Remove locals and overwritten variables from the given state, and extract
     the content of \result. *)
  let externalize ~with_alarms kf ~return_lv clob =
    let fundec = Kernel_function.get_definition kf in
    let offsetmap_top_addresses_of_locals, state_top_addresses_of_locals =
      Locals_scoping.top_addresses_of_locals fundec clob
    in
    fun state ->
      let state, ret_val =
        match return_lv with
          | None ->
            state, None
          | Some lv ->
            let typ_ret = Cil.typeOfLval lv in
            let _loc, state, oret =
              try
                Eval_exprs.offsetmap_of_lv ~with_alarms state lv
              with Int_Base.Error_Top ->
                Value_parameters.abort ~current:true
                  "Function %a returns a value of unknown size. Aborting"
                  Kernel_function.pretty kf
            in
            match oret with
              | `Bottom ->
                assert (Model.equal Model.bottom state);
                state, None
              | `Top -> Warn.warn_top ();
              | `Map oret ->
                Valarms.set_syntactic_context (Valarms.SyMem lv);
                let offsetmap_state =
                  if Value_util.warn_indeterminate kf then
                    Warn.warn_reduce_indeterminate_offsetmap
                      ~with_alarms typ_ret oret `NoLoc state
                  else `Res (oret, state)
                in
                match offsetmap_state with
                  | `Bottom -> (* Completely indeterminate return *)
                    Model.bottom, None
                  | `Res (ret_val, state) ->
                    let locals, r = offsetmap_top_addresses_of_locals ret_val in
                    if not (Cvalue.V_Offsetmap.equal r ret_val) then
                      Warn.warn_locals_escape_result fundec locals;
                    state, Some r
      in

      (* Remove all the variadic arguments of this function. *)
      let state =
        (* TODO: Refactor. Check carefully what should be run for which
           kinds of functions (i.e. variadic or not) and when. *)
        if Value_util.is_function_variadic kf
        then Value_variadic.remove_variadic_arguments_from_state kf state
        else state
      in

      (* Check if all local variables of type va_list which are getting out of
         scope are properly uninitialized (i.e. either never initialized or
         initialized with the va_start or va_copy macro and then deinitialized
         with the va_end macro). *)
      let are_all_va_list_vars_uninitialized =
        Value_variadic.check_variadic_variables kf state fundec.sbody.blocals
      in
      if not are_all_va_list_vars_uninitialized then
        (* If any variable is definitely initialized then the state is bottom. *)
        ret_val, Model.bottom
      else

      (* If there are no definitely initialized variadic variables
         then we can proceed. *)
      let state =
        (* Remove the underlying structure for all the local va_list variables. *)
        Value_variadic.remove_structure_for_variadic_variables fundec.sbody.blocals state
      in

      let state = Cvalue.Model.remove_variables fundec.sbody.blocals state in
      (* We only remove from [state] the formals that have been overwritten
         during the call. The other ones will be used by the caller. See
         {!reduce_actuals_by_formals} above. *)
      let written_formals = Value_util.written_formals kf in
      let written_formals = Cil_datatype.Varinfo.Set.elements written_formals in
      let state = Cvalue.Model.remove_variables written_formals state in
      let state = state_top_addresses_of_locals state in
      ret_val, state    


(*
Local Variables:
compile-command: "make -C ../../../.."
End:
*)
