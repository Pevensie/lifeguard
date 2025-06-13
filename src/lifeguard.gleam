import gleam/deque
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/otp/supervision
import gleam/result

const pool_name_prefix = "lifeguard_pool"

// ---- Pool config ----- //

/// An actor spec for workers in a pool. Similar to [`actor.Spec`](https://hexdocs.pm/gleam_otp/gleam/otp/actor.html#Spec),
/// but this provides the initial selector for the actor. It will select on its own
/// subject by default, using `function.identity` to pass the message straight through.
///
/// For clarity, it will be used as follows by Lifeguard:
///
/// ```gleam
/// actor.Spec(init_timeout: spec.init_timeout, loop: spec.loop, init: fn() {
///   // Check in the worker
///   let self = process.new_subject()
///   process.send(pool_subject, Register(self)) // Register the worker with the pool
///
///   let selector =
///     process.new_selector()
///     |> process.selecting(self, function.identity)
///
///   spec.init(selector)
/// })
/// ```
// pub type Spec(state, msg) {
//   Spec(
//     init: fn(process.Selector(msg)) -> actor.InitResult(state, msg),
//     init_timeout: Int,
//     loop: fn(msg, state) -> actor.Next(msg, state),
//   )
// }

/// The strategy used to check out a resource from the pool.
pub type CheckoutStrategy {
  FIFO
  LIFO
}

pub opaque type Initialised(state, msg) {
  Initialised(state: state, selector: option.Option(process.Selector(msg)))
}

pub fn initialised(state: state) -> Initialised(state, msg) {
  Initialised(state: state, selector: None)
}

pub fn selecting(
  initialised: Initialised(state, msg),
  selector: process.Selector(msg),
) -> Initialised(state, msg) {
  Initialised(..initialised, selector: Some(selector))
}

/// Configuration for a [`Pool`](#Pool).
pub opaque type PoolConfig(state, msg) {
  PoolConfig(
    size: Int,
    checkout_strategy: CheckoutStrategy,
    init: fn() -> Result(Initialised(state, msg), String),
    init_timeout: Int,
    loop: fn(state, msg) -> actor.Next(state, msg),
  )
}

/// Create a new [`PoolConfig`](#PoolConfig) for creating a pool of actors.
///
/// ```gleam
/// import lifeguard
///
/// pub fn main() {
///   // Create a pool of 10 actors that do nothing.
///   let assert Ok(pool) =
///     lifeguard.new(
///       lifeguard.Spec(
///         init_timeout: 1000,
///         init: fn(selector) { actor.Ready(state: Nil, selector:) },
///         loop: fn(msg, state) { actor.continue(state) },
///       )
///     )
///     |> lifeguard.with_size(10)
///     |> lifeguard.start(1000)
/// }
/// ```
///
/// ### Default values
///
/// | Config | Default |
/// |--------|---------|
/// | `size`   | 10      |
/// | `checkout_strategy` | `FIFO` |
pub fn new(state: state) -> PoolConfig(state, msg) {
  PoolConfig(
    size: 10,
    checkout_strategy: FIFO,
    init: fn() { Ok(initialised(state)) },
    init_timeout: 1000,
    loop: fn(state, _) { actor.continue(state) },
  )
}

pub fn new_with_initialiser(
  timeout: Int,
  initialiser: fn() -> Result(Initialised(state, msg), String),
) -> PoolConfig(state, msg) {
  PoolConfig(
    size: 10,
    checkout_strategy: FIFO,
    init: initialiser,
    init_timeout: timeout,
    loop: fn(state, _) { actor.continue(state) },
  )
}

pub fn on_message(
  config pool_config: PoolConfig(state, msg),
  handler handler: fn(state, msg) -> actor.Next(state, msg),
) {
  PoolConfig(..pool_config, loop: handler)
}

/// Set the number of actors in the pool. Defaults to 10.
pub fn with_size(
  config pool_config: PoolConfig(state, msg),
  size size: Int,
) -> PoolConfig(state, msg) {
  PoolConfig(..pool_config, size:)
}

/// Set the order in which actors are checked out from the pool. Defaults to `FIFO`.
pub fn with_checkout_strategy(
  config pool_config: PoolConfig(state, msg),
  strategy checkout_strategy: CheckoutStrategy,
) -> PoolConfig(state, msg) {
  PoolConfig(..pool_config, checkout_strategy:)
}

// ----- Lifecycle functions ---- //

/// An error returned when failing to use a pooled worker.
pub type ApplyError {
  NoResourcesAvailable
  WorkerCrashed(process.Down)
}

/// Start a pool supervision tree using the given [`PoolConfig`](#PoolConfig) and return a
/// [`Pool`](#Pool).
///
/// Note: this function mimics the behaviour of `supervisor:start_link` and
/// `gleam/otp/static_supervisor`'s `start_link` function and will exit the process if
/// any of the workers fail to start.
fn start_tree(
  pool_name: process.Name(PoolMsg(msg)),
  pool_config: PoolConfig(state, msg),
  init_timeout: Int,
) -> Result(actor.Started(sup.Supervisor), actor.StartError) {
  // The supervision tree for pools looks like this:
  // supervisor (rest for one)
  // |        |
  // |        |
  // pool  supervisor (one for one)
  //        |  |  |
  //       /   |   \
  //      /    |    \
  // worker  worker  worker

  let main_supervisor = sup.new(sup.RestForOne)
  let worker_supervisor = sup.new(sup.OneForOne)

  // Add workers to the worker supervisor
  let worker_supervisor_spec =
    supervision.supervisor(fn() {
      list.repeat("", pool_config.size)
      |> list.fold(worker_supervisor, fn(worker_supervisor, _) {
        sup.add(worker_supervisor, worker_spec(pool_name, pool_config))
      })
      |> sup.start
    })

  // Add the pool and worker supervisors to the main supervisor
  main_supervisor
  |> sup.add(pool_spec(pool_config, pool_name, init_timeout))
  |> sup.add(worker_supervisor_spec)
  |> sup.start()
}

/// Start a pool supervision tree using the given [`PoolConfig`](#PoolConfig) and return a
/// [`Pool`](#Pool).
///
/// Note: this function mimics the behaviour of `supervisor:start_link` and
/// `gleam/otp/static_supervisor`'s `start_link` function and will exit the process if
/// any of the workers fail to start.
pub fn start(
  config pool_config: PoolConfig(state, msg),
  timeout init_timeout: Int,
) -> Result(Pool(msg), actor.StartError) {
  let pool_name = process.new_name(pool_name_prefix)

  start_tree(pool_name, pool_config, init_timeout)
  |> result.replace(Pool(name: pool_name))
}

pub fn supervised(
  config pool_config: PoolConfig(state, msg),
  receive_to pool_subject: process.Subject(Pool(msg)),
  timeout init_timeout: Int,
) -> supervision.ChildSpecification(sup.Supervisor) {
  let pool_name = process.new_name(pool_name_prefix)
  supervision.supervisor(fn() {
    use supervisor <- result.try(start_tree(
      pool_name,
      pool_config,
      init_timeout,
    ))

    process.send(pool_subject, Pool(name: pool_name))
    Ok(supervisor)
  })
}

/// Get the supervisor PID for a running pool.
pub fn pid(pool pool: Pool(resource_type)) -> Result(Pid, Nil) {
  process.named(pool.name)
}

fn check_out(
  pool: Pool(resource_type),
  caller: Pid,
  timeout: Int,
) -> Result(Worker(resource_type), ApplyError) {
  process.call(process.named_subject(pool.name), timeout, CheckOut(_, caller:))
}

fn check_in(pool: Pool(msg), worker: Worker(msg), caller: Pid) {
  process.send(process.named_subject(pool.name), CheckIn(worker:, caller:))
}

@internal
pub fn apply(
  pool: Pool(msg),
  timeout: Int,
  next: fn(Subject(msg)) -> result_type,
) -> Result(result_type, ApplyError) {
  let self = process.self()
  use worker <- result.try(check_out(pool, self, timeout))

  let result = next(worker.subject)

  check_in(pool, worker, self)

  Ok(result)
}

/// Send a message to a pooled actor. Equivalent to `process.send` using a pooled actor.
pub fn send(
  pool pool: Pool(msg),
  msg msg: msg,
  checkout_timeout checkout_timeout: Int,
) -> Result(Nil, ApplyError) {
  apply(pool, checkout_timeout, process.send(_, msg))
}

/// Send a message to a pooled actor and wait for a response. Equivalent to `process.call`
/// using a pooled actor.
pub fn call(
  pool pool: Pool(msg),
  msg msg: fn(Subject(return_type)) -> msg,
  checkout_timeout checkout_timeout: Int,
  call_timeout call_timeout: Int,
) -> Result(return_type, ApplyError) {
  // apply(pool, checkout_timeout, fn(subj) {
  //   rescue_exits(fn() { process.call(subj, call_timeout, msg) })
  //   |> echo
  //   |> result.map_error(WorkerCrashed)
  // })
  // |> result.flatten

  apply(pool, checkout_timeout, fn(subj) {
    call_recover(subj, call_timeout, msg)
    |> result.map_error(WorkerCrashed)
  })
  |> result.flatten
}

/// Send a message to all pooled actors, regardless of checkout status.
pub fn broadcast(pool pool: Pool(msg), msg msg: msg) -> Nil {
  process.named_subject(pool.name)
  |> process.send(Broadcast(msg))
}

/// Shut down a pool and all its workers. Fails if the pool is not currently running.
pub fn shutdown(pool pool: Pool(msg)) {
  process.named(pool.name)
  |> result.map(process.send_exit)
}

// ----- Pool ----- //

/// The interface for interacting with a pool of workers in Lifeguard.
pub opaque type Pool(msg) {
  Pool(name: process.Name(PoolMsg(msg)))
}

type State(msg) {
  State(
    workers: deque.Deque(Worker(msg)),
    checkout_strategy: CheckoutStrategy,
    live_workers: LiveWorkers(msg),
    selector: process.Selector(PoolMsg(msg)),
  )
}

type LiveWorkers(msg) =
  Dict(Pid, LiveWorker(msg))

type LiveWorker(msg) {
  LiveWorker(worker: Worker(msg), caller: Pid, caller_monitor: process.Monitor)
}

type PoolMsg(msg) {
  Register(worker_subject: Subject(msg))
  CheckIn(worker: Worker(msg), caller: Pid)
  CheckOut(reply_to: Subject(Result(Worker(msg), ApplyError)), caller: Pid)
  WorkerDown(process.Down)
  CallerDown(process.Down)
  Broadcast(msg)
}

fn handle_pool_message(state: State(resource_type), msg: PoolMsg(resource_type)) {
  case msg {
    Register(worker_subject:) -> {
      // We can't register processes that don't exist, so if subject_owner returns
      // an Error, we just exit early

      let pid_result =
        worker_subject
        |> process.subject_owner
        |> result.replace_error(actor.continue(state))

      case pid_result {
        Error(_) -> actor.continue(state)
        Ok(worker_pid) -> {
          let monitor = process.monitor(worker_pid)
          let selector =
            state.selector
            |> process.select_specific_monitor(monitor, WorkerDown)

          let new_worker = Worker(subject: worker_subject, monitor:)

          State(
            ..state,
            workers: deque.push_back(state.workers, new_worker),
            selector:,
          )
          |> actor.continue
          |> actor.with_selector(selector)
        }
      }
    }
    CheckIn(worker:, caller:) -> {
      // If the checked-in process is a currently live worker, remove it from
      // the live_workers dict
      let caller_live_worker = dict.get(state.live_workers, caller)
      let live_workers = dict.delete(state.live_workers, caller)

      let selector = case caller_live_worker {
        // If this was a live worker, demonitor the caller
        Ok(live_worker) -> {
          process.demonitor_process(live_worker.caller_monitor)
          state.selector
          |> process.deselect_specific_monitor(live_worker.caller_monitor)
        }
        Error(_) -> state.selector
      }

      let new_workers = deque.push_back(state.workers, worker)

      State(..state, workers: new_workers, live_workers:, selector:)
      |> actor.continue
      |> actor.with_selector(selector)
    }
    CheckOut(reply_to:, caller:) -> {
      // We always push to the back, so for FIFO, we pop front,
      // and for LIFO, we pop back
      let get_result = case state.checkout_strategy {
        FIFO -> deque.pop_front(state.workers)
        LIFO -> deque.pop_back(state.workers)
      }

      case get_result {
        Ok(#(worker, new_workers)) -> {
          // Start monitoring the caller
          let caller_monitor = process.monitor(caller)
          let selector =
            state.selector
            |> process.select_specific_monitor(caller_monitor, CallerDown)

          let live_workers =
            dict.insert(
              state.live_workers,
              caller,
              LiveWorker(worker:, caller:, caller_monitor:),
            )

          actor.send(reply_to, Ok(worker))

          State(..state, workers: new_workers, live_workers:, selector:)
          |> actor.continue
          |> actor.with_selector(selector)
        }
        Error(_) -> {
          actor.send(reply_to, Error(NoResourcesAvailable))
          actor.continue(state)
        }
      }
    }
    CallerDown(process_down) -> {
      // If the process existed in the live workers dict (i.e. it had a checked out
      // worker), demonitor it and delete it from the dict. Return the worker to the
      // pool.

      // This is safe as we don't monitor ports
      let assert process.ProcessDown(pid: caller_pid, ..) = process_down

      let #(selector, workers, live_workers) = case
        dict.get(state.live_workers, caller_pid)
      {
        Ok(live_worker) -> {
          let live_workers = dict.delete(state.live_workers, caller_pid)
          process.demonitor_process(live_worker.caller_monitor)
          let selector =
            state.selector
            |> process.deselect_specific_monitor(live_worker.caller_monitor)

          let new_workers = deque.push_back(state.workers, live_worker.worker)

          #(selector, new_workers, live_workers)
        }
        Error(_) -> #(state.selector, state.workers, state.live_workers)
      }
      actor.with_selector(
        actor.continue(State(..state, selector:, live_workers:, workers:)),
        selector,
      )
    }
    WorkerDown(process_down) -> {
      // This is safe as we don't monitor ports
      let assert process.ProcessDown(pid: worker_pid, ..) = process_down

      // Get this worker from the pool if it was a checked in worker
      let #(maybe_downed_worker, new_workers) =
        state.workers
        |> deque.to_list
        |> list.partition(fn(worker) {
          process.subject_owner(worker.subject) == Ok(worker_pid)
        })

      // Otherwise, it may have been a live worker, so grab it
      let #(downed_worker, live_workers) = case maybe_downed_worker {
        [worker] -> #(Some(worker), state.live_workers)
        _ ->
          case
            dict.values(state.live_workers)
            |> list.find(fn(lw) {
              process.subject_owner(lw.worker.subject) == Ok(worker_pid)
            })
          {
            Ok(live_worker) -> #(
              Some(live_worker.worker),
              // Delete the caller pid from the live workers dict
              dict.delete(state.live_workers, live_worker.caller),
            )
            Error(Nil) -> {
              // This shouldn't happen - this worker must have either been
              // a checked-in worker or a live worker. If it does happen,
              // we'll ignore it.
              #(None, state.live_workers)
            }
          }
      }

      // If the worker exists, demonitor it
      let selector = case downed_worker {
        Some(worker) -> {
          process.demonitor_process(worker.monitor)

          state.selector
          |> process.deselect_specific_monitor(worker.monitor)
        }
        _ -> state.selector
      }

      actor.with_selector(
        actor.continue(
          State(
            ..state,
            live_workers:,
            selector:,
            workers: new_workers |> deque.from_list,
          ),
        ),
        selector,
      )
    }
    Broadcast(msg_to_send) -> {
      // Get both checked-in and live workers
      let workers =
        list.append(
          deque.to_list(state.workers),
          dict.values(state.live_workers)
            |> list.map(fn(live_worker) { live_worker.worker }),
        )

      list.each(workers, fn(worker) {
        process.send(worker.subject, msg_to_send)
      })
      actor.continue(state)
    }
  }
}

fn pool_spec(
  pool_config: PoolConfig(state, msg),
  pool_name: process.Name(PoolMsg(msg)),
  init_timeout: Int,
) -> supervision.ChildSpecification(process.Subject(PoolMsg(msg))) {
  let pool_builder =
    actor.new_with_initialiser(init_timeout, fn(self) {
      let selector =
        process.new_selector()
        |> process.select(self)

      let state =
        State(
          workers: deque.new(),
          checkout_strategy: pool_config.checkout_strategy,
          live_workers: dict.new(),
          selector:,
        )

      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle_pool_message)
    |> actor.named(pool_name)

  supervision.worker(fn() { actor.start(pool_builder) })
  |> supervision.restart(supervision.Transient)
}

// ----- Worker ---- //

type Worker(msg) {
  Worker(subject: Subject(msg), monitor: process.Monitor)
}

fn worker_spec(
  pool_name: process.Name(PoolMsg(msg)),
  pool_config: PoolConfig(state, msg),
) -> supervision.ChildSpecification(process.Subject(msg)) {
  let worker_builder =
    actor.new_with_initialiser(pool_config.init_timeout, fn(self) {
      // Check in the worker
      process.send(process.named_subject(pool_name), Register(self))

      use init_data <- result.try(pool_config.init())

      let selector =
        process.new_selector()
        |> process.select(self)

      let selector = case init_data.selector {
        Some(init_selector) -> process.merge_selector(init_selector, selector)
        None -> selector
      }

      actor.initialised(init_data.state)
      |> actor.selecting(selector)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(pool_config.loop)

  supervision.worker(fn() { actor.start(worker_builder) })
  |> supervision.restart(supervision.Transient)
}

/// This is mostly a copy of the `gleam/erlang/process.call` function but without the
/// panic on process down.
fn call_recover(
  subject: Subject(message),
  timeout: Int,
  make_request: fn(Subject(reply)) -> message,
) -> Result(reply, process.Down) {
  let reply_subject = process.new_subject()
  let assert Ok(callee) = process.subject_owner(subject)
    as "Callee subject had no owner"

  // Monitor the callee process so we can tell if it goes down (meaning we
  // won't get a reply)
  let monitor = process.monitor(callee)

  // Send the request to the process over the channel
  process.send(subject, make_request(reply_subject))

  // Await a reply or handle failure modes (timeout, process down, etc)
  let reply =
    process.new_selector()
    |> process.select_map(reply_subject, Ok)
    |> process.select_specific_monitor(monitor, Error)
    |> process.selector_receive(timeout)

  let assert Ok(reply) = reply as "callee did not send reply before timeout"

  // Demonitor the process and close the channels as we're done
  process.demonitor_process(monitor)

  reply
}
