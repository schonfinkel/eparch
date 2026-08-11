////
//// The generator driver, in the shape a project is meant to copy.
////
//// `eparch/protocol/emit` writes strings and stops there, so that the library
//// itself never depends on a file system or an argument parser. This is the
//// other half, and it is deliberately small: read what the emitter produced,
//// and either put it on disk or report that what is on disk disagrees.
////
//// ```sh
//// gleam run -m protocol_generate         # write
//// gleam run -m protocol_generate check   # fail if anything is out of date
//// ```
////
//// The `check` form is what belongs in CI. It fails when a specification has
//// changed and the modules generated from it have not, which is the one thing
//// that can quietly go wrong once generated code is committed.
////
//// One liberty is taken that a real project would not need: modules land under
//// `test/` rather than `src/`, because the protocol they describe exists to be
//// tested rather than shipped.
////

import argv
import atm_protocol
import eparch/protocol/emit
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn main() -> Nil {
  let assert Ok(modules) = emit.modules(atm_protocol.atm(), under: "generated")

  case argv.load().arguments {
    ["check"] -> check(modules)
    _ -> write(modules)
  }
}

/// Where these particular modules live. A project that ships its protocols
/// would say `"src"` and think no further about it.
const root = "test"

fn write(modules: List(emit.Module)) -> Nil {
  use module <- list.each(modules)
  let path = emit.path(module, in: root)

  let assert Ok(_) = simplifile.create_directory_all(directory(path))
  let assert Ok(_) = simplifile.write(to: path, contents: module.source)

  io.println("wrote " <> path)
}

fn check(modules: List(emit.Module)) -> Nil {
  let reviews =
    emit.review(modules, against: fn(module) {
      simplifile.read(emit.path(module, in: root))
      |> result.replace_error(Nil)
    })

  list.each(reviews, fn(review) { io.println(emit.describe(review)) })

  case emit.agreed(reviews) {
    True -> Nil
    False -> panic as "generated protocol modules are out of date"
  }
}

fn directory(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}
