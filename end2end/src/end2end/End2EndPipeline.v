Require Import String.
Require Import Coq.ZArith.ZArith.
Require Import coqutil.Z.Lia.
Require Import Coq.Lists.List. Import ListNotations.
Require Import Coq.Logic.FunctionalExtensionality.
Require Import riscv.Spec.Decode.
Require Import riscv.Utility.Encode.
Require Import riscv.Utility.Utility.
Require Import coqutil.Word.LittleEndian.
Require Import coqutil.Word.Properties.
Require Import coqutil.Map.Interface.
Require Import coqutil.Tactics.Tactics.
Require Import riscv.Spec.Primitives.
Require Import riscv.Spec.Machine.
Require riscv.Platform.Memory.
Require Import riscv.Spec.PseudoInstructions.
Require Import riscv.Proofs.EncodeBound.
Require Import riscv.Proofs.DecodeEncode.
Require Import riscv.Platform.Run.
Require Import riscv.Utility.MkMachineWidth.
Require Import riscv.Utility.Monads. Import MonadNotations.
Require Import riscv.Utility.runsToNonDet.
Require Import coqutil.Datatypes.PropSet.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Platform.MetricRiscvMachine.
Require Import riscv.Spec.MetricPrimitives.
Require Import compiler.RunInstruction.
Require Import compiler.RiscvEventLoop.
Require Import compiler.ForeverSafe.
Require Import compiler.GoFlatToRiscv.
Require Import compiler.Simp.
Require Import processor.KamiWord.
Require Import processor.KamiRiscv.
Require Import bedrock2.Syntax bedrock2.Semantics.
Require Import compiler.PipelineWithRename.
Require Import compilerExamples.MMIO.
Require Import riscv.Platform.FE310ExtSpec.
Require Import compiler.FlatToRiscvDef.
Require Import coqutil.Tactics.rdelta.
Require Import bedrock2.Byte.

Local Open Scope Z_scope.


Axiom TODO_sam: False.
Axiom TODO_andres: False.
Axiom TODO_joonwon: False.

Require Import Coq.Classes.Morphisms.

Instance FlatToRiscvDefParams: FlatToRiscvDef.parameters :=
  { FlatToRiscvDef.W := @KamiWord.WordsKami KamiProc.width KamiProc.width_cases;
    FlatToRiscvDef.compile_ext_call := compile_ext_call;
    FlatToRiscvDef.compile_ext_call_length := compile_ext_call_length';
    FlatToRiscvDef.compile_ext_call_emits_valid := compile_ext_call_emits_valid;
  }.

Definition instrencode(p: list Instruction): list Byte.byte :=
  let word8s := List.flat_map
                  (fun inst => HList.tuple.to_list (LittleEndian.split 4 (encode inst))) p in
  List.map (fun w => Byte.of_Z (word.unsigned w)) word8s.

Section Connect.

  Context (memInit: Syntax.Vec (Syntax.ConstT (MemTypes.Data IsaRv32.rv32DataBytes))
                               (Z.to_nat KamiProc.width)).

  Context (instrMemSizeLg: Z).
  Hypothesis instrMemSizeLg_bounds: 3 <= instrMemSizeLg <= 30.

  Definition p4mm: Kami.Syntax.Modules :=
    KamiRiscv.p4mm instrMemSizeLg (proj1 instrMemSizeLg_bounds)
                   (proj2 instrMemSizeLg_bounds)
                   memInit.

  Context {Registers: map.map Register Utility.word}
          {Registers_ok: map.ok Registers}
          {mem: map.map Utility.word Utility.byte}
          {mem_ok: map.ok mem}
          {stringname_env : forall T : Type, map.map string T}
          {stringname_env_ok: forall T, map.ok (stringname_env T)}
          {src2imp : map.map string Register}
          {src2impOk : map.ok src2imp}.

  Instance mmio_params: MMIO.parameters := {
    byte_ok := KamiWord.word8ok;
    word_ok := @KamiWord.wordWok _ (or_introl eq_refl);
  }.

  Goal True.
  epose (_ : PrimitivesParams (MinimalMMIO.free MetricMinimalMMIO.action MetricMinimalMMIO.result)
                              MetricRiscvMachine).
  Abort.

  Instance pipeline_params: PipelineWithRename.Pipeline.parameters. refine ({|
    Pipeline.FlatToRiscvDef_params := compilation_params;
    Pipeline.ext_spec := bedrock2_interact;
  |}).
  Defined.

  Existing Instance MetricMinimalMMIO.MetricMinimalMMIOSatisfiesPrimitives.

  Instance pipeline_assumptions: @PipelineWithRename.Pipeline.assumptions pipeline_params.
    refine ({|
      Pipeline.PR := _ ; (*MetricMinimalMMIO.MetricMinimalMMIOSatisfiesPrimitives;*)
      Pipeline.FlatToRiscv_hyps := _; (*MMIO.FlatToRiscv_hyps*)
      Pipeline.src2imp_ok := _;
      Pipeline.Registers_ok := _;
      (* wait until we know if ext_spec will be in monad style or postcond style *)
      Pipeline.ext_spec_ok := match TODO_sam with end;
    |}).
  - refine (MetricMinimalMMIO.MetricMinimalMMIOSatisfiesPrimitives).
  - refine (@MMIO.FlatToRiscv_hyps _).
  Defined.

  Lemma HbtbAddr: BinInt.Z.to_nat instrMemSizeLg = (3 + (BinInt.Z.to_nat instrMemSizeLg - 3))%nat.
  Proof. PreOmega.zify; rewrite ?Z2Nat.id in *; blia. Qed.

  Lemma HinstrMemBound: instrMemSizeLg <= 30.
  Proof. exact (proj2 instrMemSizeLg_bounds). Qed.

  Definition kamiStep := kamiStep instrMemSizeLg.
  Definition states_related := @states_related Pipeline.Registers mem instrMemSizeLg.

  Lemma split_ll_trace: forall {t2' t1' t},
      traces_related t (t2' ++ t1') ->
      exists t1 t2, t = t2 ++ t1 /\ traces_related t1 t1' /\ traces_related t2 t2'.
  Proof.
    induction t2'; intros.
    - exists t, nil. simpl in *. repeat constructor. assumption.
    - simpl in H. simp. specialize IHt2' with (1 := H4).
      destruct IHt2' as (t1 & t2 & E & R1 & R2). subst.
      exists t1. exists (e :: t2). simpl. repeat constructor; assumption.
  Qed.

  Lemma states_related_to_traces_related: forall m m' t,
      states_related (m, t) m' -> traces_related t m'.(getLog).
  Proof. intros. inversion H. simpl. assumption. Qed.

  (* for debugging f_equal *)
  Lemma cong_app: forall {A B: Type} (f f': A -> B) (a a': A),
      f = f' ->
      a = a' ->
      f a = f' a'.
  Proof. intros. congruence. Qed.

  (* to tell that we want string names Semantics.params, because there's also
     Z names Semantics.params lingering around *)
  Notation strname_sem := (FlattenExpr.mk_Semantics_params
                             (@Pipeline.FlattenExpr_parameters pipeline_params)).
  Notation cmd := (@cmd ((FlattenExpr.mk_Syntax_params
                            (@Pipeline.FlattenExpr_parameters pipeline_params)))).
  Context (init_code loop_body: cmd)
          (spec: @ProgramSpec strname_sem)
          (ml: MemoryLayout 32)
          (mlOk: MemoryLayoutOk ml)
          (funimplsList: list (string * (list string * list string * cmd))).

  Hypothesis instrMemSizeLg_agrees_with_ml:
    word.sub ml.(code_pastend) ml.(code_start) = word.of_Z instrMemSizeLg.

  Hypothesis funimplsList_NoDup: NoDup (List.map fst funimplsList).

  (* goodTrace in terms of "exchange format" (list Event).
     Only holds at the beginning/end of each loop iteration,
     will be transformed into "exists suffix, ..." form later *)
  Definition goodTraceE(t: list Event): Prop :=
    exists bedrockTrace, traces_related t bedrockTrace /\ spec.(goodTrace) bedrockTrace.

  (* Definition kamiMemToBedrockMem: mem := *)
  (*   projT1 (riscvMemInit memInit). *)

  Definition bedrock2Inv := (fun t' m' l' => spec.(isReady) t' m' l' /\ spec.(goodTrace) t'
                                             /\ l' = map.empty).

  Definition prog: Program (p := strname_sem) cmd.
    refine {|
      ProgramSpec.funnames := _;
      ProgramSpec.funimpls := _;
      ProgramSpec.init_code := init_code;
      ProgramSpec.loop_body := loop_body;
    |}.
    - exact (List.map fst funimplsList).
    - exact (map.of_list funimplsList).
  Defined.

  Let funspecs := WeakestPrecondition.call (p := strname_sem) funimplsList.

  (* end to end, but still generic over the program
     TODO also write instantiations where the program is fixed, to reduce number of hypotheses *)
  Lemma end2end:
      (forall m, WeakestPrecondition.cmd (p := strname_sem) funspecs init_code
                                         [] m map.empty bedrock2Inv) ->
      (forall t m l,
          bedrock2Inv t m l ->
          WeakestPrecondition.cmd (p := strname_sem)
                                  funspecs loop_body t m l bedrock2Inv) ->
    (* TODO more hypotheses might be needed *)
    forall (t: Kami.Semantics.LabelSeqT) (mFinal: KamiImplMachine),
      (* IF the 4-stage pipelined processor steps to some final state mFinal, producing trace t,*)
      Kami.Semantics.Behavior p4mm mFinal t ->
      (* THEN the trace produced by the kami implementation can be mapped to an MMIO trace
         (this guarantees that the only external behavior of the kami implementation is MMIO)
         and moreover, this MMIO trace satisfies "not yet bad", as in, there exists at
         least one way to complete it to a good trace *)
      exists (t': list Event), KamiLabelSeqR t t' /\
                               exists (suffix: list Event), goodTraceE (suffix ++ t').
  Proof.
    intros *. intros Establish Preserve. intros *. intros B.

    set (traceProp := fun (t: list Event) =>
                        exists (suffix: list Event), goodTraceE (suffix ++ t)).
    change (exists t' : list Event,
               KamiLabelSeqR t t' /\ traceProp t').

    (* stack of proofs, bottom-up: *)

    (* 1) Kami pipelined processor to riscv-coq *)
    pose proof @riscv_to_kamiImplProcessor as P1.
    specialize_first P1 traceProp.
    specialize_first P1 (ll_inv prog spec ml).
    specialize_first P1 B.
    (* destruct spec. TODO why "Error: sat is already used." ?? *)

    (* 2) riscv-coq to bedrock2 semantics *)
    pose proof pipeline_proofs as P2.
    specialize_first P2 prog.
    specialize_first P2 spec.
    specialize_first P2 ml.
    specialize_first P2 mlOk.
    edestruct P2 as [ P2establish [P2preserve P2use] ]. {
      (* 3) bedrock2 semantics to bedrock2 program logic *)
      constructor.
      - eapply funimplsList_NoDup.
      - intros.
        replace m0 with (projT1 (riscvMemInit memInit)) by case TODO_joonwon.
        refine (WeakestPreconditionProperties.sound_cmd _ _ _ _ _ _ _ _ _);
          eauto using FlattenExpr.mk_Semantics_params_ok, FlattenExpr_hyps.
      - intros.
        refine (WeakestPreconditionProperties.sound_cmd _ _ _ _ _ _ _ _ _);
          eauto using FlattenExpr.mk_Semantics_params_ok, FlattenExpr_hyps.
        eapply Preserve; split; auto.
    }
    { case TODO_sam. }
    { case TODO_sam. }

    eapply P1.
    - (* establish *)
      intros.
      eapply P2establish.
      case TODO_sam.
    - (* preserve *)
      intros.
      refine (P2preserve _ _). assumption.
    - (* use *)
      intros *. intro Inv.
      subst traceProp. simpl.
      specialize_first P2use Inv.
      destruct P2use as [suff Good].
      unfold goodTrace.
      (* given the bedrock2 trace "suff ++ getLog m", produce exchange format trace *)
      case TODO_sam.

      Grab Existential Variables.
      1: exact m0RV.
  Qed.

End Connect.

(*
About end2end.
Print Assumptions end2end.
*)
