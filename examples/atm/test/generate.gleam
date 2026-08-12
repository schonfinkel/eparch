////
//// The generator driver: turns `atm/protocol` into the modules under
//// `src/generated/atm`.
////
//// ```sh
//// gleam run -m generate         # write them
//// gleam run -m generate check   # fail if what is on disk is out of date
//// ```
////
//// `eparch/protocol/emit` produces strings and stops there, so that the library
//// never depends on a file system or an argument parser. This is the other
//// half, and it is meant to be copied: a project's version differs only in
//// which specification it names and which root it writes under.
////
//// The `check` form is what belongs in CI. It fails when a specification has
//// changed and the modules generated from it have not, which is the one thing
//// that can quietly go wrong once generated code is committed. There is a test
//// saying the same thing in `atm_test`, so `gleam test` catches it too.
////
//// It lives in `test/` because `simplifile` and `argv` are dev dependencies:
//// generating is something a developer does, not something the shipped
//// application does.
////

import argv
import atm/protocol
import eparch/protocol/emit
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Where the generated modules live, as a module path and as a source root.
///
/// `src`, because this protocol is part of what the application ships. A
/// protocol that only its tests used would say `test` and change nothing else.
pub const root = "src"

/// The module path generated modules go under, so they are visibly not
/// hand-written. Everything below it is written by the generator and nothing
/// else belongs there.
pub const prefix = "generated"

pub fn main() -> Nil {
  let assert Ok(modules) = emit.modules(protocol.atm(), under: prefix)

  case argv.load().arguments {
    ["check"] -> check(modules)
    _ -> write(modules)
  }
}

fn write(modules: List(emit.Module)) -> Nil {
  use module <- list.each(modules)
  let path = emit.path(module, in: root)

  let assert Ok(_) = simplifile.create_directory_all(directory(path))
  let assert Ok(_) = simplifile.write(to: path, contents: module.source)

  io.println("wrote " <> path)
}

fn check(modules: List(emit.Module)) -> Nil {
  let reviews = emit.review(modules, against: on_disk)

  list.each(reviews, fn(review) { io.println(emit.describe(review)) })

  case emit.agreed(reviews) {
    True -> Nil
    False -> panic as "generated protocol modules are out of date"
  }
}

/// Read a generated module's file, for `emit.review` to compare against.
///
/// Exported because the test suite asks the same question, and asking it two
/// different ways is how the answers drift.
///
pub fn on_disk(module: emit.Module) -> Result(String, Nil) {
  simplifile.read(emit.path(module, in: root))
  |> result.replace_error(Nil)
}

fn directory(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}
