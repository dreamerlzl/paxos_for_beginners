defmodule Paxos do
  import PaxosState
  alias PaxosState.PaxosEntry
  import ProposalNumber
  import PrepareReceiver
  import AcceptReceiver
  alias Message.{Prepare, Promise, Accept, Accepted, Learn}

  @single_conn_timeout 300
  @max_delay 300 # max proposal delay
  @retry_times 5
  @detail false
  @context false
  @lock false
  @debug false

  use GenServer

  @impl true
  def init({peers, me}) do
    size = tuple_size(peers)
    cond do
      size < 3 -> {:stop, "consensus needs odd number of nodes larger than 1!(provided peers: #{peers})"}
      size >= 3 ->
        {_, notebook} = PaxosState.start_link({me, size});
        {:ok, %{peers: peers, me: me, majority: floor(size/2) + 1, notebook: notebook}}
    end
  end

  @impl true
  def handle_call({:done, done_index}, _from, state) do
    done(state.notebook, done_index)
    {:reply, :ok, state}
  end

  # # receive a client's request and starts to propose the value
  # @impl true
  # def handle_call({:start, value}, from, state) do
  #   spawn(fn -> send (elem from, 0), fill_hole(state, value) end)
  #   {:reply, :ok, state}
  # end

  # reply the other peers' prepare msgs
  @impl true
  def handle_call({type, msg}, from, state) do
    f =
      case type do
        :start -> &fill_hole(&1, &2)
        :propose -> &propose(&1, &2)
        :prepare -> &reply_prepare(&1, &2)
        :accept -> &reply_accept(&1, &2)
        :learn -> &reply_learn(&1, &2)
        :status -> &entry_status(&1, &2)
      end
    # spawn(fn -> GenServer.reply(from, f.(state, msg)) end)
    # {:noreply, state}
    spawn(fn -> send (elem from, 0), f.(state, msg) end)
    {:reply, :ok, state}
  end

  defp fill_hole(state, value) do
    notebook = state.notebook
    old_min = min_done(get(notebook, :done))
    try do
      {first_unchosen, entry_status, v} = frontier_status(notebook)
      # this call will also increase first_unchosen_index by 1
      case entry_status do
        :pending ->
          create_entry(notebook, first_unchosen)
          {pn, candidate_value} = send_prepare_until_promise(state, first_unchosen)
          # IO.puts "candidate value: #{inspect candidate_value}"
          if candidate_value == nil || candidate_value == value do
            case send_accept(state, first_unchosen, pn, value) do
              true ->
                if @context do
                  IO.puts "value #{inspect value} has been chosen for index #{first_unchosen} on peer #{state.me}"
                end
                send_learn(state, first_unchosen, value)
                forget(notebook, old_min)
                {:ok, first_unchosen, value}
              false ->
                case propose(state, {first_unchosen, value}) do
                  {:ok, ^first_unchosen, chosen_value} ->
                    if chosen_value != value do
                      fill_hole(state, value)
                    else
                      forget(notebook, old_min)
                      {:ok, first_unchosen, value}
                    end
                  {:error, _first_unchosen, reason} -> raise reason
                end
            end
          else
            spawn(fn ->
              case send_accept(state, first_unchosen, pn, candidate_value) do
                true -> send_learn(state, first_unchosen, candidate_value)
                false -> propose(state, {first_unchosen, candidate_value})
              end
            end)
            fill_hole(state, value)
          end

        :decided ->
          if v == value do
            forget(notebook, old_min)
            {:ok, first_unchosen, value}
          else
            fill_hole(state, value)
          end
      end
    rescue
      x -> rollback_first_unchosen(notebook); {:error, x}
    catch
      :exit, r -> rollback_first_unchosen(notebook); {:error, r}
    end
  end

  defp next_delay(delay) do
    Enum.random(delay..(min 2 * delay, @max_delay))
  end

  defp propose(state, {index, value}, delay \\ 50, max_times \\ 10) do
    if @context do
      IO.puts "#{state.me} starts to propose #{inspect value} for index #{index}"
    end
    notebook = state.notebook
    {entry_status, v} = status(notebook, index)
    if entry_status != :pending do
      {:ok, index, v}
    else
      create_entry(notebook, index)
      case send_prepare(state, index) do
        {true, pn, av} ->

          value = case av do
            nil -> value
            _ -> av
          end

          if @context do
            IO.puts "#{state.me} gains promise for index #{index} with #{inspect pn} and value #{inspect value}"
          end

          case send_accept(state, index, pn, value) do
            true ->
              send_learn(state, index, value)
              if @context do
                IO.puts "value #{inspect value} has been chosen for index #{index} on peer #{state.me}"
              end
              {:ok, index, value}
            false ->
              if max_times == 1 do
                {:error, index, "Probably #{state.me} fail to contact the majority"}
              else
                Process.sleep(delay); propose(state, {index, value}, next_delay(delay), max_times - 1)
              end
          end
        {false, _, _} ->
          if max_times == 1 do
            {:error, index, "Probably #{state.me} fail to contact the majority"}
          else
            Process.sleep(delay); propose(state, {index, value}, next_delay(delay), max_times - 1)
          end
      end
    end
  end

  defp broadcast_message(state, type, msg) do
    me = elem state.peers, state.me
    s = self()
    f =
    case type do
      :prepare -> &reply_prepare(&1, &2)
      :accept -> &reply_accept(&1, &2)
      :learn -> &reply_learn(&1, &2)
    end

    state.peers
    |> Tuple.to_list
    |> Enum.with_index
    |> Enum.each(
      fn {peer, i} ->
          if @lock do
            IO.puts "#{state.me} is waiting from peer #{i}"
          end
          if peer != me do
            try do
              GenServer.call(peer, {type, msg})
            catch
              :exit, _ ->
                if @detail do
                  IO.puts "peer #{state.me} failed to hear from peer #{i}"
                end
                nil
            end
          else
            spawn(fn -> send s, f.(state, msg) end)
          end
          if @lock do
            IO.puts "#{state.me} sended #{type} to peer #{i}"
          end
      end)
  end

  # sending prepares to all nodes
  defp send_prepare(state, index) do
    pn = next_proposal_number(state.notebook, index)
    msg = %Prepare{index: index, pn: pn}
    broadcast_message(state, :prepare, msg)
    {:ok, a} = PrepareReceiver.start_link([])

    Enum.each 1..tuple_size(state.peers), fn _ ->
      receive do
        {:promise, ^index, promise} ->
          #IO.inspect promise
          if less?(promise.max_proposal, pn) do
            PrepareReceiver.add_count(a)
            PrepareReceiver.update(a, promise.accepted_proposal, promise.accepted_value)
          else
            PrepareReceiver.update_mr(a, promise.max_proposal)
          end
        after
          @single_conn_timeout -> nil
      end
    end

    {promise_count, av, mr} = promise_status(a)
    PrepareReceiver.stop_receive(a)
    update_max_round(state.notebook, index, mr)
    if @detail do
      IO.puts "promise count: #{promise_count}, #{av} for #{inspect pn}"
    end
    {promise_count >= state.majority, pn, av}
  end

  def send_prepare_until_promise(state, index, max_times \\ @retry_times) do
    if max_times == 0 do
      raise "Probably peer #{state.me} fail to contact the majority | the majority is down"
    end
    if @debug do
      IO.puts "peer #{state.me} tries to gain promise for index #{index}..."
    end
    case send_prepare(state, index) do
      {true, pn, av} -> {pn, av}
      {false, _, _} -> send_prepare_until_promise(state, index, max_times - 1)
    end
  end

  def reply_prepare(state, prepare) do
    index = prepare.index
    notebook = state.notebook
    create_entry(notebook, index)
    if @detail do
      IO.puts "#{state.me} receives prepare #{inspect prepare}"
    end
    Agent.get_and_update(notebook,
      fn s ->
        msg = {:promise, index, %Promise{
          max_proposal: s.log[index].max_proposal,
          accepted_proposal: s.log[index].accepted_proposal,
          accepted_value: s.log[index].accepted_value}}

        new_s = if less?(s.log[index].max_proposal, prepare.pn) do
          Map.put(s, :log, Map.put(s.log, index, Map.put(s.log[index], :max_proposal, prepare.pn)))
        else
          s
        end
        {msg, new_s}
      end)
  end

  def send_accept(state, index, pn, value) do
    msg = %Accept{index: index, sender: state.me, pn: pn, value: value, done_index: get_done(state.notebook, state.me)}
    broadcast_message(state, :accept, msg)

    {:ok, a} = AcceptReceiver.start_link []
    Enum.each 1..tuple_size(state.peers), fn _ ->
      receive do
        {:accepted, ^index, accepted} ->
          # IO.puts "#{state.me} receives #{inspect accepted}"
          if eq?(accepted.max_proposal, pn) do
            AcceptReceiver.add_count(a)
          end
          AcceptReceiver.update(a, accepted.max_proposal, accepted.done_index)
        after
          @single_conn_timeout -> nil
      end
    end

    {accepted_count, done_index, mr} = accept_status(a)

    update_done(state.notebook, state.me, done_index)
    update_max_round(state.notebook, index, mr)

    accepted_count >= state.majority
  end

  def reply_accept(state, accept) do
    index = accept.index
    notebook = state.notebook
    create_entry(notebook, index)

    if @detail do
      IO.puts "#{state.me} receives accept #{inspect accept}"
    end

    {:accepted, index, Agent.get_and_update(notebook,
      fn s ->
        new_entry =
        if leq?(s.log[index].max_proposal, accept.pn) do
          # IO.puts "#{state.me}'s state: #{inspect s.log[index]} accept: #{inspect accept}\n"
          %{s.log[index] | max_proposal: accept.pn, accepted_value: accept.value, accepted_proposal: accept.pn}
        else
          s.log[index]
        end

        {%Accepted{
            done_index: elem(s.done, s.me),
            max_proposal: select_larger(s.log[index].max_proposal, accept.pn)
            },

          %{s | done: put_elem(s.done, accept.sender, max(accept.done_index, elem(s.done, accept.sender))),
                log: %{s.log | index=>new_entry} }
        }
      end)
    }
  end

  def send_learn(state, index, value) do
    msg = %Learn{index: index, chosen_value: value}
    broadcast_message(state, :learn, msg)
  end

  def reply_learn(state, learn) do
    index = learn.index
    notebook = state.notebook
    create_entry(notebook, index)

    try do
      Agent.update(notebook,
        fn s ->
          entry = s.log[index]
          # not forgotten nor decided
          if index >= min_done(s.done) && !PaxosEntry.decided?(entry) do
            %{s | log: %{s.log | index => %{PaxosEntry.decide(s.log[index]) | accepted_value: learn.chosen_value}}}
          else
            s
          end
        end, 500)
      :ok
    catch
      :exit, _ -> :error
    end
  end

  def entry_status(state, index) do
    PaxosState.status(state.notebook, index)
  end

end
