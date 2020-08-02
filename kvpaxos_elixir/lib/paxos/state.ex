defmodule PaxosState do
  defstruct [:me, first_unchosen: 0, log: %{}, done: {}]
  # log: a map from index(integer) to paxos_entry
  # done: a map from peer id(integer) to largest done entry index(integer)
  import ProposalNumber
  defmodule PaxosEntry do
    defstruct [accepted_value: nil, accepted_proposal: smallest(), max_proposal: smallest(), max_round: 0]

    @type t(av, ap, mp, mr) :: %PaxosEntry{accepted_value: av, accepted_proposal: ap, max_proposal: mp, max_round: mr}
    @type t :: %PaxosEntry{accepted_value: any(), accepted_proposal: ProposalNumber.t(), max_proposal: ProposalNumber.t(), max_round: integer}

    @spec decided?(atom | %{accepted_proposal: ProposalNumber.t()}) :: boolean
    def decided?(entry) do
      eq? entry.accepted_proposal, infty()
    end

    # returns a decided entry

    def decide(entry) do
      Map.put(entry, :accepted_proposal, infty())
    end
  end

  use Agent

  def start_link({me, size}) do
    Agent.start_link(fn ->
      %PaxosState{me: me, done: Tuple.duplicate(-1, size)} end)
  end

  def min_done(done) do
    Enum.min(Tuple.to_list done)
  end

  def get(state, key) do
    Agent.get(state, fn s -> Map.get(s, key) end)
  end

  def get_entry(state, index) do
    Agent.get(state, fn s -> s.log[index] end)
  end

  def status(state, index) do
    Agent.get(state,
      fn s ->
        entry = s.log[index]
        cond do
          index < min_done(s.done) -> {:forgotten, nil}
          entry == nil -> {:pending, nil}
          PaxosEntry.decided?(entry) -> {:decided, entry.accepted_value}
          true -> {:pending, nil}
        end
      end)
  end

  def frontier_status(state) do
    Agent.get_and_update(state,
      fn s ->
        index = s.first_unchosen
        entry = s.log[index] # if the entry doesnt' exist, it's nil
        status = cond do
          index < min_done(s.done) -> {index, :forgotten, nil}
          entry == nil -> {index, :pending, nil}
          PaxosEntry.decided?(entry) -> {index, :decided, entry.accepted_value}
          true -> {index, :pending, nil}
        end
        {status, %{s | first_unchosen: index + 1}}
      end)
  end

  def rollback_first_unchosen(state) do
    Agent.update(state, fn s -> Map.put(s, :first_unchosen, s.first_unchosen - 1) end)
  end

  def get_done(state, id) do
    Agent.get(state, fn s -> elem(s.done, id) end)
  end

  def update_done(state, id, index) do
    Agent.update(state, fn s -> Map.put(s, :done, put_elem(s.done, id, max(elem(s.done, id), index))) end)
  end

  def done(state, index) do
    Agent.update(state, fn s -> Map.put(s, :done, put_elem(s.done, s.me, max(elem(s.done, s.me), index))) end)
  end

  def update_max_round(state, index, mr) do
    Agent.update(state, fn s -> Map.put(s, :log, Map.put(s.log, index, Map.put(s.log[index], :max_round, max(mr, s.log[index].max_round)))) end)
  end

  # def decide_entry(state, index) do
  #   Agent.update(state, fn s -> Map.put(s, :log, Map.put(s.log, index, PaxosEntry.decide(s.log[index]) )) end)
  # end

  def create_entry(state, index) do
    Agent.update(state,
      fn s ->
        case s.log[index] do
          nil -> Map.put(s, :log, Map.put(s.log, index, %PaxosEntry{}))
          _ -> s
        end
      end)
  end

  def next_proposal_number(state, index) do
    Agent.get_and_update(state, fn s ->
      {next_proposal(s.log[index].max_round, s.me),
       Map.put(s, :log, Map.put(s.log, index, Map.put(s.log[index], :max_round, s.log[index].max_round+1)))}
    end)
  end

  def forget(state, old_min) do
    Agent.update(state,
      fn s ->
        Enum.reduce old_min..min_done(s.done)-1, s,
        fn index, s ->
          case s.log[index] do
            nil -> s
            _ -> elem Map.pop!(s.log, index), 1
          end
        end
      end)
  end
end
