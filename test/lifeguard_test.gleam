import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/task
import gleeunit
import lifeguard

import logging

pub fn main() {
  logging.configure()
  gleeunit.main()
}

// Weird hack to change test timeouts, see: https://github.com/lpil/gleeunit/issues/34
pub type Timeout {
  Timeout(Float, fn() -> Nil)
}

type TestMsg {
  Send
  OkCall(reply_to: process.Subject(Result(Nil, Nil)))
  ErrorCall(reply_to: process.Subject(Result(Nil, Nil)))
  Wait(value: Int, reply_to: process.Subject(Int))
  Panic(reply_to: process.Subject(Nil))
}

fn default_handle(msg: TestMsg, _state: Nil) {
  case msg {
    Send -> actor.continue(Nil)
    OkCall(reply_to:) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(Nil)
    }
    ErrorCall(reply_to:) -> {
      process.send(reply_to, Error(Nil))
      actor.continue(Nil)
    }
    Wait(value:, reply_to:) -> {
      process.sleep(value)
      process.send(reply_to, value)
      actor.continue(Nil)
    }
    Panic(_) -> panic as "Test panic"
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
pub fn send_lifecycle_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  assert lifeguard.send(pool, Send, 1000) == Ok(Nil)

  lifeguard.shutdown(pool)
}

pub fn call_lifecycle_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  assert lifeguard.call(pool, OkCall, 1000, 100) == Ok(Ok(Nil))

  lifeguard.shutdown(pool)
}

pub fn call_larger_pool_lifecycle_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(10)
    |> lifeguard.start(1000)

  assert lifeguard.call(pool, ErrorCall, 1000, 100) == Ok(Error(Nil))

  lifeguard.shutdown(pool)
}

// Note: the trailing underscore is required to use Timeout
pub fn call_long_running_job_lifecycle_test_() {
  use <- Timeout(11_000.0)
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(10)
    |> lifeguard.start(1000)

  assert lifeguard.call(pool, Wait(10_000, _), 100, 11_000) == Ok(10_000)

  lifeguard.shutdown(pool)
}

pub fn empty_pool_fails_to_apply_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(0)
    |> lifeguard.start(1000)

  assert lifeguard.send(pool, Send, 1000)
    == Error(lifeguard.NoResourcesAvailable)

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
  process.sleep(10)

  assert lifeguard.send(pool, Send, 1000)
    == Error(lifeguard.NoResourcesAvailable)

  // Wait for the other process to finish
  assert task.try_await(handle, 1000) == Ok(Ok(1000))

  lifeguard.shutdown(pool)
}

pub fn workers_can_be_called_concurrently_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(2)
    |> lifeguard.start(1000)

  // Send a wait message that takes a long time
  let handle =
    task.async(fn() { lifeguard.call(pool, Wait(1000, _), 1000, 2000) })

  // Use a short timeout here so the call times out before the other message can
  // complete.
  assert lifeguard.call(pool, OkCall, 100, 100) == Ok(Ok(Nil))

  // Wait for the other process to finish
  assert task.try_await(handle, 1100) == Ok(Ok(1000))

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
  assert lifeguard.call(pool, Wait(10, _), 1000, 100) == Ok(10)

  lifeguard.shutdown(pool)
}

pub fn pool_handles_worker_crash_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  // Expect an error message here
  logging.set_level(logging.Critical)

  let assert Error(lifeguard.WorkerCrashed(_)) =
    lifeguard.call(pool, Panic, 1000, 100)

  process.sleep(200)

  // Reset level
  logging.configure()

  // Ensure the pool still has an available resource
  assert lifeguard.call(pool, Wait(10, _), 1000, 100) == Ok(10)

  lifeguard.shutdown(pool)
}

pub fn broadcast_test() {
  let assert Ok(pool) =
    lifeguard.new(default_spec())
    |> lifeguard.with_size(1)
    |> lifeguard.start(1000)

  lifeguard.broadcast(pool, Send)

  lifeguard.shutdown(pool)
}
