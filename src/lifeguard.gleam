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

/// The strategy used to check out a resource from the pool.
pub type CheckoutStrategy {
  /// Check out workers with a first-in-first-out strategy. Operates like a queue.
  FIFO
  /// Check out workers with a last-in-first-out strategy. Operates like a stack.
  LIFO
}

/// A type returned by a worker's initialisation function. It contains the worker's
/// initial state, along with an optional selector that can be used to send messages
/// to the worker.
///
/// If provided, the selector will be used instead of the default, which just selects
/// from the worker's own subject. You can provide a custom selector using the
/// [`selecting`](#selecting) function.
pub opaque type Initialised(state, msg) {
  Initialised(state: state, selector: option.Option(process.Selector(msg)))
}

/// Create a new [`Initialised`](#Initialised) value with the given state and no selector.
pub fn initialised(state: state) -> Initialised(state, msg) {
  Initialised(state: state, selector: None)
}

/// Provide a selector for your worker to receive messages with. If your worker receives
/// a message that isn't selected, the message will be discarded and a warning will be
/// logged.
///
/// If you don't provide a selector, the worker will receive messages from its own subject,
/// equivalent to `process.select(process.new_selector(), process.new_subject())`. If you
/// provide a selector, the default selector will be overwritten.
pub fn selecting(
  initialised: Initialised(state, msg),
  selector: process.Selector(msg),
) -> Initialised(state, msg) {
  Initialised(..initialised, selector: Some(selector))
}

/// Configuration for a [`Pool`](#Pool).
pub opaque type Builder(state, msg) {
  Builder(
    size: Int,
    checkout_strategy: CheckoutStrategy,
    init: fn(process.Subject(msg)) -> Result(Initialised(state, msg), String),
    init_timeout: Int,
    loop: fn(state, msg) -> actor.Next(state, msg),
  )
}

/// Create a new [`Builder`](#Builder) for creating a pool of worker actors.
///
/// This API mimics the Actor API from [`gleam/otp/actor`](https://hexdocs.pm/gleam_otp/gleam/otp/actor.html),
/// so it should be familiar to anyone already using OTP with Gleam.
///
/// ```gleam
/// import lifeguard
///
/// pub fn main() {
///   // Create a pool of 10 actors that do nothing.
///   let assert Ok(pool) =
///     lifeguard.new(initial_state)
///     |> lifeguard.on_message(fn(msg, state) { actor.continue(state) })
///     |> lifeguard.size(10)
///     |> lifeguard.start(1000)
/// }
/// ```
///
/// ### Default values
///
/// | Config | Default |
/// |--------|---------|
/// | `on_message` | `fn(state, _) { actor.continue(state) }` |
/// | `size`   | 10      |
/// | `checkout_strategy` | `FIFO` |
pub fn new(state: state) -> Builder(state, msg) {
  Builder(
    size: 10,
    checkout_strategy: FIFO,
    init: fn(_) { Ok(initialised(state)) },
    init_timeout: 1000,
    loop: fn(state, _) { actor.continue(state) },
  )
}

/// Create a new [`Builder`](#Builder) with a custom initialiser that runs before the
/// worker's message loop starts.
///
/// The first argument is the number of milliseconds the initialiser is expected to
/// return within. The actor will be terminated if it does not complete within the
/// specified time, and the creation of the pool will fail.
///
/// The initialiser is given the worker's default subject, which can optionally be
/// used to create a custom selector for the worker to receive messages. See the
/// [`selecting`](#selecting) function for more information.
///
/// This API mimics the Actor API from [`gleam/otp/actor`](https://hexdocs.pm/gleam_otp/gleam/otp/actor.html),
/// so it should be familiar to anyone already using OTP with Gleam.
///
/// ```gleam
/// import lifeguard
///
/// pub fn main() {
///   // Create a pool of 10 actors that do nothing.
///   let assert Ok(pool) =
///     lifeguard.new(initial_state)
///     |> lifeguard.on_message(fn(msg, state) { actor.continue(state) })
///     |> lifeguard.size(10)
///     |> lifeguard.start(1000)
/// }
/// ```
///
/// ### Default values
///
/// | Config | Default |
/// |--------|---------|
/// | `on_message` | `fn(state, _) { actor.continue(state) }` |
/// | `size`   | 10      |
/// | `checkout_strategy` | `FIFO` |
pub fn new_with_initialiser(
  timeout: Int,
  initialiser: fn(process.Subject(msg)) ->
    Result(Initialised(state, msg), String),
) -> Builder(state, msg) {
  Builder(
    size: 10,
    checkout_strategy: FIFO,
    init: initialiser,
    init_timeout: timeout,
    loop: fn(state, _) { actor.continue(state) },
  )
}

/// Set the message handler for actors in the pool. This operates exactly like
/// [`gleam/otp/actor.on_message`](https://gleam.run/api/gleam/otp/actor/index.html#on_message).
pub fn on_message(
  builder builder: Builder(state, msg),
  handler handler: fn(state, msg) -> actor.Next(state, msg),
) {
  Builder(..builder, loop: handler)
}

/// Set the number of actors in the pool. Defaults to 10.
pub fn size(
  builder builder: Builder(state, msg),
  size size: Int,
) -> Builder(state, msg) {
  Builder(..builder, size:)
}

/// Set the order in which actors are checked out from the pool. Defaults to `FIFO`.
pub fn checkout_strategy(
  builder builder: Builder(state, msg),
  strategy checkout_strategy: CheckoutStrategy,
) -> Builder(state, msg) {
  Builder(..builder, checkout_strategy:)
}

// ----- Lifecycle functions ---- //

/// An error returned when failing to use a pooled worker.
pub type ApplyError {
  NoResourcesAvailable
  // WorkerCrashed(process.Down)
}

/// Start a pool supervision tree using the given [`Builder`](#Builder) and return a
/// [`Pool`](#Pool).
///
/// Note: this function mimics the behaviour of `supervisor:start_link` and
/// `gleam/otp/static_supervisor`'s `start_link` function and will exit the process if
/// any of the workers fail to start.
fn start_tree(
  pool_name: process.Name(PoolMsg(msg)),
  builder: Builder(state, msg),
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
      list.repeat("", builder.size)
      |> list.fold(worker_supervisor, fn(worker_supervisor, _) {
        sup.add(worker_supervisor, worker_spec(pool_name, builder))
      })
      |> sup.start
    })

  // Add the pool and worker supervisors to the main supervisor
  main_supervisor
  |> sup.add(pool_spec(builder, pool_name, init_timeout))
  |> sup.add(worker_supervisor_spec)
  |> sup.start()
}

/// Start an unsupervised pool using the given [`Builder`](#Builder) and return a
/// [`Pool`](#Pool). In most cases, you should use the [`supervised`](#supervised)
/// function instead.
///
/// Note: this function mimics the behaviour of `supervisor:start_link` and
/// `gleam/otp/static_supervisor`'s `start_link` function and will exit the process if
/// any of the workers fail to start.
pub fn start(
  builder builder: Builder(state, msg),
  timeout init_timeout: Int,
) -> Result(Pool(msg), actor.StartError) {
  let pool_name = process.new_name(pool_name_prefix)

  start_tree(pool_name, builder, init_timeout)
  |> result.replace(Pool(name: pool_name))
}

/// Return the [`ChildSpecification`](https://hexdocs.pm/gleam_otp/gleam/otp/supervision.html#ChildSpecification)
/// for creating a supervised worker pool.
///
/// You must provide a selector to receive the [`Pool`](#Pool) value representing the
/// pool once it has started.
///
/// ## Example
///
/// ```gleam
/// let pool_receiver = process.new_subject()
///
/// let assert Ok(_started) =
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(
///     lifeguard.new(state)
///     |> lifeguard.supervised(pool_receiver, 1000)
///   )
///   |> supervisor.start
///
/// let assert Ok(pool) =
///   process.receive(pool_receiver)
///
/// let assert Ok(_) = lifeguard.send(pool, Message)
/// ```
pub fn supervised(
  builder builder: Builder(state, msg),
  receive_to pool_subject: process.Subject(Pool(msg)),
  timeout init_timeout: Int,
) -> supervision.ChildSpecification(sup.Supervisor) {
  let pool_name = process.new_name(pool_name_prefix)
  supervision.supervisor(fn() {
    use supervisor <- result.try(start_tree(pool_name, builder, init_timeout))

    process.send(pool_subject, Pool(name: pool_name))
    Ok(supervisor)
  })
}

/// Get the supervisor PID for a running pool.
///
/// Returns an error if the pool is not running.
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

/// Send a message to a pooled worker. Equivalent to `process.send` using a pooled actor.
///
/// ## Panics
///
/// Like [`gleam/erlang/process.send`](https://hexdocs.pm/gleam_erlang/gleam/erlang/process.html#send),
/// this will panic if the pool is not running.
pub fn send(
  pool pool: Pool(msg),
  msg msg: msg,
  checkout_timeout checkout_timeout: Int,
) -> Result(Nil, ApplyError) {
  apply(pool, checkout_timeout, process.send(_, msg))
}

/// Send a message to a pooled actor and wait for a response. Equivalent to `process.call`
/// using a pooled worker.
///
/// ## Panics
///
/// Like [`gleam/erlang/process.call`](https://hexdocs.pm/gleam_erlang/gleam/erlang/process.html#call),
/// this will panic if the pool is not running, or if the worker crashes while
/// handling the message.
pub fn call(
  pool pool: Pool(msg),
  msg msg: fn(Subject(return_type)) -> msg,
  checkout_timeout checkout_timeout: Int,
  call_timeout call_timeout: Int,
) -> Result(return_type, ApplyError) {
  apply(pool, checkout_timeout, process.call(_, call_timeout, msg))
}

/// Send a message to all pooled actors, regardless of checkout status.
///
/// ## Panics
///
/// Like [`gleam/erlang/process.send`](https://hexdocs.pm/gleam_erlang/gleam/erlang/process.html#send),
/// this will panic if the pool is not running.
pub fn broadcast(pool pool: Pool(msg), msg msg: msg) -> Nil {
  process.named_subject(pool.name)
  |> process.send(Broadcast(msg))
}

/// Shut down a pool and all its workers. Fails if the pool is not currently running.
///
/// You only need to call this when using unsupervised pools. You should let your
/// supervision tree handle the shutdown of supervised worker pools.
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
  builder: Builder(state, msg),
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
          checkout_strategy: builder.checkout_strategy,
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
  builder: Builder(state, msg),
) -> supervision.ChildSpecification(process.Subject(msg)) {
  let worker_builder =
    actor.new_with_initialiser(builder.init_timeout, fn(self) {
      // Check in the worker
      process.send(process.named_subject(pool_name), Register(self))

      use init_data <- result.try(builder.init(self))

      let selector =
        option.unwrap(
          init_data.selector,
          // Default self selector
          process.new_selector()
            |> process.select(self),
        )

      actor.initialised(init_data.state)
      |> actor.selecting(selector)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(builder.loop)

  supervision.worker(fn() { actor.start(worker_builder) })
  |> supervision.restart(supervision.Transient)
}
