defmodule Handoff.Local do
  @behaviour Handoff

  require Logger

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

  def handoff_initiate(label, %Handoff{} = data, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:put, label, data}, timeout)
  end

  def handoff_complete(label, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:drain, label}, timeout)
  end

  def handoff_subscribe(label, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:subscribe, label}, timeout)
  end

  def handoff_unsubscribe(label, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:unsubscribe, label}, timeout)
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

  def handle_call({:put, label, %Handoff{} = data}, _from, state) do
    this_handoffs = Map.get(state.handoffs, label, [])
    this_handoffs = this_handoffs ++ [data]
    new_handoffs = Map.put(state.handoffs, label, this_handoffs)
    GenServer.cast(self(), {:notify, label})
    {:reply, :ok, %{state | handoffs: new_handoffs}}
  end

  def handle_call({:drain, label}, _from, state) do
    handoffs = Map.get(state.handoffs, label, [])
    new_handoffs = Map.drop(state.handoffs, [label])
    {:reply, {:ok, handoffs}, %{state | handoffs: new_handoffs}}
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

  def handle_call({:unsubscribe, label}, {from, _}, state) do
    subscribers =
      state.subscribers
      |> Map.get(label, [])
      |> Enum.filter(fn {ref, pid} ->
        if pid == from do
          Process.demonitor(ref)
          false
        else
          true
        end
      end)

    new_subscribers = Map.put(state.subscribers, label, subscribers)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
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

  # when a subscription dies, unsubscribe
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Enum.find(state.subscribers, &(ref_in_subscribers?(ref, &1))) do
      {label, subscribers} ->
        subscribers =
          Enum.filter subscribers, fn {r, _} ->
            if r == ref do
              Process.demonitor(ref)
              false
            else
              true
            end
          end
        new_subscribers = Map.put(state.subscribers, label, subscribers)
        {:noreply, %{state | subscribers: new_subscribers}}
      _ ->
        {:no_reply, state}
    end
  end

  def terminate(reason, state) do
    Logger.warn("Unable to handoff: #{inspect(state.handoffs)}")
    reason
  end

  defp ref_in_subscribers?(ref, {_key, subscribers}) do
    Enum.any?(subscribers, fn {r, _} -> r == ref end)
  end
end
