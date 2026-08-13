////
//// The payload types the specification names.
////
//// A specification holds payload types as *strings*, because Gleam has no type
//// reflection and a specification is an ordinary value. The only thing that
//// resolves those strings is the `imports` line the specification carries, so
//// the two have to be kept in agreement. Keeping the types in one small module
//// named by that import line is what makes the agreement easy to see.
////
//// These are the paper's `type Id = String` and its `u64` amounts, under names
//// that read better in generated code.
////

/// The number on the card the client puts in the machine.
///
pub type CardId =
  String

/// Money, in whole units of whatever the machine is stocked with.
///
/// The paper uses `u64`. Gleam's `Int` is arbitrary precision and signed, which
/// is why `withdraw` below has an overdraft check the Rust version could get
/// away with leaving to the type.
///
pub type Amount =
  Int
