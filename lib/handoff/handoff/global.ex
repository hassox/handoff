defmodule Handoff.Global do
  @moduledoc """
  Handoff state between global processes.
  This was initially developed for cluster wide singletons

  *Note* you must ensure that when you handoff state that you're able to deal with the state.
  Do not accept corrupt state

  # Setup

  When using global handoffs, `use Handoff.Global` in your GenServer.

  A bare bones implementation of the important parts is:

  ```
  defmoduel MyServer do
    use GenServer
    use Handoff.Global       # <-----

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
        Handoff.Global.handoff_initiate(__MODULE__, handoff_data, timeout)
      end

      def handoff_complete(timeout \\ 5_000) do
        Handoff.Global.handoff_complete(__MODULE__, timeout)
      end

      # implement handle_call(:handoff_available, state) and use it to call handoff_complete
      def handoff_subscribe(timeout \\ 5_000) do
        Handoff.Global.handoff_subscribe(__MODULE__, timeout)
      end

      def handoff_unsubscribe(timeout \\ 5_000) do
        Handoff.Global.handoff_unsubscribe(__MODULE__, timeout)
      end
    end
  end

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
    {:ok, fetch_remote_handoffs(__MODULE__, %__MODULE__.State{})}
  end

  def handle_call({:put, label, %Handoff{} = data}, {from, _}, state) do
    this_handoffs = Map.get(state.handoffs, label, [])
    this_handoffs = this_handoffs ++ [data]
    new_handoffs = Map.put(state.handoffs, label, this_handoffs)

    new_state = drop_subscriber(from, label, state)

    # notify other Handoff globals
    :rpc.abcast(Node.list(), __MODULE__, {:notify, label})

    {:reply, :ok, %{new_state | handoffs: new_handoffs}}
  end

  def handle_call({:subscribe, label}, {from, _}, state) do
    current_subscribers = Map.get(state.subscribers, label, [])
    new_state = fetch_remote_handoffs(label, state)
    if Enum.any?(current_subscribers, fn {_, pid} -> pid == from end) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(from)
      new_subscribers = Map.put(state.subscribers, label, [{ref, from} | current_subscribers])
      unless new_state.handoffs |> Map.get(label, []) |> Enum.empty?() do
        GenServer.cast(from, :handoff_available)
      end
      {:reply, :ok, %{new_state | subscribers: new_subscribers}}
    end
  end

  def handle_cast({:notify, label}, state) do
    case Map.get(state.subscribers, label, []) do
      [] -> {:noreply, state}
      subs ->
        if Enum.empty?(subs) do
          {:noreply, state}
        else
          new_state = fetch_remote_handoffs(label, state)
          unless Enum.empty?(Map.get(new_state.handoffs, label, [])) do
            Enum.each(subs, fn {_, pid} -> GenServer.cast(pid, :handoff_available) end)
          end
          {:noreply, new_state}
        end
    end
  end

  def handle_info({:notify, _} = req, state) do
    GenServer.cast(__MODULE__, req)
    {:noreply, state}
  end

  def handle_info({from, {:drain, label}}, state) do
    {handoffs, new_state} = drain(label, state)
    send(from, {__MODULE__, node(), handoffs})
    {:noreply, new_state}
  end

  defp fetch_remote_handoffs(label, state) do
    local_handoffs = Map.get(state.handoffs, label, [])
    {replies, _} = :rpc.multi_server_call(Node.list(), __MODULE__, {:drain, label})
    handoffs = Enum.flat_map(replies, &(&1))
    new_state_handoffs = Map.put(state.handoffs, label, handoffs ++ local_handoffs)
    %{state | handoffs: new_state_handoffs}
  end
end
