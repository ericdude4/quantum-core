defmodule Quantum.Executor do
  @moduledoc false

  # Task to actually execute a Task

  use Task

  require Logger

  alias Quantum.{
    Job,
    NodeSelectorBroadcaster.Event,
    TaskRegistry
  }

  alias __MODULE__.StartOpts

  @spec start_link(StartOpts.t(), Event.t()) :: {:ok, pid}
  def start_link(opts, %Event{job: job, node: node}) do
    Task.start_link(fn ->
      execute(opts, job, node)
    end)
  end

  @spec execute(StartOpts.t(), Job.t(), Node.t()) :: :ok
  # Execute task on all given nodes without checking for overlap
  defp execute(
         %StartOpts{
           task_supervisor_reference: task_supervisor,
           debug_logging: debug_logging,
           scheduler: scheduler
         },
         %Job{overlap: true} = job,
         node
       ) do
    run(node, job, task_supervisor, debug_logging, scheduler)

    :ok
  end

  # Execute task on all given nodes with checking for overlap
  defp execute(
         %StartOpts{
           task_supervisor_reference: task_supervisor,
           task_registry_reference: task_registry,
           debug_logging: debug_logging,
           scheduler: scheduler
         },
         %Job{overlap: false, name: job_name} = job,
         node
       ) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Start execution of job #{inspect(job_name)}"
      end)

    case TaskRegistry.mark_running(task_registry, job_name, node) do
      :marked_running ->
        %Task{ref: ref} = run(node, job, task_supervisor, debug_logging, scheduler)

        receive do
          {^ref, _} ->
            TaskRegistry.mark_finished(task_registry, job_name, node)

          {:DOWN, ^ref, _, _, _} ->
            TaskRegistry.mark_finished(task_registry, job_name, node)

            :ok
        end

      _ ->
        :ok
    end
  end

  # Ececute the given function on a given node via the task supervisor
  @spec run(Node.t(), Job.t(), GenServer.server(), boolean(), atom()) :: Task.t()
  defp run(
         node,
         %Job{name: job_name, task: task} = job,
         task_supervisor,
         debug_logging,
         scheduler
       ) do
    debug_logging &&
      Logger.debug(fn ->
        "[#{inspect(Node.self())}][#{__MODULE__}] Task for job #{inspect(job_name)} started on node #{
          node
        }"
      end)

    Task.Supervisor.async_nolink({task_supervisor, node}, fn ->
      debug_logging &&
        Logger.debug(fn ->
          "[#{inspect(Node.self())}][#{__MODULE__}] Execute started for job #{inspect(job_name)}"
        end)

      # Note: we are intentionally mimicking the ":telemetry.span" here to keep current functionality
      start_monotonic_time = :erlang.monotonic_time()

      :telemetry.execute([:quantum, :job, :start], %{system_time: start_monotonic_time}, %{
        job: job,
        node: node,
        scheduler: scheduler
      })

      try do
        execute_task(task)
      catch
        type, value ->
          debug_logging &&
            Logger.debug(fn ->
              "[#{inspect(Node.self())}][#{__MODULE__}] Execution ended for job #{
                inspect(job_name)
              }, which failed due to: #{Exception.format(type, value, __STACKTRACE__)}"
            end)

          duration = :erlang.monotonic_time() - start_monotonic_time

          :telemetry.execute([:quantum, :job, :exception], %{duration: duration}, %{
            job: job,
            node: node,
            reason: value,
            stacktrace: __STACKTRACE__,
            scheduler: scheduler
          })
      else
        result ->
          debug_logging &&
            Logger.debug(fn ->
              "[#{inspect(Node.self())}][#{__MODULE__}] Execution ended for job #{
                inspect(job_name)
              }, which yielded result: #{inspect(result)}"
            end)

          duration = :erlang.monotonic_time() - start_monotonic_time

          :telemetry.execute([:quantum, :job, :stop], %{duration: duration}, %{
            job: job,
            node: node,
            scheduler: scheduler,
            result: result
          })
      end

      :ok
    end)
  end

  # Run function
  @spec execute_task(Quantum.Job.task()) :: any
  defp execute_task({mod, fun, args}) do
    :erlang.apply(mod, fun, args)
  end

  defp execute_task(fun) when is_function(fun, 0) do
    fun.()
  end
end
