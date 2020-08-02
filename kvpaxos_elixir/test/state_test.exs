defmodule StateTest do
  use ExUnit.Case

  import PaxosState
  # import ProposalNumber
  # alias PaxosState.PaxosEntry

  test "create_entry" do
    # peers = {"a", "b"}
    {_, state} = start_link({0, 3})
    assert get_entry(state, 0) == nil
    create_entry(state, 1)
    assert get_entry(state, 1) != nil
    assert status(state, 1) == {:pending, nil}
  end
end
