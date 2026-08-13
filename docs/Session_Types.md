# Session Types

Compile-time protocol checking for two-party conversations.

A `Channel(protocol, msg)` from `eparch/session/core` is a handle on a conversation with one peer. The `protocol` parameter records the *whole remaining conversation* as a type. It has no runtime representation: the compiled record holds a pid, an optional monitor and some metadata, and nothing else. What it buys is that using the channel wrongly is a compile error rather than a bug you find in production.

> **Status.** `eparch/session/core`, `eparch/session/duality` and the `gen_statem` driver `eparch/protocol_machine` are implemented, as is the specification layer under `eparch/protocol`, including the generator. The examples below walk a protocol by hand, which is the shortest way to see what the types do, deriving one from a machine is done further down.

- For a worked, runnable version of everything on this page, see [`examples/atm`](https://github.com/schonfinkel/eparch/tree/main/examples/atm).
- The ATM protocol is a translation from Laumann, Munksgaard and Larsen's [Session Types for Rust](https://munksgaard.me/papers/laumann-munksgaard-larsen.pdf), it's specified once, projected onto both participants, generated into typed positions, and driven from a `gen_statem` on one side while the other walks it by hand.

## The five markers

A protocol is assembled from five uninhabited markers, each carrying its own continuation:

| Marker | Meaning |
|---|---|
| `Send(message, then)` | transmit a `message`, then continue as `then` |
| `Recv(message, then)` | accept a `message`, then continue as `then` |
| `Choose(left, right)` | *we* pick a branch, then continue as it |
| `Offer(left, right)` | *they* pick a branch, then continue as it |
| `Done` | the conversation is over |

```gleam
import eparch/session/core

pub type Greeter =
  core.Recv(
    String,
    core.Send(String, core.Choose(core.Recv(String, core.Done), core.Done)),
  )
```

Which means:
1. Take a name.
2. Answer with a greeting.
3. Then decide whether to take one more message or hang up.

Each step strips exactly one marker off the front and leaves the continuation behind, so a step cannot invent a position. It can only go where the protocol type already says.

```gleam
pub fn greeter(peer: Pid) -> core.Channel(Greeter, Wire) {
  core.begin(peer, protocol: "greeting")
}

let channel = greeter(peer)
let channel = core.receive(channel, "ada")
let #(greeting, channel) = core.send(channel, "hello ada")
let channel = core.choose_left(channel)
let channel = core.receive(channel, "bye")
let details = core.finish(channel)
```

## This layer does not own the wire

`send` hands the message back rather than transmitting it, and `receive` takes a message that has already arrived. Encoding and transport are yours, exactly as they are for `eparch/state_machine`.

```gleam
let #(greeting, channel) = core.send(channel, "hello " <> name)
process.send(client, Greeting(greeting))
```

The value that reached the wire is the same one the protocol checked, which is the reason `send` returns it instead of discarding it.

This is a deliberate limit. Doing the I/O here would mean a blocking receive, and the place these steps get called from is a `gen_statem` callback, where blocking stalls the process: timeouts do not fire, `sys:get_status/1` hangs, and supervision shutdown goes unanswered. Receiving has to be driven by events instead.

## Peer death is a message, not an exception

`watch` monitors the peer (its death then arrives like any other message), and what to do about it stays your decision. For more details, check Gleam's own docs on the [process module](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html).

```gleam
let channel = core.watch(core.begin(peer, protocol: "greeting"))
let assert Some(monitor) = core.watching(channel)

let selector =
  process.new_selector()
  |> process.select_specific_monitor(monitor, PeerDied)
```

The monitor belongs to the process that calls `watch`, so call it from the process that will own the channel, not from whoever built it. `finish` and `close` both drop it.

- `finish` only compiles at `Done`, so a participant that still owes a message cannot hang up on the other one. 
- `close` is the counterpart for giving up rather than completing, and because it is valid at any position it proves nothing about the protocol. That is why it is named differently, and why reaching for it should be a considered act.

## Duality

One participant's protocol is the other's read backwards. Every `Send` becomes a `Recv`, every `Choose` becomes an `Offer`.

Gleam has neither traits nor type-level functions (yet), so the relation cannot be computed. It can be **witnessed**, `Dual(a, b)` is a value that exists only when `a` and `b` really are dual, ecause the only way to build one is to assemble it from combinators that each encode exactly one rewriting rule.

```gleam
fn proof() -> duality.Dual(Greeter, Greeted) {
  duality.receive(
    duality.send(duality.choose(duality.receive(duality.done()), duality.done())),
  )
}
```

That function compiling works as an "informal proof". You do not have to write the other side. `opposite` takes a "proof" about `a` and opens a channel at `b`, so in practice one protocol is written by hand and the other is derived and never named:

```gleam
/// Inference gives this `Channel(Greeted, Wire)`, unwritten.
pub fn client(server: Pid) {
  duality.opposite(proof(), server, protocol: "greeting")
}
```

## The rejection catalogue

Here we catalog some example of "protocol type failures". Every example assumes:

```gleam
pub type Greeter =
  core.Recv(String, core.Send(String, core.Done))

pub fn greeter() -> core.Channel(Greeter, String) {
  core.begin(process.self(), protocol: "greeting")
}
```

### 1. Sending when the protocol says receive

```gleam
let #(_m, _c) = core.send(greeter(), "hello")
```

```
error: Type mismatch
Expected type:
    core.Channel(core.Send(String, a), b)
Found type:
    core.Channel(core.Recv(String, core.Send(String, core.Done)), String)
```

### 2. Receiving when the protocol says send

```gleam
let c = core.receive(greeter(), "ada")
let _c = core.receive(c, "again")
```

```
error: Type mismatch
Expected type:
    core.Channel(core.Recv(String, a), b)
Found type:
    core.Channel(core.Send(String, core.Done), String)
```

### 3. Hanging up while still owing a message

```gleam
core.finish(greeter())
```

```
error: Type mismatch
Expected type:
    core.Channel(core.Done, a)
Found type:
    core.Channel(core.Recv(String, core.Send(String, core.Done)), String)
```

### 4. Sending the wrong payload type

```gleam
let c = core.receive(greeter(), "ada")
let #(_m, _c) = core.send(c, 42)
```

```
error: Type mismatch
Expected type:
    String
Found type:
    Int
```

### 5. Choosing a branch that is the peer's to choose

```gleam
let c: core.Channel(core.Offer(core.Done, core.Done), String) =
  core.begin(process.self(), protocol: "b")
let _ = core.choose_left(c)
```

```
error: Type mismatch
Expected type:
    core.Channel(core.Choose(a, b), c)
Found type:
    core.Channel(core.Offer(core.Done, core.Done), String)
```

### 6. A duality witness that does not hold

Here the "other side" mistakenly receives first as well, so the two protocols do not fit together and the witness cannot be built.

```gleam
pub type Wrong =
  core.Recv(String, core.Send(String, core.Done))

pub fn proof() -> duality.Dual(Greeter, Wrong) {
  duality.receive(duality.send(duality.done()))
}
```

```
error: Type mismatch
The type of this returned value doesn't match the return type
annotation of this function.

Expected type:
    duality.Dual(core.Recv(String, core.Send(String, core.Done)), core.Recv(String, core.Send(String, core.Done)))
Found type:
    duality.Dual(core.Recv(String, core.Send(String, core.Done)), core.Send(String, core.Recv(String, core.Done)))
```

### 7. Leaving a branch of an `Offer` unhandled

Not a session-types rule at all, just Gleam's ordinary `case` exhaustiveness at the point the incoming message is narrowed. 

```gleam
case signal {
  CarryOn -> core.finish(core.offered_left(channel))
  // HangUp arm deleted
}
```

```
error: Inexhaustive patterns
This case expression does not have a pattern for all possible values. If it
is run on one of the values without a pattern then it will crash.
```

### 8. A machine transition at the wrong position

The same discipline applies inside a `protocol_machine` handler, because the transition constructors take the channel they apply to. Here the protocol says receive, and the handler tries to transmit:

```gleam
pm.state(tag: AwaitingName, at: channel, data: Nil, handler: fn(_e, channel, _d) {
  pm.transmit(at: channel, message: "hello", actions: [], then: fn(_m, _n) { ... })
})
```

```
error: Type mismatch
Expected type:
    Channel(core.Send(String, a), b)
Found type:
    Channel(core.Recv(String, core.Send(String, core.Done)), protocol.Wire)
```

`complete` before `Done` and `pick_left` at an `Offer` fail the same way.

### 9. A continuation that returns the wrong next position

The strongest of the machine's checks, and the one worth understanding. A transition's continuation type is *derived from the protocol*, never written down, so a handler that hands back a state at the wrong position cannot compile:

```gleam
pm.accept(at: channel, message: "ada", actions: [], then: fn(_next) {
  // After accepting we are at Send(String, Done), but this returns a state
  // built at the original position.
  awaiting_name(channel)
})
```

```
error: Type mismatch
Expected type:
    fn(Channel(core.Send(String, core.Done), protocol.Wire)) ->
      pm.ProtocolState(core.Send(String, core.Done), protocol.Tag, Nil, protocol.Wire, Nil)
```

### 10. Reaching for a branch before arriving at the choice

The first of two entries about *generated* positions, produced by `eparch/protocol/emit` for protocols that repeat. Generated markers are flat names rather than nested markers, which makes these errors the most readable in this catalogue: they name the position you are at and the one you assumed.

```gleam
let channel = customer.begin(teller)
// The card has not been sent yet, so the choice has not been reached.
core.send(customer.session_deposit(channel), 100)
```

```
error: Type mismatch
Expected type:
    core.Channel(customer.Session, a)

Found type:
    core.Channel(customer.Greeting, b)
```

### 11. Hanging up part way round a loop

A loop makes this failure possible in a way a straight-line protocol does not:

- `Session` is a position the conversation returns to over and over, and leaving from it is only legal through the arm that says so.

```gleam
let #(_card, channel) = core.send(customer.greeting(channel), "4111")
// At `Session`. The way out is `session_quit`, not the door.
core.finish(customer.ended(channel))
```

```
error: Type mismatch
Expected type:
    core.Channel(customer.Ended, a)

Found type:
    core.Channel(customer.Session, b)
```

## Composing Protocols

Sequencing two protocols means putting one where the other's `Done` was. That is a substitution, and Gleam cannot perform substitutions on types. It does not have to: if a fragment leaves a hole for its continuation, sequencing is filling the hole.

```gleam
pub type Request(question, answer, then) =
  core.Send(question, core.Recv(answer, then))

/// Ask twice, then stop. No combinator involved.
pub type AskTwice =
  Request(String, Int, Request(String, Int, core.Done))
```

The "proofs" compose the same way, because a fragment's witness takes its continuation's witness:

```gleam
patterns.request(patterns.request(duality.done()))
```

**What this cannot do is interleave.** Filling a hole puts one protocol after another. It cannot weave two together, which is what you need when a service and its authentication advance in step: login before the menu, a fresh second factor per payment. No arrangement of `then` parameters expresses that, because each protocol constrains the other in both directions. See the note under Limits.

## Protocols that repeat, and protocols with more than two participants

Everything above is a type. That is what makes it checked by the compiler, and it is also what puts two things out of reach.

A protocol that repeats would need a type alias defined in terms of itself, and Gleam rejects that outright:

```
error: Type cycle
This type alias is defined in terms of itself.
```

And a `Channel` has exactly one peer, so three participants cannot be described at all. `eparch/protocol` answers both by not being a type. A protocol is written as an ordinary Gleam value, checked and projected before compilation rather than during it:

```gleam
spec.Protocol(
  name: "atm",
  roles: ["Customer", "Teller"],
  initial: "Greeting",
  imports: ["import atm/money.{type Amount, type CardId}"],
  spec: spec.Message(
    from: "Customer", to: "Teller", label: "card", payload: "CardId",
    then: spec.Loop("session", spec.Choice(at: "Customer", to: "Teller", branches: [
      spec.Branch("deposit", "Amount", spec.Message(
        from: "Teller", to: "Customer", label: "balance", payload: "Amount",
        then: spec.Continue("session"),
      )),
      spec.Branch("quit", "Nil", spec.End),
    ])),
  ),
)
```

`graph.compile` checks it and projects it onto every participant, flattening the loop into a state graph with an edge back to an earlier state. Nothing self-referential is produced, so the type cycle never arises.

```gleam
let assert Ok([customer, teller]) = graph.compile(atm())
```

### Being told, and merging

The interesting check is the one a two-party protocol never needs. When a participant is not told which arm of a choice was taken, it has to behave the same way either way, and `graph` rejects the specification if it cannot:

```gleam
spec.Choice(at: "Client", to: "Server", branches: [
  spec.Branch("buy", "Item", spec.Message("Server", "Bank", "charge", "Money", spec.End)),
  spec.Branch("browse", "Nil", spec.Message("Bank", "Server", "rate", "Money", spec.End)),
])
```

The bank would have to send in one arm and receive in the other, and nobody told it which. The fix is always to route the decision through the participant that needs it.

Views that differ only in what they are *willing to receive* do merge, by union. A participant ready for a message that this particular path never sends has lost nothing, and that permissiveness is what makes most three-party protocols project at all.

### Duality, equivalence and subtyping, for protocols that loop

`Dual(a, b)` is a value, and a finite value cannot witness an infinite unfolding. So once a protocol repeats there is no "proof" to build.

Over a state graph the same questions become behavioural, and behavioural questions are answered coinductively: 

- Assume the two states you care about are related, and look for a contradiction. 
- If none turns up before you run out of pairs, there was never going to be one. 

```gleam
let assert Ok([customer, teller]) = graph.compile(atm())

// The claim `duality` cannot make, because this protocol loops.
let assert Ok(_) = relations.dual(customer, teller)
```

- `relations.subtype` is capability the type-level encoding has none of, and it is the one to reach for before changing a protocol other people already speak.
- `subtype(new, old)` succeeding means every participant written against `old` keeps working.

A subtype may **offer more** and **select fewer**. Which direction is safe therefore depends on which side of the choice you are on, and this is worth stating plainly because it is easy to get backwards. Adding a branch to a protocol is safe for the participant that *handles* it and unsafe for the participant that *takes* it:

```gleam
// A teller that also handles transfers still serves every old customer.
let assert Ok(_) = relations.subtype(new_teller, old_teller)

// A customer that might ask for a transfer is not safe against an old teller.
let assert Error(_) = relations.subtype(new_customer, old_customer)
```

### From a specification to a module you can program against

`eparch/protocol/emit` turns a projected graph into Gleam source, one module per participant. That is the step that makes the specification layer worth having, because it is what lets you write a looping protocol and then *program* against it with the compiler checking every move.

```gleam
let assert Ok(modules) = emit.modules(atm(), under: "banking")
```

Each module declares one uninhabited type per position, and one function unfolding that position into the `session/core` shape the protocol says it has:

```gleam
pub type Session
pub type AtBalance

/// Accept `balance` from `Teller`, carrying `Amount`, then continue at
/// `Session`.
///
pub fn at_balance(
  channel: Channel(AtBalance, msg),
) -> Channel(core.Recv(Amount, Session), msg) {
  core.unchecked_position(channel)
}
```

Unfolding goes one level deep and the continuation is the next flat name, so the cycle that defeats a type alias never forms. `AtBalance` continues at `Session`, a position the conversation has already been through, and that back edge is the whole trick. Everything after the unfolding is ordinary: `core.receive` on that channel hands back a `Channel(Session, msg)`, ready for the next time round.

A choice of three or more arms nests, because `core` branches two ways at a time, and the generator writes a *route* per arm so nobody has to count turns:

```gleam
pub fn session_withdraw(
  channel: Channel(Session, msg),
) -> Channel(core.Send(Amount, AtCash), msg) {
  channel
  |> session
  |> core.choose_right
  |> session_otherwise
  |> core.choose_left
}
```

Driving one of these from a machine needs `protocol_machine.along`, which threads a transition through a route. One arm, one `case` clause, however wide the choice:

```gleam
case event {
  state_machine.Cast(Deposit(amount)) ->
    pm.along(at: channel, route: teller.session_deposit, step: fn(channel) {
      pm.accept(at: channel, message: amount, actions: [], then: fn(next) {
        at_balance(next, balance + amount)
      })
    })

  state_machine.Cast(Quit) ->
    pm.along(at: channel, route: teller.session_quit, step: fn(channel) { ... })
}
```

### Keeping generated modules honest

Generated code is meant to be committed, and committed generated code goes stale. `emit.review` compares what the emitter would write now against what is on disk, which is the shape a CI step wants:

```sh
gleam run -m protocol_generate check
```

It compares content rather than layout, so running `gleam format` over generated files does not make them look stale. The driver itself is about sixty lines of `simplifile` and `argv` over `emit`, and `test/protocol_generate.gleam` in this repo is meant to be copied.

### What generation costs

The generated markers are names, and nothing in Gleam relates a name to the shape it stands for. `core.unchecked_position` is what relates them, and it is unchecked because there is nothing in the language to check it against.

That is a hole, and it is public, because Gleam cannot scope a function to part of a package. Be plain about what it means: for hand-written protocols the guarantee is the compiler's, and for generated ones it is the compiler's *given* that the generated modules say what `graph.compile` said. Positions stay uninhabited and their unfoldings stay the only way past them, so a channel at a generated position still cannot go anywhere the protocol disallows. What is no longer impossible is writing `core.unchecked_position` yourself and asserting whatever you like.

Nothing distinguishes the two calls at the type level. If that matters to your project, grep for it in review: outside a generated module it should never appear.

## Limits

**No recursion in the type-level encoding.** The markers above cannot express a protocol that repeats, for the reason given in the previous section. Reach for `eparch/protocol` when a protocol loops. Its generated modules are checked by the compiler at every call site the same way hand-written ones are, but the relation between a generated name and the shape it stands for is asserted by the generator rather than checked, through `core.unchecked_position`.

**No linearity.** Gleam has no linear types, so nothing stops you keeping an old channel value and stepping it twice. What the types rule out is reaching a position you have no "proof" of (reusing a proof you already hold is ordinary aliasing). The way to get the missing discipline is to keep the channel somewhere that is *replaced* rather than copied, which is what a `gen_statem`'s data is.

**No delegation primitive.** Handing a channel to another process is sound only under linearity. The honest pattern is to send the payload and let the recipient open a channel  at the agreed position, with the sender dropping its copy by convention.

**Two parties only, in the types.** Duality is a two-party relation, and it is what makes a well-formed two-party protocol deadlock free. It says nothing about three or more participants. `eparch/protocol` describes and checks those, but a `Channel` still has one peer, so a three-party protocol is programmed as three two-party conversations.

**Deadlock freedom does not extend to loops or to three participants.** The guarantee duality buys holds for well-formed two-party protocols with no delegation and no recursion. `relations.dual` checks the same property for graphs that repeat, which is a real check, but it is a check the generator runs rather than a property the compiler enforces.

**One unchecked function.** `core.unchecked_position` moves a channel to a position nothing has established, and generated modules are the reason it is public. Gleam cannot scope a function to part of a package, so a hand-written call is possible and is indistinguishable from a generated one at the type level. It should never appear outside a generated module.

**No interleaving composition in the types.** Two protocols that must advance in step, such as a banking service and the authentication it depends on, cannot be woven together by these markers. Filling a `then` hole only puts one protocol *after* another, and the two constrain each other in both directions. `eparch/protocol/weave` does this at the specification layer instead, which is the next section.

## Weaving two protocols together

Sequencing is type application. Weaving is the other thing, and it is what you need when a service and the authentication it depends on have to advance in lockstep: the login must precede the menu, and each payment needs its own second factor.

`eparch/protocol/weave` implements some ideas from Bocchi, Orchard and Voinea's [A Theory of Composing Protocols (2022)](https://arxiv.org/pdf/2203.02461). The three annotations from `eparch/protocol/spec` are what guide it: 

- `Assert` introduces a guarantee.
- `Require` demands one and leaves it.
- `Consume` demands one and spends it.

```gleam
// Payment happens first. Dispatch consumes the guarantee that it did.
let paying = spec.Message("Buyer", "Shop", "pay", "Money", spec.Assert("paid", spec.End))
let sending = spec.Consume("paid", spec.Message("Shop", "Buyer", "item", "Link", spec.End))

let assert weave.Composition(candidates: [only], ..) =
  weave.compose(paying, sending, weave.defaults())
```

### Composition is a relation, not a function

Two protocols may have no valid weaving, one, or many. That is not something to smooth over by picking a winner: which weaving is *wanted* is a question about the domain. So `compose` returns candidates, ranked, and the way to narrow them is to add contact points rather than to guess.

Ranking is by how much the derivation had to be relaxed, which is the only thing the library can honestly judge. Every candidate carries the liberties its derivation took.

### Branching

How a choice composes is the knob worth understanding, because the strict reading returns nothing more often than you would expect.

- `Strong` composes the other protocol into every arm. An authentication protocol that grants access in one arm and refuses in the other cannot compose a service into the refusing arm, because the guarantee was never asserted there, so strong branching yields nothing at all.
- `Weak` lets an arm that genuinely cannot compose stand alone, which is exactly that case. At least one arm still has to compose, so neither protocol can be dropped entirely.
- `Correlating` pairs each arm of one protocol with the arms of the other it can compose with, instead of distributing into all of them.
- `All` permits both. Each relaxation widens the result set rather than replacing it, so nothing derivable strongly is ever lost.

### What weaving does not do

It does not check that the result projects. Weaving can easily produce a protocol some participant cannot follow, and `graph.compile` on the candidate you pick is what says so.
