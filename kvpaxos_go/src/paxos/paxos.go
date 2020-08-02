package paxos

//
// Paxos library, to be included in an application.
// Multiple applications will run, each including
// a Paxos peer.
//
// Manages a sequence of agreed-on values.
// The set of peers is fixed.
// Copes with network failures (partition, msg loss, &c).
// Does not store anything persistently, so cannot handle crash+restart.
//
// The application interface:
//
// px = paxos.Make(peers []string, me string)
// px.Start(seq int, v interface{}) -- start agreement on new instance
// px.Status(seq int) (Fate, v interface{}) -- get info about an instance
// px.Done(seq int) -- ok to forget all instances <= seq
// px.Max() int -- highest instance seq known, or -1
// px.Min() int -- instances before this seq have been forgotten
//

import (
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/rpc"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var showLock bool = false    // for debuggin deadlock
var showContext bool = false // for normal debugging
var showDetail bool = false  // for detailed debugging

// px.Status() return values, indicating
// whether an agreement has been decided,
// or Paxos has not yet reached agreement,
// or it was agreed but forgotten (i.e. < Min()).
type Fate int

const (
	Decided   Fate = iota + 1
	Pending        // not yet decided.
	Forgotten      // decided but forgotten.
)

type Paxos struct {
	mu         sync.Mutex
	l          net.Listener
	dead       int32 // for testing
	unreliable int32 // for testing
	rpcCount   int32 // for testing
	peers      []string
	me         int // index into peers[]

	group_size int // the number of peers in the group, fixed.
	instances  map[int]*paxosInstance
	max_index  int   // the maximum index seen by proposer
	z          []int // z[i] for me
	// if acceptedProposals[index] == Infty, then it's chosen
}

//
// call() sends an RPC to the rpcname handler on server srv
// with arguments args, waits for the reply, and leaves the
// reply in reply. the reply argument should be a pointer
// to a reply structure.
//
// the return value is true if the server responded, and false
// if call() was not able to contact the server. in particular,
// the replys contents are only valid if call() returned true.
//
// you should assume that call() will time out and return an
// error after a while if it does not get a reply from the server.
//
// please use call() to send all RPCs, in client.go and server.go.
// please do not change this function.
//
func call(srv string, name string, args interface{}, reply interface{}) bool {
	c, err := rpc.Dial("unix", srv)
	if err != nil {
		err1 := err.(*net.OpError)
		if err1.Err != syscall.ENOENT && err1.Err != syscall.ECONNREFUSED {
			// fmt.Printf("paxos Dial() failed: %v\n", err1)
		}
		return false
	}
	defer c.Close()

	err = c.Call(name, args, reply)
	if err == nil {
		return true
	}

	fmt.Println(err)
	return false
}

//
// the application wants paxos to start agreement on
// instance seq, with proposed value v.
// Start() returns right away; the application will
// call Status() to find out if/when agreement
// is reached.
//
func (px *Paxos) Start(seq int, v interface{}) {
	// Your code here.
	go func() {
		px.propose(seq, v)
	}()
}

//
// the application on this machine is done with
// all instances <= seq.
//
// see the comments for Min() for more explanation.
//
func (px *Paxos) Done(seq int) {
	px.mu.Lock()
	if showLock {
		fmt.Printf("Done %d gains the lock\n", px.me)
		defer fmt.Printf("Done %d releases the lock\n", px.me)
	}
	defer px.mu.Unlock()
	px.z[px.me] = Max(px.z[px.me], seq)
	px.max_index = Max(px.max_index, seq)
}

func (px *Paxos) forget(oldMin int) {
	if showContext {
		fmt.Printf("[DONE]peer: %d\toldMin: %d\tnewMin: %d\n", px.me, oldMin, px.Min())
	}
	px.mu.Lock()
	defer px.mu.Unlock()
	for i := oldMin; i < px.Min(); i++ {
		if showContext {
			fmt.Printf("[DELETE] delete instance %d for peer %d\n", i, px.me)
		}
		delete(px.instances, i)
	}
}

//
// the application wants to know the
// highest instance sequence known to
// this peer.
//
func (px *Paxos) Max() int {
	px.mu.Lock()
	defer px.mu.Unlock()
	return px.max_index
}

//
// Min() should return one more than the minimum among z_i,
// where z_i is the highest number ever passed
// to Done() on peer i. A peers z_i is -1 if it has
// never called Done().
//
// Paxos is required to have forgotten all information
// about any instances it knows that are < Min().
// The point is to free up memory in long-running
// Paxos-based servers.
//
// Paxos peers need to exchange their highest Done()
// arguments in order to implement Min(). These
// exchanges can be piggybacked on ordinary Paxos
// agreement protocol messages, so it is OK if one
// peers Min does not reflect another Peers Done()
// until after the next instance is agreed to.
//
// The fact that Min() is defined as a minimum over
// *all* Paxos peers means that Min() cannot increase until
// all peers have been heard from. So if a peer is dead
// or unreachable, other peers Min()s will not increase
// even if all reachable peers call Done. The reason for
// this is that when the unreachable peer comes back to
// life, it will need to catch up on instances that it
// missed -- the other peers therefor cannot forget these
// instances.
//
func (px *Paxos) Min() int {
	result := px.z[px.me]
	for _, zi := range px.z {
		result = Min(result, zi)
	}
	return result + 1
}

//
// the application wants to know whether this
// peer thinks an instance has been decided,
// and if so what the agreed value is. Status()
// should just inspect the local peer state;
// it should not contact other Paxos peers.
//
func (px *Paxos) Status(seq int) (Fate, interface{}) {
	if showLock {
		fmt.Printf("status %d waiting for the lock...\n", px.me)
	}
	px.mu.Lock()
	if showLock {
		defer fmt.Printf("status %d release the lock\n", px.me)
	}
	defer px.mu.Unlock()
	if seq < px.Min() {
		return Forgotten, nil
	}
	_, ok := px.instances[seq]
	if ok && px.isDecided(seq) {
		return Decided, px.instances[seq].acceptedValue
	}
	// if ok {
	// 	return Pending, px.instances[seq].acceptedProposal
	// }
	return Pending, nil
}

//
// tell the peer to shut itself down.
// for testing.
// please do not change these two functions.
//
func (px *Paxos) Kill() {
	atomic.StoreInt32(&px.dead, 1)
	if px.l != nil {
		px.l.Close()
	}
}

//
// has this peer been asked to shut down?
//
func (px *Paxos) isdead() bool {
	return atomic.LoadInt32(&px.dead) != 0
}

// please do not change these two functions.
func (px *Paxos) setunreliable(what bool) {
	if what {
		atomic.StoreInt32(&px.unreliable, 1)
	} else {
		atomic.StoreInt32(&px.unreliable, 0)
	}
}

func (px *Paxos) isunreliable() bool {
	return atomic.LoadInt32(&px.unreliable) != 0
}

//
// the application wants to create a paxos peer.
// the ports of all the paxos peers (including this one)
// are in peers[]. this servers port is peers[me].
//
func Make(peers []string, me int, rpcs *rpc.Server) *Paxos {
	px := &Paxos{}
	px.peers = peers
	px.me = me

	px.group_size = len(peers)
	px.instances = make(map[int]*paxosInstance)
	px.max_index = -1                 // as required in the lab statement
	px.z = make([]int, px.group_size) // as required in the comment for Min()
	for i := 0; i < px.group_size; i++ {
		px.z[i] = -1
	}

	if rpcs != nil {
		// caller will create socket &c
		rpcs.Register(px)
	} else {
		rpcs = rpc.NewServer()
		rpcs.Register(px)

		// prepare to receive connections from clients.
		// change "unix" to "tcp" to use over a network.
		os.Remove(peers[me]) // only needed for "unix"
		l, e := net.Listen("unix", peers[me])
		if e != nil {
			log.Fatal("listen error: ", e)
		}
		px.l = l

		// please do not change any of the following code,
		// or do anything to subvert it.

		// create a thread to accept RPC connections
		go func() {
			for px.isdead() == false {
				conn, err := px.l.Accept()
				if err == nil && px.isdead() == false {
					if px.isunreliable() && (rand.Int63()%1000) < 100 {
						// discard the request.
						conn.Close()
					} else if px.isunreliable() && (rand.Int63()%1000) < 200 {
						// process the request but force discard of reply.
						c1 := conn.(*net.UnixConn)
						f, _ := c1.File()
						err := syscall.Shutdown(int(f.Fd()), syscall.SHUT_WR)
						if err != nil {
							fmt.Printf("shutdown: %v\n", err)
						}
						atomic.AddInt32(&px.rpcCount, 1)
						go rpcs.ServeConn(conn)
					} else {
						atomic.AddInt32(&px.rpcCount, 1)
						go rpcs.ServeConn(conn)
					}
				} else if err == nil {
					conn.Close()
				}
				if err != nil && px.isdead() == false {
					fmt.Printf("Paxos(%v) accept: %v\n", me, err.Error())
				}
			}
		}()
	}

	return px
}

type paxosInstance struct {
	acceptedValue       interface{}
	acceptedProposal    ProposalNumber
	max_round_seen      int
	max_proposal_number ProposalNumber
}

func printdead(id int) {
	fmt.Printf("[DEAD]: peer %d becomes dead!\n", id)
}

type Prepare struct {
	N     ProposalNumber
	Index int // the index of the log entry
}

type Promise struct {
	Max_proposal_number ProposalNumber
	AcceptedProposal    ProposalNumber
	AcceptedValue       interface{}
	Index               int
	AlreadyDecided      bool
}

type Accept struct {
	N      ProposalNumber
	Value  interface{}
	Index  int
	Done   int
	Sender int
}

type Accepted struct {
	Max_proposal_number ProposalNumber
	Index               int
	Done                int
	AlreadyDecided      bool
}

type Decide struct {
	Index         int
	AcceptedValue interface{}
}

func (px *Paxos) createInstance(index int) {
	_, ok := px.instances[index]
	if !ok {
		px.instances[index] = &paxosInstance{max_proposal_number: smallestProposal(), max_round_seen: 0}
		// fmt.Printf("instance %d has been created for peer %d\n", index, px.me)
	}
}

func (px *Paxos) propose(index int, v interface{}) {

	// if it's not pending, then don't propose it
	state, _ := px.Status(index)

	if showContext {
		// fmt.Printf("[PROBE] peer %d's state for index %d: %v %s\n", px.me, index, state, v)
	}

	if state != Pending {
		return
	}
	defer px.forget(px.Min())
	px.mu.Lock()
	if showLock {
		fmt.Printf("proposer %d gains the lock\n", px.me)
	}
	px.max_index = Max(index, px.max_index)

	// initialize when necessary
	px.createInstance(index)
	px.mu.Unlock()
	if showLock {
		fmt.Printf("proposer %d releases the lock\n", px.me)
	}

	delay := 10 * time.Millisecond
	for true {

		px.mu.Lock()
		_, ok := px.instances[index]
		if !ok {
			px.mu.Unlock()
			return
		}
		n := px.nextProposalNumber(index)
		px.mu.Unlock()

		ok, acceptedValue := px.sendPrepare(index, n)

		if acceptedValue != nil {
			v = acceptedValue
		}

		if ok {
			// if the proposer gains promises from majority
			ok := px.sendAccept(index, n, v)
			if ok {
				px.Decide(index, v)
				return
			} else if showContext {
				fmt.Printf("[FAILED] peer %d failed to gain accepts for index %d from majority\n", px.me, index)
			}

		} else if showContext {
			fmt.Printf("[FAILED] peer %d fail to gain promises for index %d from majority\n", px.me, index)
		}

		// if it's not pending, then don't propose it
		state, _ := px.Status(index)

		if showContext {
			// fmt.Printf("[PROBE] peer %d's state for index %d: %v %s\n", px.me, index, state, v)
		}

		if state != Pending {
			return
		}

		time.Sleep(delay)
		if delay < 2*time.Second {
			delay *= 2
		}
	}
}

func (px *Paxos) sendPrepare(index int, n ProposalNumber) (bool, interface{}) {

	if showContext {
		fmt.Printf("[START] peer %d starts to propose for index %d with proposal number %s\n", px.me, index, printProposal(n))
	}

	prepare := Prepare{N: n, Index: index}
	promise := Promise{}
	var replied bool
	var promise_count int
	var max_acceptedProposal = smallestProposal()
	var acceptedValue interface{}
	// broadcast prepare to all acceptors
	for i, peer := range px.peers {
		if px.isdead() {
			if showContext {
				printdead(px.me)
			}
			break
		}
		if i != px.me {
			if showDetail {
				fmt.Printf("peer %d sending prepare with %s to %d with index %d\n", px.me, printProposal(prepare.N), i, index)
			}
			replied = call(peer, "Paxos.ReplyPrepare", &prepare, &promise)
		} else {
			px.ReplyPrepare(&prepare, &promise)
			replied = true
		}

		if replied {
			if le(promise.Max_proposal_number, n) {
				promise_count++
				if promise.AcceptedValue != nil && le(max_acceptedProposal, promise.AcceptedProposal) {
					max_acceptedProposal = promise.AcceptedProposal
					acceptedValue = promise.AcceptedValue
				}
			} else {
				// update max seen round
				// but if the instance is deleted when running, then we need to terminate first
				px.mu.Lock()
				if showLock {
					fmt.Printf("sendPrepare %d gains the lock\n", px.me)
				}
				_, ok := px.instances[index]
				if !ok {
					px.mu.Unlock()
					return false, nil
				}
				px.updateMaxRound(index, promise.Max_proposal_number)
				px.mu.Unlock()
				if showLock {
					fmt.Printf("sendPrepare %d releases the lock\n", px.me)
				}
			}

		}
	}

	return promise_count >= px.group_size/2+1, acceptedValue
}

func (px *Paxos) ReplyPrepare(prepare *Prepare, promise *Promise) error {
	index := prepare.Index
	px.mu.Lock()
	if showLock {
		fmt.Printf("acceptor %d gains the lock in prepare\n", px.me)
		defer fmt.Printf("acceptor %d releases the lock in prepare\n", px.me)
	}
	defer px.mu.Unlock()
	px.createInstance(index)
	promise.Max_proposal_number = px.instances[index].max_proposal_number
	promise.Index = index

	if showDetail {
		if true {
			fmt.Printf("acceptor %d receives prepare %s for index %d\n", px.me, printProposal(prepare.N), index)
			fmt.Printf("acceptor %d max proposal number for index %d is %s\n", px.me, index, printProposal(px.instances[index].max_proposal_number))
		}
	}

	if less(px.instances[index].max_proposal_number, prepare.N) {
		px.instances[index].max_proposal_number = prepare.N

		if showDetail {
			fmt.Printf("acceptor %d promises to %s\n", px.me, printProposal(px.instances[index].max_proposal_number))
		}

		if px.instances[index].acceptedValue != nil {
			promise.AcceptedValue = px.instances[index].acceptedValue
			promise.AcceptedProposal = px.instances[index].acceptedProposal
		} else {
			promise.AcceptedValue = nil
		}
	}
	return nil
}

func (px *Paxos) sendAccept(index int, n ProposalNumber, v interface{}) bool {
	replied := false
	accept_count := 0
	accept := Accept{Sender: px.me, N: n, Value: v, Index: index, Done: px.z[px.me]}
	for i, peer := range px.peers {
		if px.isdead() {
			if showContext {
				printdead(px.me)
			}
			break
		}

		var accepted = Accepted{}
		if i != px.me {
			replied = call(peer, "Paxos.ReplyAccept", &accept, &accepted)
		} else {
			px.ReplyAccept(&accept, &accepted)
			replied = true
		}

		if replied {

			if showDetail {
				fmt.Printf("max_proposal_number from %d is %s\n", i, printProposal(accepted.Max_proposal_number))
			}

			if accepted.Max_proposal_number == n || accepted.AlreadyDecided {
				accept_count++
			}

			// if the instance is deleted when running, terminate
			px.mu.Lock()
			if showLock {
				fmt.Printf("sendAccept %d gains the lock\n", px.me)
			}
			if i != px.me {
				px.z[i] = Max(px.z[i], accepted.Done)
			}
			_, ok := px.instances[index]
			if !ok {
				px.mu.Unlock()
				return false
			}
			px.updateMaxRound(index, accepted.Max_proposal_number)
			px.mu.Unlock()
			if showLock {
				fmt.Printf("send Accept %d releases the lock\n", px.me)
			}
		}
	}

	return accept_count >= px.group_size/2+1
}

func (px *Paxos) ReplyAccept(accept *Accept, accepted *Accepted) error {
	index := accept.Index
	px.mu.Lock()
	if showLock {
		fmt.Printf("acceptor %d gains the lock\n", px.me)
		defer fmt.Printf("acceptor %d releases the lock\n", px.me)
	}
	defer px.mu.Unlock()
	px.createInstance(index)

	if showDetail {
		fmt.Printf("acceptor %d receives accept %s for index %d\n", px.me, printProposal(accept.N), index)
		fmt.Printf("acceptor %d max proposal number for index %d is %s\n", px.me, index, printProposal(px.instances[index].max_proposal_number))
	}

	if px.isDecided(index) {
		accepted.AlreadyDecided = true
	} else if le(px.instances[index].max_proposal_number, accept.N) {
		//fmt.Printf("acceptor %d accepts the value %v\n", px.me, accept.Value)
		px.instances[index].max_proposal_number = accept.N
		px.instances[index].acceptedProposal = accept.N
		px.instances[index].acceptedValue = accept.Value
	}
	px.z[accept.Sender] = Max(px.z[accept.Sender], accept.Done)
	accepted.Index = index
	accepted.Max_proposal_number = px.instances[index].max_proposal_number
	accepted.Done = px.z[px.me]
	// fmt.Printf("acceptor %d replies with proposal number %s\n", px.me, printProposal(accepted.Max_proposal_number))
	return nil
}

func (px *Paxos) Decide(index int, v interface{}) {
	// fmt.Printf("proposer %d gains accepted from majority with %v\n", px.me, v)
	// accepted by majority, the value is chosen
	decided := Decide{Index: index, AcceptedValue: v}
	learned := false
	learnedCount := 0
	for i, peer := range px.peers {
		if i != px.me {
			learned = call(peer, "Paxos.Learn", decided, nil)
		} else {
			px.Learn(decided, nil)
			learned = true
		}

		if learned {
			learnedCount++
		}
	}

	if learnedCount >= px.group_size/2+1 {
		if showContext {
			// fmt.Printf("[FINISH] peer %d finished the propose for index %d with value %v\n", px.me, index, v)
			fmt.Printf("[FINISH] peer %d finished the propose for index %d\n", px.me, index)
		}
	} else if showContext {
		fmt.Printf("[TO BE CONTINUED] index %d has been learned by only %d learners\n", index, learnedCount)
	}
}

func (px *Paxos) Learn(decide Decide, dummy *Decide) error {
	index := decide.Index
	status, _ := px.Status(index)
	px.mu.Lock()
	if showLock {
		fmt.Printf("learn %d gains the lock\n", px.me)
		defer fmt.Printf("learn %d releases the lock\n", px.me)
	}
	defer px.mu.Unlock()
	if status == Pending {
		px.createInstance(index)
		px.instances[index].acceptedValue = decide.AcceptedValue
		px.setDecided(index)
		if showContext {
			fmt.Printf("[LEARN] learner %d has learned for index %d\n", px.me, index)
		}
	}
	return nil
}
