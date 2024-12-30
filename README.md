# 🛟 Lifeguard

[![Package Version](https://img.shields.io/hexpm/v/lifeguard)](https://hex.pm/packages/lifeguard)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/lifeguard/)

Lifeguard a generic actor pool for Gleam. It can be used to interface with a pool of
supervised actors without having to manage their lifecycles yourself.

## Installation

```sh
gleam add lifeguard@1
```

## Usage

```gleam
import lifeguard
import fake_db

pub fn main() {
  // Create a pool of 10 connections to some fictional database.
  let assert Ok(pool) =
    lifeguard.new(
      lifeguard.Spec(
        init_timeout: 1000,
        init: fn(selector) { actor.Ready(state: fake_db.get_conn(), selector:) },
        loop: fn(msg, state) {
          case msg {
            // Logic here...
          }
        },
      )
    )
    |> lifeguard.with_size(10)
    |> lifeguard.start(1000)

  // Send a message to the pool
  let assert Ok(Nil) =
    lifeguard.send(pool, fake_db.Ping, 1000)

  // Send a message to the pool and wait for a response
  let assert Ok(fake_db.Pong) =
    lifeguard.call(pool, fake_db.Query(_, "select 1"), 1000, 1000)

  // Shut down the pool
  lifeguard.shutdown(pool)
}
```

Further documentation can be found at <https://hexdocs.pm/lifeguard>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

## Inspiration

Lifeguard is inspired by both [poolboy](https://github.com/devinus/poolboy) and
[puddle](https://github.com/massivefermion/puddle). Thanks to the authors for their
work!
