## Info
- This is Ziliang Lin's final project for CSC458, 2020 Spring, UR
- A simple Key/Value Service based on Multi-Paxos
    - check my [blog about single-decree paxos](https://medium.com/distributed-knowledge/paxos-consensus-for-beginners-1b8519d3360f)
- The `kvpaxos_go` folder contains the source for single machine version
- The `kvpaxos_elixir` folder contains the source for Elixir version

## Run
### Golang
- Install golang and configure environment so that can run `go` directly under command line 
- Add `kvpaxos_go` to `$GOPATH`
- Under the directory of `kvpaxos_go/src/paxos` or `kvpaxos_go/src/kvpaxos`, type `go test` to run the test for it, respectively.

### Elixir
- Install Elixir 
    - [https://elixir-lang.org/install.html](https://elixir-lang.org/install.html)
- Under `kvpaxos_elixir`, type `mix compile` to build
- So far there are only simple tests
    - under `kvpaxos_elixir`, type `mix test`
- Check `paxos_test.exs` and `kv_paxos_test.exs` under `kvpaxos_elixir/test/` for simple usage examples
- To run across remote nodes, make sure all the nodes have installed Elixir, and on each node under `kvpaxos_elixir`, do the following:
    - launch REPL `iex --sname <nodename>@<IP> --cookie 123 -S mix`
        - cookie can be anything, but all the nodes should have the same one
    - Make nodes connect to each other by typing `Node.connect(:<nodename>@<IP>)`
    - Start servers on some nodes with registry
        - e.g., `GenServer.start(Paxos, {{{:global, :Node0}, {:global, :Node1}, {:global, :Node2}}, 0}, name: {:global, :Node0})`
    - Now you can type the following to start using Paxos to propose a value
        - e.g., to request a value 1, type `GenServer.call({:global, :Node0}, {:start, 1})`
    - see [https://elixirschool.com/en/lessons/advanced/otp-distribution/#communication-between-nodes](https://elixirschool.com/en/lessons/advanced/otp-distribution/#communication-between-nodes)

## Implementation Details

### Commons
- There is a global lock for the log on each paxos node; i.e., the acceptor of a node can only deal with one prepare at any instant
    - in Elixir this is implicitly implemented via `Agent`, a process storing states
- Using a logical proposal number (round, id) and all details about it is hided in the `src/paxos/proposalNumber.go` 
    - the max round seen is updated in the accept phase
- Randomized delay between re-proposes to reduce livelock

### Golang
- Golang version is mainly for first ensuring algorithm's correctness
- Each proposer can only propose for one entry at any instant
- All paxos communications are synchronous

### Elixir
- Its tools and environments are more friendly for testing on different nodes
- All paxos communications are asynchronous
- Each proposer can propose for multiple entries at the same time
