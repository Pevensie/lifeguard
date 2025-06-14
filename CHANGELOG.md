# Changelog

## v3.0.0 - 2025-06-13

Lifeguard has been updated to use the new stable versions of `gleam/erlang` and
`gleam/otp`. Lifeguard was originally designed to mostly mimic the API of
`gleam/otp/actor`, as defining a single actor and defining a pool of identical
actors are similar processes.

The API for creating actors in `gleam/otp` changed significantly when the
package hit v1, and Lifeguard was updated to reflect these changes.

Consequently, Lifeguard is now much simpler to use, and using the new
supervision API and named processes has made it easier to make Lifeguard
more robust.

### Example

The recommended way to start a Lifeguard pool is with the `supervised` function. You
can use this to include the Lifeguard pool in your application's supervision tree.

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

  // Shut down the pool
  let assert Ok(Nil) = lifeguard.shutdown(pool)
}
```

### Behavioural changes

#### Panics

Like the new version of `gleam/erlang`, failing to call or send messages to Lifeguard
workers will now panic rather than returning an error result.

##### Why?

Previously, Lifeguard used the `process.try_call` function that was present in
`gleam/erlang`. However, this had the potential to cause a memory leak if the
worker did not return within the provided timeout.

The calling process would cancel its receive operation and continue, and the
worker would also continue its operation. When the worker replied to the
calling process, that message would be stuck in the caller's queue, never to
be received.

## v2.0.0 - 2025-06-01

- Fix a critical bug where the Lifeguard process would crash if a worker crashed.
  Due to the fix required for this, some information on why workers fail to start
  is currently lost, thus the `lifeguard.StartError` type no longer has the
  `lifeguard.WorkerStartError(actor.StartError)` constructor. Instead, Lifeguard
  will now mimic the bahvaiour or `supervisor:start_link` and
  `gleam/otp/supervisor.start_link` and crash if actor initialisation fails.

## v1.0.1 - 2025-01-03

- Add `broadcast` function to send a message to all workers in the pool

## v1.0.0 - 2024-12-30

- Initial release
