Require Import Coq.Logic.FunctionalExtensionality.
Require Import coqutil.Map.Interface.
Require Import coqutil.Tactics.Tactics.
Require Import compiler.Simulation.
Require Import coqutil.Tactics.fwd.
Require Import riscv.Spec.Decode.
Require Import riscv.Spec.Primitives.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Platform.MetricRiscvMachine.
Require Import riscv.Platform.MetricLogging.
Require Import riscv.Utility.runsToNonDet.
Require Import compiler.util.Common.
Require Import compiler.SeparationLogic.
Require Export coqutil.Word.SimplWordExpr.
Require Import compiler.GoFlatToRiscv.
Require Import compiler.DivisibleBy4.
Require Import compiler.MetricsToRiscv.
Require Import compiler.FlatImp.
Require Import compiler.RunInstruction.
Require Import compiler.FlatToRiscvDef.
Require Import compiler.FlatToRiscvCommon.
Require Import compiler.FlatToRiscvFunctions.
Require Import bedrock2.MetricLogging.
Require Import compiler.FitsStack.
Require Import compiler.Registers.
Require Import riscv.Utility.InstructionCoercions.

Local Arguments Z.mul: simpl never.
Local Arguments Z.add: simpl never.
Local Arguments Z.of_nat: simpl never.
Local Arguments Z.modulo : simpl never.
Local Arguments Z.pow: simpl never.
Local Arguments Z.sub: simpl never.

Section WithWordAndMem.
  Context {width: Z} {word: word.word width} {mem: map.map word byte}.

  (* bedrock2.ptsto_bytes.ptsto_bytes takes an n-tuple of bytes, whereas this one takes a list of bytes *)
  Definition ptsto_bytes: word -> list byte -> mem -> Prop := array ptsto (word.of_Z 1).

  Definition mem_available(start pastend: word) : mem -> Prop :=
    ex1 (fun anybytes: list byte =>
      emp (Z.of_nat (List.length anybytes) = word.unsigned (word.sub pastend start)) *
      (ptsto_bytes start anybytes))%sep.
End WithWordAndMem.

Section LowerPipeline.
  Context {iset: Decode.InstructionSet}.
  Context {width: Z} {BW: Bitwidth width} {BWM: bitwidth_iset width iset}.
  Context {fun_info: map.map String.string (nat * nat * Z)}. (* argcount, retcount, position *)
  Context {fun_info_ok: map.ok fun_info}.
  Context {env: map.map String.string (list Z * list Z * FlatImp.stmt Z)}.
  Context {env_ok: map.ok env}.
  Context (compile_ext_call: fun_info -> Z -> Z -> stmt Z -> list Instruction).

  Local Open Scope ilist_scope.

  (* Note: we could also track code size from the source program all the way to the target
     program, and a lot of infrastructure is already there, will do once/if we want to get
     a total compiler.
     Returns the fun_pos_env so that users know where to jump to call the compiled functions. *)
  Definition riscvPhase (prog: env): option (list Instruction * fun_info * Z) :=
    match stack_usage prog with
    | Some stack_words_needed =>
      let positions := FlatToRiscvDef.build_fun_pos_env iset compile_ext_call prog in
      let '(i, _) := FlatToRiscvDef.compile_funs iset compile_ext_call positions prog in
      Some (i, positions, stack_words_needed)
    | None => None
    end.

  Lemma get_build_fun_pos_env: forall e f,
      map.get e f <> None ->
      exists pos, map.get (FlatToRiscvDef.build_fun_pos_env iset compile_ext_call e) f = Some pos.
  Proof.
    intros pos0 e.
    unfold FlatToRiscvDef.build_fun_pos_env, FlatToRiscvDef.compile_funs.
    eapply map.fold_spec.
    - intros. rewrite map.get_empty in H. congruence.
    - intros. destruct r as [insts en]. simpl.
      rewrite map.get_put_dec in H1.
      destruct v as ((argnames & retnames) & body).
      rewrite map.get_put_dec.
      destruct_one_match; eauto.
  Qed.

  Lemma fun_pos_div4: forall functions f argcount retcount p,
      map.get (FlatToRiscvDef.build_fun_pos_env iset compile_ext_call functions) f =
      Some (argcount, retcount, p) ->
      p mod 4 = 0.
  Proof.
    unfold FlatToRiscvDef.build_fun_pos_env, FlatToRiscvDef.compile_funs.
    intros *.
    eapply map.fold_spec; intros.
    - rewrite map.get_empty in H. discriminate.
    - intros. destruct r as [insts en].
      unfold FlatToRiscvDef.add_compiled_function in *.
      destruct v as ((argnames & retnames) & body).
      rewrite map.get_put_dec in H1.
      destruct_one_match_hyp.
      + fwd. rewrite Z.mul_comm. apply Z_mod_mult.
      + auto.
  Qed.

  Context {word: word.word width} {word_ok: word.ok word}.
  Context {locals: map.map Z word} {locals_ok: map.ok locals}.
  Context {mem: map.map word byte} {mem_ok: map.ok mem}.

  Add Ring wring : (word.ring_theory (word := word))
      (preprocess [autorewrite with rew_word_morphism],
       morphism (word.ring_morph (word := word)),
       constants [word_cst]).

  Lemma mem_available_to_exists: forall start pastend (m: mem) P,
      (mem_available start pastend * P)%sep m ->
      exists anybytes,
        Z.of_nat (List.length anybytes) = word.unsigned (word.sub pastend start) /\
        (ptsto_bytes start anybytes * P)%sep m.
  Proof using word_ok mem_ok.
    unfold mem_available. intros * H.
    eapply sep_ex1_l in H. (* semicolon here fails *) destruct H.
    eapply sep_assoc in H.
    eapply sep_emp_l in H. destruct H.
    eauto.
  Qed.

  Definition mem_to_available: forall start pastend (m: mem) P anybytes,
     Z.of_nat (List.length anybytes) = word.unsigned (word.sub pastend start) ->
     (ptsto_bytes start anybytes * P)%sep m ->
     (mem_available start pastend * P)%sep m.
  Proof using word_ok mem_ok.
    unfold mem_available. intros * H Hsep.
    eapply sep_ex1_l. eexists. eapply sep_assoc. eapply sep_emp_l. eauto.
  Qed.

  Lemma get_compile_funs_pos: forall e finfo0,
      let '(insts, finfo) := FlatToRiscvDef.compile_funs iset compile_ext_call finfo0 e in
      forall f impl,
        map.get e f = Some impl ->
        exists pos2,
          let '(argnames, retnames, body) := impl in
          map.get finfo f = Some (List.length argnames, List.length retnames, pos2) /\
          pos2 mod 4 = 0.
  Proof using fun_info_ok env_ok.
    intros e finfo0.
    unfold FlatToRiscvDef.compile_funs.
    eapply map.fold_spec.
    - intros. rewrite map.get_empty in H. congruence.
    - intros. destruct r as [insts en]. simpl. destruct v as ((argnames & retnames) & body).
      intros.
      rewrite map.get_put_dec in H1.
      destruct impl as ((argnames' & retnames') & body').
      rewrite map.get_put_dec.
      destruct_one_match; fwd.
      + eexists. split; [reflexivity|].
        solve_divisibleBy4.
      + specialize H0 with (1 := H1). exact H0.
  Qed.

  Lemma program_mod_4_0: forall (a: word) instrs R m,
      instrs <> [] ->
      (program iset a instrs * R)%sep m ->
      word.unsigned a mod 4 = 0.
  Proof using .
    intros.
    destruct instrs as [|instr instrs]. 1: congruence.
    simpl in *.
    unfold sep, ptsto_instr, sep, emp in *.
    fwd.
    assumption.
  Qed.

  Lemma compile_funs_nonnil: forall e positions positions' f impl instrs,
      map.get e f = Some impl ->
      FlatToRiscvDef.compile_funs iset compile_ext_call positions e = (instrs, positions') ->
      instrs <> [].
  Proof using env_ok.
    intros e positions.
    unfold FlatToRiscvDef.compile_funs.
    eapply map.fold_spec; intros.
    - rewrite map.get_empty in H.
      discriminate.
    - rewrite map.get_put_dec in H1.
      destr (k =? f)%string.
      + subst.
        unfold FlatToRiscvDef.add_compiled_function in H2. fwd.
        intro C. destruct l; discriminate.
      + specialize H0 with (1 := H1).
        destruct r as [ instrs'' positions'' ].
        specialize H0 with (1 := eq_refl).
        intro C. subst instrs.
        unfold FlatToRiscvDef.add_compiled_function in H2. fwd.
        unfold FlatToRiscvDef.compile_function in *.
        destruct instrs''; discriminate.
  Qed.

  Ltac step :=
    match goal with
    | |- _ => reflexivity
    | |- _ => rewrite !List.app_length
    | |- _ => solve [eauto]
    | |- S _ = S _ => f_equal
    | |- (_ + _)%nat = (_ + _)%nat => f_equal
    end.

  Hypothesis compile_ext_call_length_ignores_positions: forall stackoffset posmap1 posmap2 c pos1 pos2,
      List.length (compile_ext_call posmap1 pos1 stackoffset c) =
      List.length (compile_ext_call posmap2 pos2 stackoffset c).

  Lemma compile_stmt_length_ignores_positions: forall posmap1 posmap2 c stackoffset pos1 pos2,
      List.length (FlatToRiscvDef.compile_stmt iset compile_ext_call posmap1 pos1 stackoffset c) =
      List.length (FlatToRiscvDef.compile_stmt iset compile_ext_call posmap2 pos2 stackoffset c).
  Proof using compile_ext_call_length_ignores_positions.
    induction c; intros; repeat (step || simpl).
  Qed.

  Lemma compile_function_length_ignores_positions: forall posmap1 posmap2 pos1 pos2 impl,
      List.length (FlatToRiscvDef.compile_function iset compile_ext_call posmap1 pos1 impl) =
      List.length (FlatToRiscvDef.compile_function iset compile_ext_call posmap2 pos2 impl).
  Proof using compile_ext_call_length_ignores_positions.
    intros. destruct impl as [ [args rets] body ]. repeat (step || simpl).
    apply compile_stmt_length_ignores_positions.
  Qed.

  Lemma build_fun_pos_env_ignores_posmap_aux: forall posmap1 posmap2 e i1 m1 i2 m2,
      map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call posmap1)
               ([], map.empty) e = (i1, m1) ->
      map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call posmap2)
               ([], map.empty) e = (i2, m2) ->
      m1 = m2 /\ List.length i1 = List.length i2.
  Proof using env_ok compile_ext_call_length_ignores_positions.
    intros until e.
    eapply map.fold_parametricity with (fa := (FlatToRiscvDef.add_compiled_function _ _ posmap1))
                                       (fb := (FlatToRiscvDef.add_compiled_function _ _ posmap2));
      intros.
    - destruct a as [insts1 map1]. destruct b as [insts2 map2].
      unfold FlatToRiscvDef.add_compiled_function in *.
      inversion H0. inversion H1. subst. clear H0 H1.
      specialize H with (1 := eq_refl) (2 := eq_refl). destruct H.
      rewrite ?H0. subst.
      destruct v as ((argnames & retnames) & body). fwd.
      split. 1: congruence.
      repeat step.
      apply compile_function_length_ignores_positions.
    - fwd. auto.
  Qed.

  Lemma build_fun_pos_env_ignores_posmap: forall posmap1 posmap2 e,
      snd (map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call posmap1)
                    ([], map.empty) e) =
      snd (map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call posmap2)
                    ([], map.empty) e).
  Proof using env_ok compile_ext_call_length_ignores_positions.
    intros.
    destr (map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call posmap1)
                    ([], map.empty) e).
    destr (map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call posmap2)
                    ([], map.empty) e).
    simpl.
    edestruct build_fun_pos_env_ignores_posmap_aux.
    - exact E.
    - exact E0.
    - assumption.
  Qed.

  (* This lemma should relate two map.folds which fold two different f over the same env e:
     1) FlatToRiscvDef.compile_funs, which folds FlatToRiscvDef.add_compiled_function.
        Note that this one is called twice: First in build_fun_pos_env, and then in
        compile_funs, and we rely on the order being the same both times.
     2) functions, which folds sep
     Note that 1) is not commutative (the iteration order determines in which order code
     is layed out in memory), while 2) should be commutative because the "function"
     separation logic predicate it seps onto the separation logic formula is the same
     if we pass it the same function position map. *)
  Lemma functions_to_program: forall (functions_start: word) e instrs pos_map stack_size,
      riscvPhase e = Some (instrs, pos_map, stack_size) ->
      iff1 (program iset functions_start instrs)
           (FlatToRiscvCommon.functions compile_ext_call functions_start
                                        (FlatToRiscvDef.build_fun_pos_env iset compile_ext_call e) e).
  Proof using word_ok mem_ok fun_info_ok env_ok compile_ext_call_length_ignores_positions.
    unfold riscvPhase.
    intros.
    fwd.
    unfold FlatToRiscvDef.compile_funs, functions in *.
    remember (FlatToRiscvDef.build_fun_pos_env iset compile_ext_call e) as positions.
    (* choose your IH carefully! *)
    lazymatch goal with
    | |- ?G => enough ((forall f, map.get r f <> None <-> map.get e f <> None) /\
             ((forall f pos, map.get r f = Some pos -> map.get positions f = Some pos) -> G))
    end.
    1: {
      fwd. apply Hp1; clear Hp1.
      intros. rewrite <- H. f_equal.
      subst.
      apply (f_equal snd) in E0. simpl in E0. rewrite <- E0.
      transitivity (snd (map.fold (FlatToRiscvDef.add_compiled_function iset compile_ext_call map.empty) ([], map.empty) e)).
      - unfold FlatToRiscvDef.build_fun_pos_env, snd. reflexivity.
      - apply build_fun_pos_env_ignores_posmap.
    }
    revert E0.
    revert instrs r. clear E stack_size.
    eapply (map.fold_spec (R:=(list Instruction * _))) with (m:=e); repeat (cbn || fwd || intros).
    { rewrite map.fold_empty. intuition try reflexivity.
      - eapply H. eapply map.get_empty.
      - eapply H. eapply map.get_empty.
    }
    rewrite map.fold_put; trivial.
    2: { intros.
      eapply functional_extensionality_dep; intros x.
      eapply PropExtensionality.propositional_extensionality; revert x.
      match goal with |- forall x, ?P x <-> ?Q x => change (iff1 P Q) end.
      cancel. }
    case r as (instrs'&r').
    specialize H0 with (1 := eq_refl).
    unfold FlatToRiscvDef.add_compiled_function in E0.
    destruct v as ((argnames & retnames) & body).
    fwd.
    unfold program in *.
    wseplog_pre.
    split. {
      intros. rewrite ?map.get_put_dec.
      destr (k =? f)%string. 2: eauto. intuition discriminate.
    }
    intros.
    rewrite H0p1. 2: {
      intros.
      eapply H0.
      rewrite map.get_put_dec.
      destr (k =? f)%string. 2: assumption.
      subst. exfalso.
      specialize (H0p0 f). unfold not in H0p0. rewrite H1 in H0p0. rewrite H in H0p0.
      intuition congruence.
    }
    cancel.
    unfold function.
    specialize (H0 k).
    rewrite map.get_put_same in H0.
    specialize H0 with (1 := eq_refl).
    rewrite H0.
    unfold program.
    cancel_seps_at_indices 0%nat 0%nat. 2: reflexivity.
    f_equal.
    f_equal.
    solve_word_eq word_ok.
  Qed.

  Open Scope ilist_scope.

  Context {M: Type -> Type}.
  Context {MM: Monads.Monad M}.
  Context {RVM: Machine.RiscvProgram M word}.
  Context {PRParams: PrimitivesParams M MetricRiscvMachine}.
  Context {PR: MetricPrimitives.MetricPrimitives PRParams}.
  Context {ext_spec: Semantics.ExtSpec}.
  Context {word_riscv_ok: RiscvWordProperties.word.riscv_ok word}.

  Definition machine_ok{BWM: bitwidth_iset width iset}
             (p_functions: word)(stack_start stack_pastend: word)
             (finstrs: list Instruction)
             (pc: word)(mH: mem)(Rdata Rexec: mem -> Prop)(mach: MetricRiscvMachine): Prop :=
      (program iset p_functions finstrs *
       mem_available stack_start stack_pastend *
       Rdata * Rexec * eq mH
      )%sep mach.(getMem) /\
      subset (footpr (program iset p_functions finstrs * Rexec)%sep)
             (of_list (getXAddrs mach)) /\
      word.unsigned (mach.(getPc)) mod 4 = 0 /\
      mach.(getPc) = pc /\
      mach.(getNextPc) = word.add mach.(getPc) (word.of_Z 4) /\
      regs_initialized mach.(getRegs) /\
      map.get mach.(getRegs) RegisterNames.sp = Some stack_pastend /\
      (* configured by PrimitivesParams, can contain invariants needed for external calls *)
      valid_machine mach.

  Hypothesis compile_ext_call_correct: forall resvars extcall argvars,
      compiles_FlatToRiscv_correctly compile_ext_call compile_ext_call
                                     (FlatImp.SInteract resvars extcall argvars).

  Definition riscv_call(p: list Instruction * fun_info * Z)
             (f_name: string)(t: Semantics.trace)(mH: mem)(argvals: list word)
             (post: Semantics.trace -> mem -> list word -> Prop): Prop :=
    let '(instrs, finfo, req_stack_size) := p in
    exists argcount retcount f_rel_pos,
      map.get finfo f_name = Some (argcount, retcount, f_rel_pos) /\
      forall p_funcs stack_start stack_pastend ret_addr Rdata Rexec (initial: MetricRiscvMachine),
        map.get initial.(getRegs) RegisterNames.ra = Some ret_addr ->
        map.getmany_of_list initial.(getRegs)
                            (List.firstn argcount (reg_class.all reg_class.arg))
        = Some argvals ->
        let start_pc := word.add p_funcs (word.of_Z f_rel_pos) in
        req_stack_size <= word.unsigned (word.sub stack_pastend stack_start) / bytes_per_word ->
        word.unsigned (word.sub stack_pastend stack_start) mod bytes_per_word = 0 ->
        machine_ok p_funcs stack_start stack_pastend instrs start_pc mH Rdata Rexec initial ->
        runsTo initial (fun final => exists mH' retvals,
          map.getmany_of_list final.(getRegs)
                              (List.firstn retcount (reg_class.all reg_class.arg))
          = Some retvals /\
          post final.(getLog) mH' retvals /\
          machine_ok p_funcs stack_start stack_pastend instrs ret_addr mH' Rdata Rexec final).

  Lemma flat_to_riscv_correct: forall p1 p2,
      map.forall_values FlatToRiscvDef.valid_FlatImp_fun p1 ->
      riscvPhase p1 = Some p2 ->
      forall fname t m argvals post,
      (exists argnames retnames fbody,
          map.get p1 fname = Some (argnames, retnames, fbody) /\
          forall l mc, map.of_list_zip argnames argvals = Some l ->
                       FlatImp.exec p1 fbody t m l mc (fun t' m' l' mc' =>
                         exists retvals, map.getmany_of_list l' retnames = Some retvals /\
                                         post t' m' retvals)) ->
      riscv_call p2 fname t m argvals post.
  Proof.
    unfold riscv_call.
    intros. destruct p2 as ((finstrs & finfo) & req_stack_size).
    match goal with
    | H: riscvPhase _ = _ |- _ => pose proof H as RP; unfold riscvPhase in H
    end.
    fwd.
    pose proof (get_compile_funs_pos p1 (build_fun_pos_env iset compile_ext_call p1)) as P.
    rewrite E0 in P.
    specialize P with (1 := H1p0). cbn in P. rename r into finfo. fwd.
    assert (finfo = build_fun_pos_env iset compile_ext_call p1). {
      unfold riscvPhase in RP.
(*
    edestruct (get_build_fun_pos_env p1 fname) as (((argcount & retcount) & f_rel_pos) & GetPos).
    1: congruence.
    exists argcount, retcount, f_rel_pos. split. 1: assumption.
    intros.
    pose proof GetPos as M0. eapply fun_pos_div4 in M0.
    assert (word.unsigned p_funcs mod 4 = 0). {
      unfold machine_ok in *. fwd.
      eapply program_mod_4_0. 2: ecancel_assumption.
      eapply compile_funs_nonnil; eassumption.
    }
    unfold map.forall_values in H.
    match goal with
    | H: map.get p1 fname = Some _ |- _ => rename H into GetFun
    end.
    specialize H with (1 := GetFun).
    match goal with
    | H: context[post] |- _ => rename H into Hpost
    end.
    unfold map.of_list_zip in Hpost.
    unfold valid_FlatImp_fun in H. fwd.
    apply_in_hyps @map.getmany_of_list_length.
    match goal with
    | H: _ |- _ => rename H into HL
    end.
    edestruct (map.sameLength_putmany_of_list _ _ map.empty HL) as [st0 OL].
    rewrite List.firstn_length in HL.
    change (Datatypes.length (reg_class.all reg_class.arg)) with 8%nat in HL.
    pose proof (get_compile_funs_pos p1 (build_fun_pos_env iset compile_ext_call p1)) as P.
    rewrite E0 in P.
    Search p1.

    Search argnames.
    Search argvals.
    apply_in_hyps


    specialize Hpost with (1 := OL).

    eapply runsTo_weaken.
    - eapply compile_function_body_correct with
          (e_impl := e)
          (e_pos := FlatToRiscvDef.build_fun_pos_env iset compile_ext_call e)
          (xframe := Rexec)
          (program_base := p_funcs).
      + intros.
        pose proof compile_stmt_correct as P.
        unfold compiles_FlatToRiscv_correctly in P at 2.
        eapply P; clear P. try eassumption.

    - specialize compile_stmt_correct with (1 := compile_ext_call_correct).
      unfold compiles_FlatToRiscv_correctly. intros compile_stmt_correct.
      (* TODO isolate exec.call case from FlatToRiscvFunctions *)
      eapply compile_stmt_correct with (g := {|
        e_pos := FlatToRiscvDef.build_fun_pos_env iset compile_ext_call functions;
        program_base := p_funcs;
        e_impl := functions;
        rem_stackwords := word.unsigned (word.sub stack_pastend stack_start) / bytes_per_word;
        rem_framewords := 0;
        p_insts := _;
        insts := [[Jal RegisterNames.ra
                      (f_entry_rel_pos + word.signed (word.sub p_funcs (getPc initial)))]];
        xframe := Rexec;
        dframe := Rdata;
      |}) (pos := - word.signed (word.sub p_funcs p_call));
      clear compile_stmt_correct; cbn.
      { eapply FlatImp.exec.call with (args := []) (argvs := []) (binds := []); cycle -1; try eassumption.
        2,3: reflexivity.
        intros *. intro Po. do 2 eexists. ssplit.
        1,2: reflexivity.
        revert Po.
        match goal with
        | |- ?A _ _ _ _ -> ?B _ _ _ _ => unify A B
        end.
        exact id. }
      { clear. intros k v ?. eassumption. }
      { unfold good_e_impl.
        intros *. intro G.
        split.
        - eapply H. eassumption.
        - unfold FlatToRiscvDef.build_fun_pos_env, FlatToRiscvDef.build_fun_pos_env.
          pose proof (get_compile_funs_pos functions) as P.
          destruct (compile_funs iset _ map.empty functions) as [ insts posmap ] eqn: F.
          eapply P.
          eassumption. }
      { eapply fits_stack_call. 2: eassumption. 1: reflexivity.
        eapply fits_stack_monotone.
        { eapply stack_usage_correct; eassumption. }
        1: reflexivity.
        blia. }
      { cbn. cbn in GetPos. rewrite GetPos. f_equal. f_equal. f_equal.
        unfold machine_ok in *. simp. blia. }
      { simpl. auto. }
      { cbn. auto using Forall_nil, Nat.le_0_l. }
      { solve_divisibleBy4. }
      { assumption. }
      { unfold machine_ok in *. simp.
        (* TODO why are these manual steps needed? *)
        rewrite word.ring_morph_opp.
        rewrite word.of_Z_signed.
        solve_word_eq word_ok. }
      { (* TODO why are these manual steps needed? *)
        rewrite word.ring_morph_opp.
        rewrite word.of_Z_signed.
        solve_word_eq word_ok. }
      unfold goodMachine. simpl. ssplit.
      { simpl. unfold map.extends. intros k v Emp. rewrite map.get_empty in Emp. discriminate. }
      { simpl. unfold map.extends. intros k v Emp. rewrite map.get_empty in Emp. discriminate. }
      { simpl. unfold machine_ok in *. simp. eassumption. }
      { unfold machine_ok in *. simp. assumption. }
      { unfold machine_ok in *. simp. assumption. }
      { unfold machine_ok in *. simp. simpl.
        eapply rearrange_footpr_subset. 1: eassumption.
        wwcancel.
        eapply functions_to_program.
        idtac. eassumption. }
      { simpl.
        unfold machine_ok in *. simp.
        edestruct mem_available_to_exists as [ stack_trash [? ?] ]. 1: simpl; ecancel_assumption.
        destruct (byte_list_to_word_list_array stack_trash)
          as (stack_trash_words&Hlength_stack_trash_words&Hstack_trash_words).
        { match goal with
          | H: ?x = ?y |- _ => rewrite H
          end.
          assumption. }
        exists stack_trash_words.
        split. 2: {
          unfold word_array.
          rewrite <- (iff1ToEq (Hstack_trash_words _)).
          match goal with
          | E: Z.of_nat _ = word.unsigned (word.sub _ _) |- _ => simpl in E|-*; rewrite <- E
          end.
          lazymatch goal with
          | H: riscvPhase _ = _ |- _ => specialize functions_to_program with (1 := H) as P
          end.
          symmetry in P.
          simpl in P|-*. unfold program in P.
          seprewrite P. clear P.
          rewrite <- Z_div_exact_2; cycle 1. {
            unfold bytes_per_word. clear -BW.
            destruct width_cases as [E | E]; rewrite E; reflexivity.
          }
          {
            match goal with
            | H: ?x = ?y |- _ => rewrite H
            end.
            assumption.
          }
          use_sep_assumption.
          unfold ptsto_bytes.
          wseplog_pre.
          simpl_addrs.
          rewrite !word.of_Z_unsigned.
          wcancel.
        }
        match goal with
        | E: Z.of_nat _ = word.unsigned (word.sub _ _) |- _ => simpl in E|-*; rewrite <- E
        end.
        rewrite Z.sub_0_r. symmetry.
        apply Hlength_stack_trash_words. }
      { reflexivity. }
      { unfold machine_ok in *. simp. assumption. }
    - cbv beta. unfold goodMachine. cbn. unfold machine_ok in *. intros. simp.
      eexists. split. 1: eassumption.
      ssplit; try assumption.
      + cbv [mem_available].
        repeat rewrite ?(iff1ToEq (sep_ex1_r _ _)), ?(iff1ToEq (sep_ex1_l _ _)).
        exists (List.flat_map (fun x => HList.tuple.to_list (LittleEndian.split (Z.to_nat bytes_per_word) (word.unsigned x))) stack_trash).
        rewrite !(iff1ToEq (sep_emp_2 _ _ _)).
        rewrite !(iff1ToEq (sep_assoc _ _ _)).
        eapply (sep_emp_l _ _); split.
        { assert (0 < bytes_per_word). { (* TODO: deduplicate *)
            unfold bytes_per_word; simpl; destruct width_cases as [EE | EE]; rewrite EE; cbv; trivial.
          }
          rewrite (List.length_flat_map _ (Z.to_nat bytes_per_word)).
          { rewrite Nat2Z.inj_mul, Z2Nat.id by blia. rewrite Z.sub_0_r in H7p9p0.
            rewrite <-H7p9p0, <-Z_div_exact_2; try trivial.
            eapply Z.lt_gt; assumption. }
          intros w.
          rewrite HList.tuple.length_to_list; trivial. }
        use_sep_assumption.
        cbn [dframe xframe program_base e_pos e_impl p_insts insts].
        change (if width =? 32 then RV32I else RV64I) with iset.
        wwcancel.
        cancel_seps_at_indices 0%nat 1%nat. {
          unfold ptsto_bytes.
          match goal with
          | |- array _ _ ?a _ = array _ _ ?a' _ => replace a with a'
          end.
          2: {
            match goal with
            | H: context[stack_trash] |- _ => rewrite <- H
            end.
            rewrite <- Z_div_exact_2; cycle 1. {
              unfold bytes_per_word. simpl.
              destruct width_cases as [Ew | Ew]; rewrite Ew; reflexivity.
            }
            1: assumption.
            rewrite word.of_Z_unsigned.
            solve_word_eq word_ok.
          }
          apply iff1ToEq, cast_word_array_to_bytes.
        }
        unfold ptsto_instr.
        simpl.
        unfold ptsto_bytes, ptsto_instr, truncated_scalar, littleendian, ptsto_bytes.ptsto_bytes.
        simpl.
        wwcancel.
        pose proof functions_to_program as P. specialize P with (1 := RP).
        cbn [seps].
        rewrite <- P; clear P.
        wwcancel.
      + unfold machine_ok in *. simp. simpl.
        eapply rearrange_footpr_subset. 1: eassumption.
        (* TODO remove duplication *)
        lazymatch goal with
        | H: riscvPhase _ = _ |- _ => specialize functions_to_program with (1 := H) as P
        end.
        symmetry in P.
        rewrite P. clear P.
        cbn [dframe xframe program_base e_pos e_impl p_insts insts program].
        simpl.
        unfold ptsto_bytes, ptsto_instr, truncated_scalar, littleendian, ptsto_bytes.ptsto_bytes.
        simpl.
        wwcancel.
      + destr_RiscvMachine final. subst. solve_divisibleBy4.
  Qed.
  *)
  Admitted.

End LowerPipeline.
