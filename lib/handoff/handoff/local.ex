defmodule Handoff.Local do
  @moduledoc """
  Handoff state between local processes.

  *Note* you must ensure that when you handoff state that you're able to deal with the state.
  Do not accept corrupt state

  # Setup

  When using local handoffs, `use Handoff.Local` in your GenServer.

  A bare bones implementation of the important parts is:

  ```
  defmoduel MyServer do
    use GenServer
    use Handoff.Local

    # snip

    def init(initial_state) do
      Process.flag(:trap_exit, true)  # <---
      handoff_subscribe()             # <---
      {:ok, initial_state}
    end

    def handle_cast(:handoff_available, state) do
      with {:ok, handoffs} <- handoff_complete() do        # <-----
        state = merge_handoff_with_state(handoffs, state)
        {:noreply, state}
      else
        _ ->
          {:noreply, state}
      end
    end

    def handle_info({:EXIT, _pid, reason}, state) do
      {:noreply, reason, state}
    end

    def terminate(reason, {data, _}) do
      handoff_initiate(data)        # <------
      reason
    end

    defp merge_handoff_with_state(handoffs, state) do
      # calculate new state
    end
  end
  ```
  """

  @behaviour Handoff
  use Handoff.Utils

  defmodule State do
    @moduledoc false
    defstruct subscribers: %{}, handoffs: %{}
  end

  defmacro __using__(_) do
    quote do
      def handoff_initiate(data, timeout \\ 5_000) do
        vsn = __MODULE__.module_info(:attributes) |> Keyword.get(:vsn)
        handoff_data = %Handoff{label: __MODULE__, vsn: vsn, data: data}
        Handoff.Local.handoff_initiate(__MODULE__, handoff_data, timeout)
      end

      def handoff_complete(timeout \\ 5_000) do
        Handoff.Local.handoff_complete(__MODULE__, timeout)
      end

      # implement handle_call(:handoff_available, state) and use it to call handoff_complete
      def handoff_subscribe(timeout \\ 5_000) do
        Handoff.Local.handoff_subscribe(__MODULE__, timeout)
      end

      def handoff_unsubscribe(timeout \\ 5_000) do
        Handoff.Local.handoff_unsubscribe(__MODULE__, timeout)
      end
    end
  end

  ### GenServer callbacks

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      shutdown: 5000,
    }
  end

  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__.State{}}
  end

  def handle_call({:put, label, %Handoff{} = data}, {from, _}, state) do
    this_handoffs = Map.get(state.handoffs, label, [])
    this_handoffs = this_handoffs ++ [data]
    new_handoffs = Map.put(state.handoffs, label, this_handoffs)

    new_state = drop_subscriber(from, label, state)

    GenServer.cast(self(), {:notify, label})

    {:reply, :ok, %{new_state | handoffs: new_handoffs}}
  end

  def handle_call({:subscribe, label}, {from, _}, state) do
    current_subscribers = Map.get(state.subscribers, label, [])
    if Enum.any?(current_subscribers, fn {_, pid} -> pid == from end) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(from)
      new_subscribers = Map.put(state.subscribers, label, [{ref, from} | current_subscribers])
      {:reply, :ok, %{state | subscribers: new_subscribers}}
    end
  end

  def handle_cast({:notify, label}, state) do
    case Map.get(state.handoffs, label, []) do
      [] -> :nothing
      _handoffs ->
          state.subscribers
          |> Map.get(label, [])
          |> Enum.each(fn {_, pid} -> GenServer.cast(pid, :handoff_available) end)
    end
    {:noreply, state}
  end
end
