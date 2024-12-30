import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/task
import gleeunit
import gleeunit/should
import lifeguard

import logging

pub fn main() {
  logging.configure()
  gleeunit.main()
}

type TestMsg {
  Send
  Wait(value: Int, reply_to: process.Subject(Int))
}

fn default_handle(msg: TestMsg, _state: Nil) {
  case msg {
    Send -> actor.continue(Nil)
    Wait(value:, reply_to:) -> {
      process.sleep(value)
      process.send(reply_to, value)
      actor.continue(Nil)
    }
  }
}

fn default_spec() {
  lifeguard.Spec(
    init_timeout: 1000,
    init: fn(selector) { actor.Ready(state: Nil, selector:) },
    loop: default_handle,
  )
}

// gleeunit test functions end in `_test`
pub fn lifecycle_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  lifeguard.send(pool, Send, 1000)
  |> should.equal(Ok(Nil))

  lifeguard.shutdown(pool)
}

pub fn empty_pool_fails_to_apply_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(0)
    |> lifeguard.start(1000)

  lifeguard.send(pool, Send, 1000)
  |> should.equal(Error(lifeguard.NoResourcesAvailable))

  lifeguard.shutdown(pool)
}

pub fn pool_has_correct_capacity_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  // Send a wait message that takes a long time
  let handle =
    task.async(fn() { lifeguard.call(pool, Wait(1000, _), 1000, 2000) })

  // Wait to let the other process start
  process.sleep(100)

  lifeguard.send(pool, Send, 1000)
  |> should.equal(Error(lifeguard.NoResourcesAvailable))

  // Wait for the other process to finish
  task.try_await(handle, 1000)
  |> should.equal(Ok(Ok(1000)))

  lifeguard.shutdown(pool)
}

pub fn pool_handles_caller_crash_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  // Expect an error message here
  logging.set_level(logging.Critical)

  process.start(
    fn() {
      use _ <- lifeguard.apply(pool, 1000)
      panic as "Oh no, the caller crashed!"
    },
    False,
  )

  process.sleep(1000)

  // Reset level
  logging.configure()

  // Ensure the pool still has an available resource
  lifeguard.call(pool, Wait(10, _), 1000, 100)
  |> should.equal(Ok(10))

  lifeguard.shutdown(pool)
}
