// TODO: change this to be a proper worker pool
import gleam/deque
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Pid, type Subject}
import gleam/function
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/result

// ---- Pool config ----- //

/// The strategy used to check out a resource from the pool.
pub type CheckoutStrategy {
  FIFO
  LIFO
}

/// Configuration for a [`Pool`](#Pool).
pub opaque type PoolConfig(state, msg) {
  PoolConfig(
    size: Int,
    spec: Spec(state, msg),
    checkout_strategy: CheckoutStrategy,
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
pub fn new(spec spec: Spec(state, msg)) -> PoolConfig(state, msg) {
  PoolConfig(size: 10, spec:, checkout_strategy: FIFO)
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

/// An error returned when creating a [`Pool`](#Pool).
pub type StartError {
  PoolActorStartError(actor.StartError)
  PoolSupervisorStartError(dynamic.Dynamic)
  WorkerSupervisorStartError(dynamic.Dynamic)
}

/// An error returned when failing to use a pooled worker.
pub type ApplyError {
  NoResourcesAvailable
  CheckOutTimeout
  WorkerCallTimeout
  WorkerCrashed(dynamic.Dynamic)
}

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
pub type Spec(state, msg) {
  Spec(
    init: fn(process.Selector(msg)) -> actor.InitResult(state, msg),
    init_timeout: Int,
    loop: fn(msg, state) -> actor.Next(msg, state),
  )
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
) -> Result(Pool(msg), StartError) {
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

  let pool_start_result =
    actor.start_spec(pool_spec(pool_config, init_timeout))
    |> result.map_error(PoolActorStartError)

  use pool_subject <- result.try(pool_start_result)

  // Add workers to the worker supervisor and start it
  let worker_supervisor_result =
    list.repeat("", pool_config.size)
    |> list.index_fold(worker_supervisor, fn(worker_supervisor, _, idx) {
      sup.add(
        worker_supervisor,
        sup.worker_child("worker_" <> int.to_string(idx), fn() {
          worker_spec(pool_subject, pool_config.spec)
          |> actor.start_spec
          |> result.map(process.subject_owner)
        })
          |> sup.timeout(11_000_000)
          |> sup.restart(sup.Transient),
      )
    })
    |> sup.start_link
    |> result.map_error(WorkerSupervisorStartError)

  use worker_supervisor <- result.try(worker_supervisor_result)

  // Add the pool and worker supervisors to the main supervisor
  let main_supervisor_result =
    sup.add(
      main_supervisor,
      sup.worker_child("pool", fn() {
        process.subject_owner(pool_subject) |> Ok
      })
        |> sup.timeout(11_000_000)
        |> sup.restart(sup.Transient),
    )
    |> sup.add(
      sup.supervisor_child("worker_supervisor", fn() { Ok(worker_supervisor) })
      |> sup.timeout(11_000_000)
      |> sup.restart(sup.Transient),
    )
    |> sup.start_link()
    |> result.map_error(PoolSupervisorStartError)

  use main_supervisor <- result.try(main_supervisor_result)

  Ok(Pool(subject: pool_subject, supervisor: main_supervisor))
}

/// Get the supervisor PID for a running pool.
pub fn supervisor(pool pool: Pool(resource_type)) -> Pid {
  pool.supervisor
}

fn check_out(
  pool: Pool(resource_type),
  caller: Pid,
  timeout: Int,
) -> Result(Worker(resource_type), ApplyError) {
  process.try_call(pool.subject, CheckOut(_, caller:), timeout)
  |> result.replace_error(CheckOutTimeout)
  |> result.flatten
}

fn check_in(pool: Pool(msg), worker: Worker(msg), caller: Pid) {
  process.send(pool.subject, CheckIn(worker:, caller:))
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
  use subject <- apply(pool, checkout_timeout)

  process.send(subject, msg)
}

/// Send a message to a pooled actor and wait for a response. Equivalent to `process.call`
/// using a pooled actor.
pub fn call(
  pool pool: Pool(msg),
  msg msg: fn(Subject(return_type)) -> msg,
  checkout_timeout checkout_timeout: Int,
  call_timeout call_timeout: Int,
) -> Result(return_type, ApplyError) {
  apply(pool, checkout_timeout, fn(subject) {
    process.try_call(subject, msg, call_timeout)
    |> result.map_error(fn(err) {
      case err {
        process.CallTimeout -> WorkerCallTimeout
        process.CalleeDown(reason) -> WorkerCrashed(reason)
      }
    })
  })
  |> result.flatten
}

/// Send a message to all pooled actors, regardless of checkout status.
pub fn broadcast(pool pool: Pool(msg), msg msg: msg) -> Nil {
  process.send(pool.subject, Broadcast(msg))
}

/// Shut down a pool and all its workers.
pub fn shutdown(pool pool: Pool(msg)) {
  process.send_exit(pool.supervisor)
}

// ----- Pool ----- //

/// The interface for interacting with a pool of workers in Lifeguard.
pub opaque type Pool(msg) {
  Pool(subject: Subject(PoolMsg(msg)), supervisor: Pid)
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
  LiveWorker(
    worker: Worker(msg),
    caller: Pid,
    caller_monitor: process.ProcessMonitor,
  )
}

type PoolMsg(msg) {
  Register(worker_subject: Subject(msg))
  CheckIn(worker: Worker(msg), caller: Pid)
  CheckOut(reply_to: Subject(Result(Worker(msg), ApplyError)), caller: Pid)
  WorkerDown(process.ProcessDown)
  CallerDown(process.ProcessDown)
  Broadcast(msg)
}

fn handle_pool_message(msg: PoolMsg(resource_type), state: State(resource_type)) {
  // TODO: process monitoring
  case msg {
    Register(worker_subject:) -> {
      let monitor =
        process.monitor_process(worker_subject |> process.subject_owner)
      let selector =
        state.selector
        |> process.selecting_process_down(monitor, WorkerDown)

      let new_worker = Worker(subject: worker_subject, monitor:)

      actor.with_selector(
        actor.continue(
          State(
            ..state,
            workers: deque.push_back(state.workers, new_worker),
            selector:,
          ),
        ),
        selector,
      )
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
          |> process.deselecting_process_down(live_worker.caller_monitor)
        }
        Error(_) -> state.selector
      }

      let new_workers = deque.push_back(state.workers, worker)

      actor.with_selector(
        actor.continue(
          State(..state, workers: new_workers, live_workers:, selector:),
        ),
        selector,
      )
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
          let caller_monitor = process.monitor_process(caller)
          let selector =
            state.selector
            |> process.selecting_process_down(caller_monitor, CallerDown)

          let live_workers =
            dict.insert(
              state.live_workers,
              caller,
              LiveWorker(worker:, caller:, caller_monitor:),
            )
          actor.send(reply_to, Ok(worker))
          actor.with_selector(
            actor.continue(
              State(..state, workers: new_workers, live_workers:, selector:),
            ),
            selector,
          )
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
      let #(selector, workers, live_workers) = case
        dict.get(state.live_workers, process_down.pid)
      {
        Ok(live_worker) -> {
          let live_workers = dict.delete(state.live_workers, process_down.pid)
          process.demonitor_process(live_worker.caller_monitor)
          let selector =
            state.selector
            |> process.deselecting_process_down(live_worker.caller_monitor)

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
      // Get this worker from the pool if it was a checked in worker
      let #(maybe_downed_worker, new_workers) =
        state.workers
        |> deque.to_list
        |> list.partition(fn(worker) {
          process.subject_owner(worker.subject) == process_down.pid
        })

      // Otherwise, it may have been a live worker, so grab it
      let #(downed_worker, live_workers) = case maybe_downed_worker {
        [worker] -> #(Some(worker), state.live_workers)
        _ ->
          case
            dict.values(state.live_workers)
            |> list.find(fn(lw) {
              process.subject_owner(lw.worker.subject) == process_down.pid
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
          |> process.deselecting_process_down(worker.monitor)
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
  init_timeout: Int,
) -> actor.Spec(State(msg), PoolMsg(msg)) {
  actor.Spec(init_timeout:, loop: handle_pool_message, init: fn() {
    let self = process.new_subject()

    let selector =
      process.new_selector()
      |> process.selecting(self, function.identity)

    let state =
      State(
        workers: deque.new(),
        checkout_strategy: pool_config.checkout_strategy,
        live_workers: dict.new(),
        selector:,
      )

    actor.Ready(state, selector)
  })
}

// ----- Worker ---- //

type Worker(msg) {
  Worker(subject: Subject(msg), monitor: process.ProcessMonitor)
}

fn worker_spec(
  pool_subject: Subject(PoolMsg(msg)),
  spec: Spec(state, msg),
) -> actor.Spec(state, msg) {
  actor.Spec(init_timeout: spec.init_timeout, loop: spec.loop, init: fn() {
    // Check in the worker
    let self = process.new_subject()
    process.send(pool_subject, Register(self))

    let selector =
      process.new_selector()
      |> process.selecting(self, function.identity)

    spec.init(selector)
  })
}
