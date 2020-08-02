defmodule KVPaxosTest do
  use ExUnit.Case
  doctest KVPaxos

  def start_all(peers) do
    for i <- 0..(tuple_size(peers)-1), do: GenServer.start(Paxos, {peers, i}, name: elem(peers, i))
  end

  def start_kv_server(peer, name) do
    GenServer.start_link(KVPaxos, peer, name: name)
  end

  def start_all_kv(paxos_peers, kv_peers) do
    for i <- 0..(tuple_size(kv_peers)-1), do: GenServer.start(KVPaxos, elem(paxos_peers, i), name: elem(kv_peers, i))
  end

  def update(kvs, key, value) do
    GenServer.call(kvs, %{type: :update, key: key, value: value})
  end

  def put(kvs, key, value) do
    GenServer.call(kvs, %{type: :put, key: key, value: value})
  end

  def get(kvs, key) do
    GenServer.call(kvs, %{type: :get, key: key})
  end

  def my_flush do
    Process.sleep(2000)
    messages = :erlang.process_info(self(), :messages)
    IO.inspect(messages)
  end

  test "test basic" do
    peers = {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
    start_all(peers)
    cka = {{:global, :KV1}, {:global, :KV2}, {:global, :KV3}}
    {kva, kvb, kvc} = cka
    start_all_kv(peers, cka)
    put(kva, "app", "x")
    update(kvb, "app", fn x -> x <> "y" end)
    {:ok, value} = get(kvc, "app")
    assert value == "xy"

    put(kvc, "a", "aa")
    {:ok, value} = get(kva, "a")
    assert value == "aa"
    {:ok, value} = get(kvb, "a")
    assert value == "aa"
    {:ok, value} = get(kvc, "a")
    assert value == "aa"

    spawn(fn -> put(kva, "b", 1) end)
    spawn(fn -> put(kvb, "b", 2) end)
    spawn(fn -> put(kvc, "b", 3) end)
    Process.sleep(2000)
    {:ok, chosen} = get kva, "b"
    Enum.each 1..2, fn i ->
      {:ok, value} = get(elem(cka, i), "b")
      assert value == chosen
    end

  end

  test "test sequential execution" do
    peers = {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
    start_all(peers)
    {a, _, _} = peers
    {kva, _, _} = {{:global, :KV1}, {:global, :KV2}, {:global, :KV3}}
    start_kv_server(a, kva)
    {_status, value} = put(kva, "a", 1)
    assert value == 1
    {_status, value} = update(kva, "a", fn x -> x + 1 end)
    assert value == 2
    {_status, value} = get(kva, "a")
    assert value == 2
  end

  test "test consistency" do
    peers = {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
    start_all(peers)
    {a, b, c} = peers
    {kva, kvb, kvc} = {{:global, :KV1}, {:global, :KV2}, {:global, :KV3}}
    start_kv_server(a, kva)
    start_kv_server(b, kvb)
    start_kv_server(c, kvc)

    {_status, _value} = put(kva, "a", 0)
    {_status, value} = get(kvb, "a")
    # IO.inspect "#{status} #{value}"
    assert value == 0
    {_status, _value} = update(kvc, "a", 3)
    {_status, _value} = put(kvb, "b", "sb")
    {_status, value} = get(kva, "a")
    assert value == 3
    {_status, value} = get(kvc, "b")
    assert value == "sb"
  end
end
