defmodule PrepareReceiver do
  import ProposalNumber
  defstruct [count: 0, max_proposal: smallest(), accepted_value: nil, max_round: 0]
  use Agent

  def start_link(_arg) do
    Agent.start_link(fn -> %PrepareReceiver{} end)
  end

  def add_count(agent) do
    Agent.update(agent, fn s -> %{s |count: s.count + 1} end)
  end

  def update(agent, ap, av) do
    Agent.update(agent, fn s -> cond do
      av != nil && less?(s.max_proposal, ap) -> %{s | max_proposal: ap, accepted_value: av}
      true -> s
    end end)
  end

  def update_mr(agent, mpn) do
    Agent.update(agent, fn s -> %{s | max_round: max(s.max_round, mpn.round)} end)
  end

  def promise_status(agent) do
    Agent.get(agent, fn s -> {s.count, s.accepted_value, s.max_round} end)
  end

  def stop_receive(agent) do
    Agent.stop(agent)
  end

end
