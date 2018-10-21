# Handoff

Handoff state between processes.

*Note* This is an experiment. Use at your own risk

Initially developed for cluster global processes to handoff state when one process dies and the other
is stated on another unknown node. Specifically when performing rolling deploys on Kubernetes using Horde.

This provides a handoff mechanism for processes either in a local scope or global.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `handoff` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:handoff, "~> 0.1.0"}
  ]
end
```

## Usage

The implementation of your GenServer is mostly the same when using local or global handoffs.

*Note* you must ensure that when you handoff state that you're able to deal with the state.
This is somewhat dangerous. If you have corrupt state, you're going to have a bad time.

Make sure that you don't propagate bad state....

The main difference is which Handoff to use.

When a handoff occurs you receive a list of handoffs, each on is a `Handoff` struct.
It includes:

* label - the module for the handoff
* vsn - the @vsn of the module. usually a list of 1 element
* data - The data that was provided for the handoff.

The general steps of setting up a handoff are:

1. Add a shutdown option do your child_spec to give time to handoff
2. In your init function
  * Trap exits
  * Setup a subscription
3. Handle a cast of `:handoff_available`
  * call `handoff_complete()` to get the handoffs. This could be empty if another process has already taken the handoff
  * merge the handoff state into your processes state
4. Implement a terminate callback with `handoff_initiate(state_data_to_handoff)`

A bare bones implementation of the important parts is:

```
defmoduel MyServer do
  use GenServer
  use Handoff.Local
  # use Handoff.Global  only use one of these, either local or global

  # snip

  def child_spec(args) do
    %{
      id: :"#{__MODULE__}#{args}",
      start: {__MODULE__, :start_link, [args]},
      shutdown: 5_000, # <-----
    }
  end

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

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/handoff](https://hexdocs.pm/handoff).
