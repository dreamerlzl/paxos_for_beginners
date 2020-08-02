defmodule Demo do

  def peers do
    {{:global, :Alpha}, {:global, :Beta}, {:global, :Gamma}}
  end

  def start_all do
    for id <- 0..(tuple_size(peers())-1), do: GenServer.start(Paxos, {peers(), id}, name: elem(peers(), id))
  end

  def start_server(id) do
    cond do
      is_integer(id) -> GenServer.start(Paxos, {peers(), id}, name: elem(peers(), id))
      is_tuple(id) ->
        index = Enum.find_index Tuple.to_list(peers()), fn x -> x == id end
        GenServer.start(Paxos, {peers(), index}, name: id)
    end
  end

  def propose(peer, index, value) do
    GenServer.call(peer, {:propose, {index, value}})
  end

  def request(peer, value) do
    GenServer.call(peer, {:start, value})
  end

  def let_crash(peer) do
    try do
      # send an unhandled message
      GenServer.call(peer, {:kill})
    rescue
      x -> IO.puts x
    catch
      :exit, _ -> IO.puts "The server #{inspect peer} crashed"
    end
  end

end
