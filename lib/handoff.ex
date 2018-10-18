defmodule Handoff do
  defstruct [:label, :vsn, :data]

  @type t :: %__MODULE__{}

  @callback handoff_initiate(label :: atom, data :: __MODULE__.t, timeout :: non_neg_integer) :: :ok | {:error, term}
  @callback handoff_complete(label :: atom, timeout :: non_neg_integer) :: {:ok, [__MODULE__.t]} | {:error, term}
  @callback handoff_subscribe(label :: atom, timeout :: non_neg_integer) :: :ok | {:error, term}
  @callback handoff_unsubscribe(label :: atom, timeout :: non_neg_integer) :: :ok | {:eror, term}
end
