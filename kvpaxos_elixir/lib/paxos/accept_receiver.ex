defmodule AcceptReceiver do
  defstruct [count: 0, max_round: 0, done_index: -1]
  use Agent

  def start_link(_arg) do
    Agent.start_link(fn -> %AcceptReceiver{} end)
  end

  def add_count(agent) do
    Agent.update(agent, fn s -> %{s |count: s.count + 1} end)
  end

  def update(agent, mpn, di) do
    Agent.update(agent, fn s -> %{s | max_round: max(s.max_round, mpn.round), done_index: max(s.done_index, di)} end)
  end

  def accept_status(agent) do
    Agent.get(agent, fn s -> {s.count, s.done_index, s.max_round} end)
  end

  def stop_receive(agent) do
    Agent.stop(agent)
  end

end
