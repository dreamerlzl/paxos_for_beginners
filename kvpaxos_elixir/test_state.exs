defmodule TestState do
  import ProposalNumber
  import PaxosState
  alias PaxosState.PaxosEntry

  def test1 do
    peers = {"a", "b"}
    {_, state} = start_link {0, 2}
    IO.puts get_entry(state, 0) == nil
    create_entry state, 0
    IO.puts get_entry(state, 0) != nil
    IO.inspect(get_entry(state, 0))
    IO.inspect frontier_status(state)

    decide_entry(state, 0)
    IO.inspect status(state, 0)

    IO.inspect get(state, :first_unchosen)
    increment_first_unchosen(state)
    IO.inspect get(state, :first_unchosen)

    next_proposal_number(state, 0)

    # done(state, 1)
  end

end
