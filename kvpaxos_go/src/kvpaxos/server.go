package kvpaxos

import (
	"encoding/gob"
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

	"../paxos"
)

const Debug = 0

func DPrintf(format string, a ...interface{}) (n int, err error) {
	if Debug > 0 {
		log.Printf(format, a...)
	}
	return
}

const (
	getOp    = 0
	putOp    = 1
	appendOp = 2
)

type opType int

type Op struct {
	// Your definitions here.
	// Field names must start with capital letters,
	// otherwise RPC will break.
	Key   string
	Value string
	T     opType
	Id    int64
}

func (op *Op) toString() string {
	var t string
	switch op.T {
	case getOp:
		t = "get"
	case putOp:
		t = "put"
	case appendOp:
		t = "append"
	}
	var value string
	if t == "get" {
		value = ""
	} else {
		value = op.Value
	}

	return fmt.Sprintf("(%s, %s, %s)", t, op.Key, value)
}

type KVPaxos struct {
	mu         sync.Mutex
	l          net.Listener
	me         int
	dead       int32 // for testing
	unreliable int32 // for testing
	px         *paxos.Paxos

	// Your definitions here.
	data               map[string]string // stores the key-value pair
	delivered          map[int64]bool    // record already delivered operation's id
	firstUnchosenIndex int               // the first seq/index available for the client's request
	name               byte
}

func (kv *KVPaxos) wait(seq int) Op {
	to := 10 * time.Millisecond
	for {
		status, v := kv.px.Status(seq)
		if status == paxos.Decided {
			return v.(Op)
		}
		time.Sleep(to)
		if to < 10*time.Second {
			to *= 2
		}
	}
}

func (kv *KVPaxos) execute(op Op, index int) {
	_, ok := kv.delivered[op.Id]
	if ok { // already delivered
		return
	}
	if op.T == putOp {
		kv.data[op.Key] = op.Value
	} else if op.T == appendOp {
		v, ok := kv.data[op.Key]
		if ok {
			kv.data[op.Key] = v + op.Value
		} else {
			kv.data[op.Key] = op.Value
		}
	}

	if op.T == getOp {
		DPrintf("kvpaxos %d's value for key %s: %s\n", kv.me, op.Key, kv.data[op.Key])
	} else {
		kv.delivered[op.Id] = true
		DPrintf("kvpaxos %d deliver op %d:%s for index %d!\n", kv.me, op.Id, op.toString(), index)
	}
}

func (kv *KVPaxos) fillHole(op Op) {
	DPrintf("kvpaxos %d looking for op %s...\n", kv.me, op.toString())
	var decidedOp Op
	for {
		state, v := kv.px.Status(kv.firstUnchosenIndex)
		// note that former gets could be ignored
		if state == paxos.Pending { // either the frontier or my illusion
			kv.px.Start(kv.firstUnchosenIndex, op)
			decidedOp = kv.wait(kv.firstUnchosenIndex)
			DPrintf("kvpaxos %d filles the hole at index %d!\n", kv.me, kv.firstUnchosenIndex)
		} else if state == paxos.Decided {
			// decided but not execute yet
			decidedOp = v.(Op)
			DPrintf("kvpaxos %d catches up with index %d!\n", kv.me, kv.firstUnchosenIndex)
		}
		kv.execute(decidedOp, kv.firstUnchosenIndex)
		kv.firstUnchosenIndex++
		if decidedOp == op {
			kv.px.Done(kv.firstUnchosenIndex - 1)
			return
		}
	}
}

func (kv *KVPaxos) Get(args *GetArgs, reply *GetReply) error {
	// Your code here.
	kv.mu.Lock()
	defer kv.mu.Unlock()
	_, ok := kv.delivered[args.Id]
	if ok {
		// already delivered
		DPrintf("[WARN](key: %s) %d: already delivered!\n", args.Key, args.Id)
		return nil
	} else {
		op := Op{Key: args.Key, T: getOp, Id: args.Id}
		kv.fillHole(op)
		value, ok := kv.data[args.Key]
		// DPrintf("[GET]kvpaxos %d's value for key %s: %s\n", kv.me, op.Key, value)
		if !ok {
			reply.Err = ErrNoKey
		} else {
			reply.Err = OK
			reply.Value = value
		}
		DPrintf("[GET]kvpeer %c reply (key: %s) %d: %s %s\n", kv.name, args.Key, args.Id, reply.Err, reply.Value)
	}
	return nil
}

func (kv *KVPaxos) PutAppend(args *PutAppendArgs, reply *PutAppendReply) error {
	// Your code here.
	kv.mu.Lock()
	defer kv.mu.Unlock()
	_, ok := kv.delivered[args.Id]
	if ok {
		// already delivered
		return nil
	} else {
		var t opType
		if args.Op == "Put" {
			t = putOp
		} else {
			t = appendOp
		}
		op := Op{Key: args.Key, Value: args.Value, T: t, Id: args.Id}
		kv.fillHole(op)
	}
	return nil
}

// tell the server to shut itself down.
// please do not change these two functions.
func (kv *KVPaxos) kill() {
	DPrintf("Kill(%d): die\n", kv.me)
	atomic.StoreInt32(&kv.dead, 1)
	kv.l.Close()
	kv.px.Kill()
}

// call this to find out if the server is dead.
func (kv *KVPaxos) isdead() bool {
	return atomic.LoadInt32(&kv.dead) != 0
}

// please do not change these two functions.
func (kv *KVPaxos) setunreliable(what bool) {
	if what {
		atomic.StoreInt32(&kv.unreliable, 1)
	} else {
		atomic.StoreInt32(&kv.unreliable, 0)
	}
}

func (kv *KVPaxos) isunreliable() bool {
	return atomic.LoadInt32(&kv.unreliable) != 0
}

//
// servers[] contains the ports of the set of
// servers that will cooperate via Paxos to
// form the fault-tolerant key/value service.
// me is the index of the current server in servers[].
//
func StartServer(servers []string, me int) *KVPaxos {
	// call gob.Register on structures you want
	// Go's RPC library to marshall/unmarshall.
	gob.Register(Op{})

	kv := new(KVPaxos)
	kv.me = me

	// Your initialization code here.
	kv.data = make(map[string]string)
	kv.delivered = make(map[int64]bool)
	kv.firstUnchosenIndex = 0
	kv.name = servers[me][len(servers[me])-1]

	rpcs := rpc.NewServer()
	rpcs.Register(kv)

	kv.px = paxos.Make(servers, me, rpcs)

	os.Remove(servers[me])
	l, e := net.Listen("unix", servers[me])
	if e != nil {
		log.Fatal("listen error: ", e)
	}
	kv.l = l

	// please do not change any of the following code,
	// or do anything to subvert it.

	go func() {
		for kv.isdead() == false {
			conn, err := kv.l.Accept()
			if err == nil && kv.isdead() == false {
				if kv.isunreliable() && (rand.Int63()%1000) < 100 {
					// discard the request.
					conn.Close()
				} else if kv.isunreliable() && (rand.Int63()%1000) < 200 {
					// process the request but force discard of reply.
					c1 := conn.(*net.UnixConn)
					f, _ := c1.File()
					err := syscall.Shutdown(int(f.Fd()), syscall.SHUT_WR)
					if err != nil {
						fmt.Printf("shutdown: %v\n", err)
					}
					go rpcs.ServeConn(conn)
				} else {
					go rpcs.ServeConn(conn)
				}
			} else if err == nil {
				conn.Close()
			}
			if err != nil && kv.isdead() == false {
				fmt.Printf("KVPaxos(%v) accept: %v\n", me, err.Error())
				kv.kill()
			}
		}
	}()

	return kv
}
