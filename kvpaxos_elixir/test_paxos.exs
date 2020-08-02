defmodule TestPaxos do
  def propose(peer, index, value, a) do
    GenServer.call(peer, {:propose, {index, value}})
    Agent.update(a, fn c -> c+1 end)
  end

  def request(peer, value) do
    GenServer.call(peer, {:start, value})
  end

  def my_flush do
    Process.sleep(2000)
    messages = :erlang.process_info(self(), :messages)
    IO.inspect(messages)
  end

  def start_servers(peers) do
    for i <- 0..(tuple_size(peers)-1), do: GenServer.start_link(Paxos, {peers, i}, name: elem(peers, i))
  end

  def test1 do
    peers = {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
    start_servers(peers)
    {node0, node1, node2} = peers
    {:ok, a} = Agent.start_link(fn -> 0 end)

    propose(node0, 0, "node0", a)
    propose(node2, 0, "node2", a)
    # Process.sleep(500)
    # request(node0, 2)
    request(node1, "node1")
    Process.sleep(1000)
    my_flush()
  end

end
