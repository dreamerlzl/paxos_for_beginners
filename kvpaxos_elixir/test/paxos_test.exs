defmodule PaxosTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, a} = Agent.start_link(fn -> 0 end)
    peers = {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
    %{counter: a, peers: peers}
  end

  def propose(peer, index, value, a) do
    GenServer.call(peer, {:propose, {index, value}})
    Agent.update(a, fn c -> c+1 end)
  end

  def propose(peer, index, value) do
    GenServer.call(peer, {:propose, {index, value}})
  end

  def request(peer, value) do
    GenServer.call(peer, {:start, value})
  end

  def status(peer, index) do
    try do
      GenServer.call(peer, {:status, index})
    catch
      :exit, _ ->
        # IO.puts "fail to call status index=#{index} peer=#{inspect peer}"
        send self(), {nil, nil}
    end
  end

  def my_flush do
    Process.sleep(2000)
    messages = :erlang.process_info(self(), :messages)
    IO.inspect(messages)
  end

  def start_all(peers) do
    for i <- 0..(tuple_size(peers)-1), do: GenServer.start_link(Paxos, {peers, i}, name: elem(peers, i))
  end

  def start_server(peers, id) do
    cond do
      is_integer(id) -> GenServer.start(Paxos, {peers, id}, name: elem(peers, id))
      is_tuple(id) ->
        index = Enum.find_index Tuple.to_list(peers), fn x -> x == id end
        GenServer.start(Paxos, {peers, index}, name: id)
    end
  end

  def ndecided(peers, index) do
    {count, _decided_value} =
      Enum.reduce(Tuple.to_list(peers), {0, nil},
        fn peer, {n, v} ->
          status(peer, index)
          receive do
            {:decided, value} ->
              if n > 0 do
                assert v == value, "decided values vary; index=#{index} peer=#{inspect peer} #{v} #{value}"
              end
              {n+1, value}
            {_, _} -> {n, v}
            after
              1000 -> my_flush() ; assert false, "unexpected timeout for getting the status for peer=#{inspect peer} index=#{index}"
          end
        end)
    count
  end

  def waitn(peers, index, wanted, max_times \\ 10, delay \\ 100) do
    nd = ndecided(peers, index)
    cond do
      nd  >= wanted -> nil
      true ->
        cond do
          max_times <= 1 ->
            assert nd >= wanted, "too few decided; index=#{index} ndecided=#{nd} wanted=#{wanted}"
          max_times > 1 ->
            new_delay = min(delay *2, 1000)
            Process.sleep(new_delay);
            waitn(peers, index, wanted, max_times - 1, new_delay)
        end
    end
  end

  def wait_majority(peers, index) do
    waitn(peers, index, floor(tuple_size(peers)/2)+1)
  end

  test "test basic", %{counter: _a, peers: peers} do
    start_all(peers)
    peers_list = Tuple.to_list(peers)
    npaxos = tuple_size(peers)
    {a, b, c} = peers
    request(a, "hello")
    waitn(peers, 0, npaxos)

    Enum.each peers_list,
      fn peer ->
        propose(peer, 1, 77)
      end

    waitn(peers, 1, npaxos)

    propose(a, 2, 100)
    propose(b, 2, 101)
    propose(c, 2, 102)
    waitn(peers, 2, npaxos)

    pxa = peers
    propose(a, 7, 700)
    propose(a, 6, 600)
    propose(b, 5, 500)
    waitn(pxa, 7, npaxos)
    propose(a, 4, 400)
    propose(b, 3, 300)
    waitn(pxa, 6, npaxos)
    waitn(pxa, 5, npaxos)
    waitn(pxa, 4, npaxos)
    waitn(pxa, 3, npaxos)
  end

  test "test deaf" do
    pxa = {{:global, :Node1}, {:global, :Node2}, {:global, :Node3}, {:global, :Node4}, {:global, :Node5}}
    {a,b,_c,_d,e} = pxa
    npaxos = tuple_size(pxa)
    Enum.each 1..(npaxos-2), fn i ->
      start_server(pxa, i)
    end

    propose(b, 1, "goodbye")
    Process.sleep(1000)
    wait_majority(pxa, 1)
    nd = ndecided(pxa, 1)
    assert nd <= npaxos - 2, "a deaf node heard a decision #{nd}"

    start_server(pxa, 0)
    propose(a, 1, "xxx")
    waitn(pxa, 1, npaxos - 1)
    assert ndecided(pxa, 1) == npaxos - 1, "a deaf node heard about a decision"

    start_server(pxa, e)
    propose(e, 1, "yyy")
    waitn(pxa, 1, npaxos)
  end

  test "test fillHole", %{counter: a, peers: peers} do
    start_all(peers)
    {node0, node1, node2} = peers

    propose(node0, 0, "node0", a)
    propose(node2, 0, "node2", a)

    first_chosen =
      receive do
        {:ok, 0, value} -> value
      end

    receive do
      {:ok, 0, value} -> assert first_chosen == value
        # code
    end

    Process.sleep(500)
    request(node1, "node1")
    receive do
      {:ok, 1, value} ->
        assert value == "node1"
    end

  end

  test "test consistency", %{counter: a} do
    peers = {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
    start_all(peers)
    {node0, node1, node2} = peers
    propose(node0, 0, 1, a)
    propose(node1, 0, 2, a)
    propose(node2, 0, 3, a)

    # my_flush()

    count = Agent.get(a, fn c -> c end)

    decided_value = receive do
      {:ok, _index, value} -> value
    after
      1000 -> IO.puts "timeout"; nil
    end

    Enum.each 2..count,
      fn _ ->
        receive do
          {:ok, _index, value} -> assert value == decided_value
          after
            1000 -> IO.puts "timeout"
        end
      end
  end

end
