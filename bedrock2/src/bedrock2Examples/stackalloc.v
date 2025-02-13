Require Import bedrock2.Syntax bedrock2.NotationsCustomEntry.

Import Syntax.Coercions BinInt String List.ListNotations.
Local Open Scope string_scope. Local Open Scope Z_scope. Local Open Scope list_scope.

Definition stacktrivial := func! { stackalloc 4 as t; /*skip*/ }.

Definition stacknondet := func! () ~> (a, b) {
  stackalloc 4 as t;
  a = (load4(t) >> $8);
  store1(t, $42);
  b = (load4(t) >> $8)
}.

Definition stackdisj := func! () ~> (a,b) {
  stackalloc 4 as a;
  stackalloc 4 as b;
  /*skip*/
}.

Require bedrock2.WeakestPrecondition.
Require Import bedrock2.Semantics bedrock2.FE310CSemantics.
Require Import coqutil.Map.Interface bedrock2.Map.Separation bedrock2.Map.SeparationLogic.

Require bedrock2.WeakestPreconditionProperties.
From coqutil.Tactics Require Import letexists eabstract.
Require Import bedrock2.ProgramLogic bedrock2.Scalars.
Require Import coqutil.Word.Interface.

Section WithParameters.
  Context {word: word.word 32} {mem: map.map word Byte.byte}.
  Context {word_ok: word.ok word} {mem_ok: map.ok mem}.

  Instance spec_of_stacktrivial : spec_of "stacktrivial" := fun functions => forall m t,
      WeakestPrecondition.call functions
        "stacktrivial" t m [] (fun t' m' rets => rets = [] /\ m'=m /\ t'=t).
  From coqutil.Tactics Require Import reference_to_string .

  Lemma stacktrivial_ok : program_logic_goal_for_function! stacktrivial.
  Proof.
    repeat straightline.

    set (R := eq m).
    pose proof (eq_refl : R m) as Hm.

    repeat straightline.

    (* test for presence of intermediate separation logic hypothesis generated by [straightline_stackalloc] *)
    lazymatch goal with H : Z.of_nat (Datatypes.length ?stackarray) = 4 |- _ =>
    lazymatch goal with H : sep _ _ _ |- _ =>
    lazymatch type of H with context [Array.array ptsto _ ?a stackarray] =>
    idtac
    end end end.

    intuition congruence.
  Qed.

  Instance spec_of_stacknondet : spec_of "stacknondet" := fun functions => forall m t,
      WeakestPrecondition.call functions
        "stacknondet" t m [] (fun t' m' rets => exists a b, rets = [a;b] /\ a = b /\ m'=m/\t'=t).

  Add Ring wring : (Properties.word.ring_theory (word := word))
      (preprocess [autorewrite with rew_word_morphism],
       morphism (Properties.word.ring_morph (word := word)),
       constants [Properties.word_cst]).

  Lemma stacknondet_ok : program_logic_goal_for_function! stacknondet.
  Proof.
    repeat straightline.
    set (R := eq m).
    pose proof (eq_refl : R m) as Hm.
    repeat straightline.
    repeat (destruct stack as [|?b stack]; try solve [cbn in H1; Lia.lia]; []);
      clear H H0 H1 length_stack.
    seprewrite_in_by @scalar32_of_bytes Hm reflexivity.
    repeat straightline.
    Import symmetry eplace.
    seprewrite_in_by (symmetry! @scalar32_of_bytes) Hm reflexivity.
    cbn [Array.array] in Hm.
    Import Ring_tac.
    repeat straightline.
    assert ((Array.array ptsto (word.of_Z 1) a [(Byte.byte.of_Z (word.unsigned v0)); b0; b1; b2] ⋆ R)%sep m1).
    { cbn [Array.array].
      use_sep_assumption; cancel; Morphisms.f_equiv; f_equal; f_equal; ring. }
    seprewrite_in_by @scalar32_of_bytes H0 reflexivity.
    repeat straightline.
    seprewrite_in_by (symmetry! @scalar32_of_bytes) H0 reflexivity.
    repeat straightline.
    set [Byte.byte.of_Z (word.unsigned v0); b0; b1; b2] as ss in *.
    assert (length ss = Z.to_nat 4) by reflexivity.
    repeat straightline.
    cbn.
    eexists; split; [exact eq_refl|].
    subst R. subst m1.
    eexists _, _; Tactics.ssplit; eauto.

    subst v. subst v1. subst ss.
    eapply Properties.word.unsigned_inj.
    rewrite ?Properties.word.unsigned_sru_nowrap.
    2,3: rewrite ?Properties.word.unsigned_of_Z_nowrap by Lia.lia; reflexivity.
    rewrite ?Properties.word.unsigned_of_Z_nowrap; try Lia.lia.
    2,3: eapply (LittleEndianList.le_combine_bound [_;_;_;_]).
    repeat change [?a;?b;?c;?d] with ([a]++[b;c;d]).
    rewrite 2LittleEndianList.le_combine_app, 2LittleEndianList.le_combine_1, 2Z.shiftr_lor; simpl Z.of_nat; f_equal.
    rewrite 2Z.shiftr_div_pow2, 2Zdiv.Zdiv_small; eauto using Byte.byte.unsigned_range; Lia.lia.
  Qed.

  From bedrock2 Require Import ToCString PrintListByte.
  Definition stacknondet_main := func! () ~> ret {
      unpack! a, b = stacknondet();
      ret = a ^ b
  }.
  Definition stacknondet_c := String.list_byte_of_string (c_module (("main",stacknondet_main)::("stacknondet",stacknondet)::nil)).
  (* Goal True. print_list_byte stacknondet_c. Abort. *)

  Instance spec_of_stackdisj : spec_of "stackdisj" := fun functions => forall m t,
      WeakestPrecondition.call functions
        "stackdisj" t m [] (fun t' m' rets => exists a b, rets = [a;b] /\ a <> b /\ m'=m/\t'=t).

  Lemma stackdisj_ok : program_logic_goal_for_function! stackdisj.
  Proof.
    repeat straightline.
    set (R := eq m).
    pose proof (eq_refl : R m) as Hm.
    repeat straightline.
    repeat esplit.
    all : try intuition congruence.
    match goal with |- _ <> _ => idtac end.
  Abort.
End WithParameters.
