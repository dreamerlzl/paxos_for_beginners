{application,kvpaxos,
             [{applications,[kernel,stdlib,elixir,logger]},
              {description,"kvpaxos"},
              {modules,['Elixir.AcceptReceiver','Elixir.KVOperation',
                        'Elixir.KVPaxos','Elixir.Message',
                        'Elixir.Message.Accept','Elixir.Message.Accepted',
                        'Elixir.Message.Learn','Elixir.Message.Prepare',
                        'Elixir.Message.Promise','Elixir.Paxos',
                        'Elixir.PaxosState','Elixir.PaxosState.PaxosEntry',
                        'Elixir.PrepareReceiver','Elixir.ProposalNumber']},
              {registered,[]},
              {vsn,"0.1.0"}]}.