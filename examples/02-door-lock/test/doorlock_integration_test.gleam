////
//// Integration tests for the door lock state machine.
////
//// These tests spawn a real gen_statem process and exercise the full
//// message-passing lifecycle: `enter_code`, `get_status`, and the
//// auto-lock state timeout.
////
//// The auto-lock timeout is set to 100 ms (via `start_with_lock_timeout`)
//// so timeout tests complete quickly without sleeping for 5 seconds.
////

import gleam/erlang/process
import gleeunit/should
import doorlock

// Constants & Helpers
const code = "secret"

/// Start a lock with the default 5-second auto-lock.
fn start() -> process.Subject(doorlock.Message) {
  let assert Ok(machine) = doorlock.start(code)
  machine.data
}

/// Start a lock with a short auto-lock for timeout tests.
fn start_fast() -> process.Subject(doorlock.Message) {
  let assert Ok(machine) = doorlock.start_with_lock_timeout(code, 100)
  machine.data
}

// Tests
/// A freshly started lock is in the Locked state.
pub fn initial_state_is_locked_test() {
  let subject = start()
  doorlock.get_status(subject) |> should.equal(doorlock.Locked)
}

/// The correct code unlocks the door and the status becomes Open.
pub fn correct_code_opens_the_lock_test() {
  let subject = start()

  doorlock.enter_code(subject, code) |> should.equal(Ok(Nil))
  doorlock.get_status(subject) |> should.equal(doorlock.Open)
}

/// A wrong code returns an error and the door stays Locked.
pub fn wrong_code_stays_locked_test() {
  let subject = start()

  doorlock.enter_code(subject, "wrong") |> should.equal(Error("Wrong code"))
  doorlock.get_status(subject) |> should.equal(doorlock.Locked)
}

/// Multiple wrong codes all return errors; the door remains Locked throughout.
pub fn multiple_wrong_codes_stay_locked_test() {
  let subject = start()

  doorlock.enter_code(subject, "aaa") |> should.equal(Error("Wrong code"))
  doorlock.enter_code(subject, "bbb") |> should.equal(Error("Wrong code"))
  doorlock.enter_code(subject, "ccc") |> should.equal(Error("Wrong code"))
  doorlock.get_status(subject) |> should.equal(doorlock.Locked)
}

/// When the door is already Open, entering a code returns Ok(Nil) without
/// locking again (the auto-lock timer resets instead).
pub fn enter_code_while_open_returns_ok_test() {
  let subject = start()

  doorlock.enter_code(subject, code) |> should.equal(Ok(Nil))
  // Door is now Open; entering code again should not error or deadlock.
  doorlock.enter_code(subject, code) |> should.equal(Ok(Nil))
  doorlock.get_status(subject) |> should.equal(doorlock.Open)
}

/// After the auto-lock timeout fires, the door transitions back to Locked.
pub fn auto_lock_relocks_after_timeout_test() {
  let subject = start_fast()

  doorlock.enter_code(subject, code) |> should.equal(Ok(Nil))
  doorlock.get_status(subject) |> should.equal(doorlock.Open)

  // Wait long enough for the 100 ms state timeout to fire.
  process.sleep(250)

  doorlock.get_status(subject) |> should.equal(doorlock.Locked)
}

/// After auto-lock, the correct code can re-open the door.
pub fn can_reopen_after_auto_lock_test() {
  let subject = start_fast()

  doorlock.enter_code(subject, code) |> should.equal(Ok(Nil))
  process.sleep(250)
  doorlock.get_status(subject) |> should.equal(doorlock.Locked)

  doorlock.enter_code(subject, code) |> should.equal(Ok(Nil))
  doorlock.get_status(subject) |> should.equal(doorlock.Open)
}
