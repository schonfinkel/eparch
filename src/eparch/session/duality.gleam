//// Proof that two participants' protocols fit together.
////
//// `eparch/session/core` tracks *where one participant is*. This module adds
//// the other half: what the two owe each other, and a way to prove that the
//// two halves agree.
////
//// The customer's protocol is the teller's read backwards. Every `Send`
//// becomes a `Recv`, every `Choose` becomes an `Offer`. That relation is what
//// makes two participants safe to connect, and it is the reason session types
//// are worth having at all.
////
//// | Server | Client |
//// |---|---|
//// | `Send(message, then)` | `Recv(message, dual_of_then)` |
//// | `Recv(message, then)` | `Send(message, dual_of_then)` |
//// | `Choose(left, right)` | `Offer(dual_of_left, dual_of_right)` |
//// | `Offer(left, right)` | `Choose(dual_of_left, dual_of_right)` |
//// | `Done` | `Done` |
////
//// Gleam (currently) has neither traits, macros nor type-level functions, so 
//// the relation cannot be computed. What it can be is **witnessed**: `Dual(a, b)` 
//// is a value that exists only when `a` and `b` really are dual, because the 
//// only way to build one is to assemble it from the combinators below, and 
//// each of those encodes exactly one row of the table.
////
//// ```gleam
//// pub fn atm_duality() -> duality.Dual(AtmTeller, AtmCustomer) {
////   duality.receive(
////     duality.choose(
////       duality.offer(
////         duality.receive(duality.send(duality.done())),
////         duality.receive(duality.choose(duality.done(), duality.done())),
////       ),
////       duality.done(),
////     ),
////   )
//// }
//// ```
////
//// That function compiling *is* the proof. Get one line wrong and the
//// mismatch is reported where you wrote it. Note that this whole part is
//// still a WIP for this library.
////
//// ## You do not have to write the other side
////
//// The second parameter of a witness can be left to inference. `opposite`
//// takes a proof about `a` and opens a channel at `b`, so in practice one
//// protocol is written by hand and the other is derived and never named:
////
//// ```gleam
//// /// Inference gives this `Channel(Patron, Request)`, unwritten.
//// pub fn customer(teller: Pid) {
////   duality.opposite(atm_duality(), teller, protocol: "atm")
//// }
//// ```
////
//// ## Scope
////
//// Duality is a two-party relation, and it is what makes a well-formed
//// two-party protocol deadlock free. It says nothing about three or more
//// participants, and nothing about protocols that repeat. Neither is covered
//// by a witness, so neither inherits the guarantee.
////

import eparch/session/core.{type Channel}
import gleam/erlang/process.{type Pid}

/// A proof that `a` and `b` are dual protocols.
///
/// The type is opaque and its only constructors are the combinators in this
/// module, each of which mirrors one rewriting rule. So a value of type
/// `Dual(a, b)` can only exist if the two protocols really do fit together,
/// which makes the witness worth requiring wherever two participants are
/// connected.
///
/// It carries no data and costs nothing at run time.
///
/// ## Example
///
/// ```gleam
/// /// Only compiles if `Customer` is exactly the reverse of `Teller`.
/// pub fn proof() -> duality.Dual(Teller, Customer) {
///   duality.receive(duality.send(duality.done()))
/// }
/// ```
///
pub opaque type Dual(a, b) {
  Dual
}

/// `Dual(Done) = Done`. The base case: two participants that owe each other
/// nothing agree trivially.
///
/// ## Example
///
/// ```gleam
/// let proof: Dual(core.Done, core.Done) = duality.done()
/// ```
///
pub fn done() -> Dual(core.Done, core.Done) {
  Dual
}

/// `Dual(Send(m, s)) = Recv(m, Dual(s))`. One side transmits exactly when the
/// other accepts, and the message type has to agree.
///
/// ## Example
///
/// ```gleam
/// /// Dual(Send(Int, Done), Recv(Int, Done))
/// let proof = duality.send(duality.done())
/// ```
///
pub fn send(
  then: Dual(a, b),
) -> Dual(core.Send(message, a), core.Recv(message, b)) {
  let Dual = then
  Dual
}

/// `Dual(Recv(m, s)) = Send(m, Dual(s))`.
///
/// ## Example
///
/// ```gleam
/// /// Dual(Recv(Int, Done), Send(Int, Done))
/// let proof = duality.receive(duality.done())
/// ```
///
pub fn receive(
  then: Dual(a, b),
) -> Dual(core.Recv(message, a), core.Send(message, b)) {
  let Dual = then
  Dual
}

/// `Dual(Choose(l, r)) = Offer(Dual(l), Dual(r))`. When one side picks, the
/// other must be ready for either answer, so both branches need their own
/// proof.
///
/// ## Example
///
/// ```gleam
/// /// Dual(Choose(Done, Done), Offer(Done, Done))
/// let proof = duality.choose(duality.done(), duality.done())
/// ```
///
pub fn choose(
  left: Dual(a, b),
  right: Dual(c, d),
) -> Dual(core.Choose(a, c), core.Offer(b, d)) {
  let Dual = left
  let Dual = right
  Dual
}

/// `Dual(Offer(l, r)) = Choose(Dual(l), Dual(r))`.
///
/// ## Example
///
/// ```gleam
/// /// Dual(Offer(Done, Done), Choose(Done, Done))
/// let proof = duality.offer(duality.done(), duality.done())
/// ```
///
pub fn offer(
  left: Dual(a, b),
  right: Dual(c, d),
) -> Dual(core.Offer(a, c), core.Choose(b, d)) {
  let Dual = left
  let Dual = right
  Dual
}

/// Read a "proof" from the other participant's point of view.
///
/// Duality is symmetric, so a proof that the teller and the customer agree is
/// equally a proof that the customer and the teller do. Useful for handing the
/// same witness to code written from either side without building it twice.
///
/// ## Example
///
/// ```gleam
/// pub fn customer_view() -> Dual(AtmCustomer, AtmTeller) {
///   duality.flip(atm_duality())
/// }
/// ```
///
pub fn flip(proof: Dual(a, b)) -> Dual(b, a) {
  let Dual = proof
  Dual
}

/// Open a channel on the other side of a proof.
///
/// The protocol `b` comes from the witness rather than from an annotation, so
/// the second participant is *derived*: it never has to be written down.
///
/// This is also the one way to reach a position without writing the annotation
/// that `core.begin` requires, and it is sound precisely because the witness
/// already pinned it.
///
/// ## Example
///
/// ```gleam
/// /// Inference gives this `Channel(Patron, Request)`.
/// pub fn approach(teller: Pid) {
///   duality.opposite(protocol.duality(), teller, protocol: "atm")
/// }
/// ```
///
pub fn opposite(
  proof: Dual(a, b),
  peer: Pid,
  protocol protocol_name: String,
) -> Channel(b, msg) {
  let Dual = proof
  core.begin(peer, protocol: protocol_name)
}

/// Pair two participants whose protocols are proven to fit together.
///
/// The witness does the work. Because `a` and `b` are bound by the proof
/// rather than by annotations, two participants that disagree cannot be passed
/// to this function at all, and neither protocol has to be named at the call
/// site. Reach for `opposite` instead when the second participant does not
/// exist yet and should be derived.
///
/// This is a compile-time pairing only. It moves no data and opens no
/// connection; connecting the two participants for real is the transport's
/// job.
///
/// ## Example
///
/// ```gleam
/// let #(teller, customer) =
///   duality.connect(protocol.duality(), open_till(), approach(till))
/// ```
///
pub fn connect(
  proof: Dual(a, b),
  left: Channel(a, left_msg),
  right: Channel(b, right_msg),
) -> #(Channel(a, left_msg), Channel(b, right_msg)) {
  let Dual = proof
  #(left, right)
}
