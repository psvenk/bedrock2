Require Import Coq.ZArith.ZArith. Local Open Scope Z_scope.
Require Import Coq.micromega.Lia.
Require Import coqutil.Word.Interface coqutil.Word.Properties coqutil.Word.Bitwidth.
Require Import coqutil.Map.Interface.
Require Import coqutil.Datatypes.ZList. Import ZList.List.ZIndexNotations.
Require Import bedrock2.Lift1Prop bedrock2.Map.Separation bedrock2.Map.SeparationLogic.
Require Import bedrock2.PurifySep.
Require Import bedrock2.Array bedrock2.Scalars.

(* PredTp equals `Z -> mem -> Prop` if the predicate takes any number of values
   and its size depends on these values.
   PredTp equals `V1 -> ... -> Vn -> Z -> mem -> Prop` for some `V1..Vn` if the
   predicate takes `n` values, but its size does not depend on these values. *)
Definition PredicateSize{PredTp: Type}(pred: PredTp) := Z.
Existing Class PredicateSize.

(* Derives the size of a value-independent predicate applied to a value *)
#[export] Hint Extern 4 (PredicateSize (?pred ?v)) =>
  lazymatch constr:(_: PredicateSize pred) with
  | ?sz => exact sz
  end
: typeclass_instances.

Definition array{width}{BW: Bitwidth width}{word: word width}
  {mem: map.map word Byte.byte}{T: Type}
  (elem: T -> word -> mem -> Prop){elemSize: PredicateSize elem}
  (n: Z)(vs: list T)(addr: word): mem -> Prop :=
  sep (emp (len vs = n))
      (array (fun a v => elem v a) (word.of_Z elemSize) addr vs).

(* Note: We don't pass a list ?vs to the pattern, because the length is already given by n *)
#[export] Hint Extern 1
  (PredicateSize (@array ?width ?BW ?word ?mem ?T ?elem ?elemSize ?n)) =>
  exact (n * elemSize) : typeclass_instances.

Lemma purify_array{width}{BW: Bitwidth width}{word: word width}{word_ok: word.ok word}
  {mem: map.map word Byte.byte}{mem_ok: map.ok mem}{T: Type} elem
  {elemSize: PredicateSize elem}(n: Z)(vs: list T)(addr: word):
  purify (array elem n vs addr) (len vs = n). (* TODO also n <= 2^width or n < 2^width? *)
Proof.
  unfold purify, array. intros. eapply sep_emp_l in H. apply H.
Qed.
#[export] Hint Resolve purify_array | 10 : purify.

Lemma purify_array_and_elems{width}{BW: Bitwidth width}
  {word: word width}{word_ok: word.ok word}
  {mem: map.map word Byte.byte}{mem_ok: map.ok mem}{T: Type} elem
  {elemSize: PredicateSize elem}{P: Prop}
  (n: Z)(vs: list T)(addr: word):
  purify (bedrock2.Array.array (fun a v => elem v a) (word.of_Z elemSize) addr vs) P ->
  purify (array elem n vs addr) (len vs = n /\ P).
Proof.
  unfold purify, array. intros. eapply sep_emp_l in H0. split. 1: apply H0.
  eapply H. apply H0.
Qed.
Ltac is_concrete_list l :=
  lazymatch l with
  | nil => idtac
  | cons _ ?t => is_concrete_list t
  end.
#[export] Hint Extern 5 (purify (array ?elem ?n ?vs ?addr) _) =>
  is_concrete_list vs;
  eapply purify_array_and_elems;
  unfold bedrock2.Array.array;
  purify_rec
: purify.

Definition nbits_to_nbytes(nbits: Z): Z := (Z.max 0 nbits + 7) / 8.

Lemma nbits_to_nbytes_nonneg: forall nbits, 0 <= nbits_to_nbytes nbits.
Proof. intros. unfold nbits_to_nbytes. Z.to_euclidean_division_equations. lia. Qed.

Lemma nbits_to_nbytes_8: forall n, 0 <= n -> nbits_to_nbytes (8 * n) = n.
Proof.
  intros. unfold nbits_to_nbytes. Z.to_euclidean_division_equations. lia.
Qed.


Definition uint{width}{BW: Bitwidth width}{word: word width}{mem: map.map word Byte.byte}
  (nbits: Z)(v: Z)(addr: word): mem -> Prop :=
  sep (emp (0 <= v < 2 ^ nbits))
      (littleendian (Z.to_nat (nbits_to_nbytes nbits)) addr v).

#[export] Hint Extern 1 (PredicateSize (uint ?nbits)) =>
  let sz := lazymatch isZcst nbits with
            | true => eval cbv in (nbits_to_nbytes nbits)
            | false => constr:(nbits_to_nbytes nbits)
            end in
  exact sz
: typeclass_instances.

Lemma purify_uint{width}{BW: Bitwidth width}{word: word width}{word_ok: word.ok word}
  {mem: map.map word Byte.byte}{mem_ok: map.ok mem} nbits v a:
  purify (uint nbits v a) (0 <= v < 2 ^ nbits).
Proof.
  unfold purify, uint. intros. eapply sep_emp_l in H. apply proj1 in H. exact H.
Qed.
#[export] Hint Resolve purify_uint : purify.


Definition uintptr{width}{BW: Bitwidth width}{word: word width}{mem: map.map word Byte.byte}
                  (v a: word): mem -> Prop := scalar a v.

#[export] Hint Extern 1 (PredicateSize (@uintptr ?width ?BW ?word ?mem)) =>
  let sz := lazymatch isZcst width with
            | true => eval cbv in (nbits_to_nbytes width)
            | false => constr:(nbits_to_nbytes width)
            end in
  exact sz
: typeclass_instances.

Lemma purify_uintptr{width}{BW: Bitwidth width}{word: word width}
  {mem: map.map word Byte.byte} v a:
  purify (uintptr v a) True.
Proof. unfold purify. intros. constructor. Qed.
#[export] Hint Resolve purify_uintptr : purify.

Section WithMem.
  Context {width} {BW: Bitwidth width} {word: word width} {mem: map.map word Byte.byte}
          {word_ok: word.ok word} {mem_ok: map.ok mem}.

  Definition anybytes(sz: Z)(a: word): mem -> Prop :=
    ex1 (fun bytes => array (uint 8) sz bytes a).

  Lemma purify_anybytes sz a:
    purify (anybytes sz a) (0 <= sz).
    (* Note:
     - (sz <= 2^width) would hold (because of max memory size)
     - (sz < 2^width) would be more useful but is not provable currently *)
  Proof.
    unfold purify, anybytes, ex1. intros * [bytes Hm].
    eapply purify_array in Hm. lia.
  Qed.

  Lemma sep_assoc_eq: forall (p q r: mem -> Prop),
      sep (sep p q) r = sep p (sep q r).
  Proof.
    intros. eapply iff1ToEq. eapply sep_assoc.
  Qed.

  (* The opposite direction does not hold because (len (vs1 ++ vs2) = n1 + n2) does
     not imply (len vs1 = n1 /\ len vs2 = n2), but we can quantify over a vs:=vs1++vs2
     and use vs[:i] ++ vs[i:], resulting in the lemma split_array below *)
  Lemma merge_array{T: Type}(elem: T -> word -> mem -> Prop){sz: PredicateSize elem}:
    forall n1 n2 vs1 vs2 a m,
      sep (array elem n1 vs1 a)
          (array elem n2 vs2 (word.add a (word.of_Z (sz * n1)))) m ->
      array elem (n1 + n2) (vs1 ++ vs2) a m.
  Proof.
    unfold array. intros.
    pose proof (Array.array_append (fun (a0 : word) (v : T) => elem v a0)
                  (word.of_Z sz) vs1 vs2 a) as A.
    eapply iff1ToEq in A.
    rewrite A. clear A.
    rewrite sep_assoc_eq in H.
    eapply sep_emp_l in H.
    destruct H as [? H]. subst n1.
    eapply sep_comm in H.
    rewrite sep_assoc_eq in H.
    eapply sep_emp_l in H.
    destruct H as [? H]. subst n2.
    eapply sep_emp_l. split.
    1: rewrite List.app_length; lia.
    rewrite word.ring_morph_mul.
    rewrite word.of_Z_unsigned.
    rewrite <- word.ring_morph_mul.
    eapply sep_comm in H.
    exact H.
  Qed.

  Import ZList.List.ZIndexNotations.
  Local Open Scope zlist_scope.

  Lemma split_array{T: Type}(elem: T -> word -> mem -> Prop){sz: PredicateSize elem}:
    forall vs n i a m,
      0 <= i <= len vs ->
      array elem n vs a m ->
      sep (array elem i vs[:i] a)
          (array elem (n-i) vs[i:] (word.add a (word.of_Z (sz * i)))) m.
  Proof.
    unfold array. intros.
    eapply sep_emp_l in H0. destruct H0.
    rewrite (List.split_at_index vs i) in H1 by assumption.
    eapply Array.array_append in H1.
    rewrite sep_assoc_eq.
    eapply sep_emp_l.
    split.
    { apply List.len_upto. assumption. }
    apply sep_comm.
    rewrite sep_assoc_eq.
    eapply sep_emp_l.
    split.
    { subst. apply List.len_from. assumption. }
    rewrite word.ring_morph_mul in H1.
    rewrite word.of_Z_unsigned in H1.
    rewrite <- word.ring_morph_mul in H1.
    rewrite List.len_upto in H1 by assumption.
    apply sep_comm.
    exact H1.
  Qed.

  Lemma merge_anybytes: forall n1 n2 addr m,
      sep (anybytes n1 addr) (anybytes n2 (word.add addr (word.of_Z n1))) m ->
      anybytes (n1 + n2) addr m.
  Proof.
    unfold anybytes. intros * Hm.
    eapply sep_ex1_l in Hm. destruct Hm as [bs1 Hm].
    eapply sep_ex1_r in Hm. destruct Hm as [bs2 Hm].
    exists (bs1 ++ bs2).
    eapply merge_array. rewrite Z.mul_1_l.
    exact Hm.
  Qed.

  Lemma split_anybytes: forall n i addr m,
      0 <= i <= n ->
      anybytes n addr m ->
      sep (anybytes i addr) (anybytes (n-i) (word.add addr (word.of_Z i))) m.
  Proof.
    intros * B Hm.
    destruct Hm as [bs Hm].
    pose proof Hm as HP. eapply purify_array in HP.
    unfold anybytes.
    eapply sep_ex1_l. exists bs[:i].
    eapply sep_ex1_r. exists bs[i:].
    subst n.
    eapply split_array in Hm. 2: eassumption.
    rewrite Z.mul_1_l in Hm.
    exact Hm.
  Qed.

  Lemma ptsto_to_uint8: forall a b m, ptsto a b m -> uint 8 (Byte.byte.unsigned b) a m.
  Proof.
    intros a b m Hb.
    eapply sep_emp_l. split. 1: eapply Byte.byte.unsigned_range.
    unfold littleendian, ptsto_bytes.ptsto_bytes. simpl.
    eapply sep_emp_True_r.
    rewrite Byte.byte.of_Z_unsigned.
    exact Hb.
  Qed.

  Lemma uint8_to_ptsto: forall a b m, uint 8 b a m -> ptsto a (Byte.byte.of_Z b) m.
  Proof.
    unfold uint. intros a b m Hb. eapply sep_emp_l in Hb. destruct Hb as (B & Hb).
    unfold littleendian, ptsto_bytes.ptsto_bytes in Hb. simpl in Hb.
    eapply sep_emp_True_r. exact Hb.
  Qed.

  Lemma anybytes_from_alt: forall addr n m,
      0 <= n -> Memory.anybytes addr n m -> anybytes n addr m.
  Proof.
    unfold anybytes. intros * B H.
    eapply anybytes_to_array_1 in H. destruct H as (bs & Hm & Hl).
    exists (List.map Byte.byte.unsigned bs).
    unfold array. eapply sep_emp_l. split.
    { rewrite List.map_length. lia. }
    eapply array_map.
    eapply impl1_array. 2: exact Hm.
    unfold impl1. eapply ptsto_to_uint8.
  Qed.

  Lemma anybytes_to_alt: forall addr n m,
      anybytes n addr m -> Memory.anybytes addr n m.
  Proof.
    unfold anybytes. intros. destruct H as (bs & H).
    unfold array in H. eapply sep_emp_l in H. destruct H as (? & H). subst n.
    eapply impl1_array in H.
    - eapply (array_map ptsto Byte.byte.of_Z addr bs (word.of_Z 1)) in H.
      eapply array_1_to_anybytes in H. rewrite List.map_length in H. exact H.
    - clear m bs addr H. unfold impl1. eapply uint8_to_ptsto.
  Qed.
End WithMem.

#[export] Hint Extern 1 (PredicateSize (anybytes ?sz)) => exact sz
: typeclass_instances.
#[export] Hint Resolve purify_anybytes : purify.
