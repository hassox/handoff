defmodule Handoff.Utils do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      require Logger

      import Handoff.Utils, only: [drain: 2, drop_subscriber: 3, ref_in_subscribers?: 2]

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

      def handle_call({:drain, label}, _from, state) do
        {local_handoffs, new_state} = drain(label, state)
        {:reply, {:ok, local_handoffs}, new_state}
      end

      def handle_call({:unsubscribe, label}, {from, _}, state) do
        new_state = drop_subscriber(from, label, state)
        {:reply, :ok, new_state}
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
    end
  end

  def drain(label, state) do
    local_handoffs = Map.get(state.handoffs, label, [])
    new_handoffs = Map.drop(state.handoffs, [label])
    {local_handoffs, %{state | handoffs: new_handoffs}}
  end

  def drop_subscriber(pid, label, state) do
    subscribers =
      state.subscribers
      |> Map.get(label, [])
      |> Enum.filter(fn
        {ref, ^pid} ->
          Process.demonitor(ref)
          false
        _ ->
          true
      end)

    new_subscribers = Map.put(state.subscribers, label, subscribers)
    %{state | subscribers: new_subscribers}
  end

  def ref_in_subscribers?(ref, {_key, subscribers}) do
    Enum.any?(subscribers, fn {r, _} -> r == ref end)
  end
end
