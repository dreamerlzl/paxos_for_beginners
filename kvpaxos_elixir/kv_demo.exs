defmodule KVDemo do
  # Code.require_file("demo.exs")

  def paxos_peers do
    {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
  end

  def kv_peers do
    {{:global, :KV1}, {:global, :KV2}, {:global, :KV3}}
  end

  def start_paxos do
    peers = paxos_peers()
    for i <- 0..(tuple_size(peers)-1), do: GenServer.start(Paxos, {peers, i}, name: elem(peers, i))
  end

  def start_all_kv do
    for i <- 0..(tuple_size(kv_peers())-1), do: GenServer.start(KVPaxos, elem(paxos_peers(), i), name: elem(kv_peers(), i))
  end

  def start_kv_server(peer, name) do
    GenServer.start(KVPaxos, peer, name: name)
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
end
