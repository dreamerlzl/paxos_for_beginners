defmodule KVPaxos do
  @moduledoc """
  Documentation for `KVPaxos`.
  """

  @doc """

  """
  use GenServer

  @request_timeout 1000
  @retry_times 5

  @impl true
  def init(paxos_peer) do
    {:ok, %{px: paxos_peer, map: %{}, delivered: MapSet.new(), progress: -1}}
  end

  @impl true
  def handle_call(x, _from, state) do
    this_request_id = KVOperation.gen_id()
    try do
      value =
        case x.type do
          :get -> %KVOperation{type: x.type, key: x.key, id: this_request_id}
          :put -> %KVOperation{type: x.type, key: x.key, value: x.value, id: this_request_id}
          :update -> %KVOperation{type: x.type, key: x.key, value: x.value, id: this_request_id}
        end
      # may exit if the paxos peer crashed
      request(state.px, value)
      {new_map, new_delivered, new_progress, reply} =
        receive do
          {:ok, idx, _} ->
            {temp_map, temp_delivered} =
              if idx - state.progress >= 2 do
                Enum.reduce((state.progress+1)..(idx-1), {state.map, state.delivered},
                  fn i, {m, d} ->
                    {status, op} = get_map_entry(state.px, i)
                    {_, op} =
                    if status != :decided do
                      propose(state.px, i, nil)
                    else
                      {nil, op}
                    end
                    if !is_map(op) || MapSet.member?(d, op.id) do
                      # already delivered
                      {m, d}
                    else
                      {execute(m, op), MapSet.put(d, op.id)}
                    end
                  end)
              else
                {state.map, state.delivered}
              end

            temp_map = case value.type do
              :get -> temp_map
              :put -> execute(temp_map, value)
              :update -> execute(temp_map, value)
            end

            reply =
              if Map.has_key?(temp_map, value.key) do
                  {:ok, temp_map[value.key]}
              else
                  {:error, "the key doesn't exist"}
              end

            temp_delivered = MapSet.put(temp_delivered, this_request_id)
            {temp_map, temp_delivered, idx, reply}
        after
          @request_timeout -> {state.map, state.delivered, state.progress, {:error, "fail to contact paxos peer #{inspect state.px}\n"}}
        end

      {:reply, reply, %{state | map: new_map, progress: new_progress, delivered: new_delivered} }
    rescue
      e in KeyError -> {:reply, {:error, "The passed arg should have key: #{e.key}"}, state}
      _e in CaseClauseError -> {:reply, {:error, "The operation must be one of get/put/update"}, state}
      reason -> {:reply, {:error, reason}, state}
    catch
      :exit, _ -> {:reply, {:error, "Probably the paxos peer #{inspect state.px} has crashed"} , state}
    end
  end

  def execute(map, op) do
    case op do
      %KVOperation{type: :put, key: k, value: v} ->
        Map.put(map, k, v)
      %KVOperation{type: :update, key: k, value: v} ->
        cond do
          !Map.has_key?(map, k) -> throw("[ERROR] The key #{k} doesn't exist")
          is_function(v) -> %{map | k => v.(map[k])}
          true -> %{map | k => v}
        end
      %KVOperation{type: :get} -> map
    end
  end

  def request(peer, value) do
    GenServer.call(peer, {:start, value})
  end

  def propose(peer, index, value, retry_times \\ @retry_times, delay \\ 50) do
    if retry_times == 0 do
      throw("[ERROR]: fail to know the chosen operation for index #{index}\n")
    end
    GenServer.call(peer, {:propose, {index, value}})
    receive do
      {index, value} -> {index, value}
    after
      @request_timeout ->
        new_delay = min(1000, 2 * delay)
        propose(peer, index, value, retry_times - 1, new_delay)
    end
  end

  def get_map_entry(peer, index, retry_times \\ @retry_times) do
    if retry_times == 0 do
      throw("[ERROR]: fail to get entry for index #{index}\n")
    end
    GenServer.call(peer, {:status, index})
    receive do
      {status, value} -> {status, value}
    after
      @request_timeout -> get_map_entry(peer, index, retry_times - 1)
    end
  end

end
