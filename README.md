# 🛟 Lifeguard

[![Package Version](https://img.shields.io/hexpm/v/lifeguard)](https://hex.pm/packages/lifeguard)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/lifeguard/)

Lifeguard a generic actor pool for Gleam. It can be used to interface with a pool of
supervised actors without having to manage their lifecycles yourself.

## Installation

```sh
gleam add lifeguard@3
```

## Usage

```gleam
import fake_db
import gleam/otp/static_supervisor as supervisor
import lifeguard

pub fn main() {
  let pool_receiver = process.new_subject()

  // Define a pool of 10 connections to some fictional database, and create a child
  // spec to allow it to be supervised.
  let lifeguard_child_spec =
    lifeguard.new(fake_db.get_conn())
    |> lifeguard.on_message(fn(state, msg) {
        case msg {
          fake_db.Ping(reply_to:) -> {
            process.send(reply_to, fake_db.Pong)
            actor.continue(state)
          }
          _ -> todo
        }
      })
    |> lifeguard.size(10)
    |> lifeguard.supervised(pool_receiver, 1000)

  // Start the pool under a supervisor
  let assert Ok(_started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(lifeguard_child_spec)
    |> supervisor.start

  // Receive the pool handle now that it's started
  let assert Ok(pool) = process.receive(pool_receiver, 1000)

  // Send a message to the pool
  let assert Ok(Nil) =
    lifeguard.send(pool, fake_db.Ping, 1000)

  // Send a message to the pool and wait for a response
  let assert Ok(fake_db.Pong) =
    lifeguard.call(pool, fake_db.Ping, 1000, 1000)

  // Do more stuff...
}
```

Further documentation can be found at <https://hexdocs.pm/lifeguard>.

## Development

If you've found any bugs, please open an issue on
[GitHub](https://github.com/Pevensie/lifeguard/issues).

The code is reasonably well tested and documented, but PRs to improve either are always
welcome.

```sh
gleam test  # Run the tests
```

## Inspiration

Lifeguard is inspired by both [poolboy](https://github.com/devinus/poolboy) and
[puddle](https://github.com/massivefermion/puddle). Thanks to the authors for their
work!
