defmodule HandoffTest do
  use ExUnit.Case
  doctest Handoff

  test "greets the world" do
    assert Handoff.hello() == :world
  end
end
