package paxos

import (
	"strings"
	"strconv"
	"fmt"
)

type ProposalNumber = string

const firstValidRound = 1
const UintSize = 32 << (^uint(0) >> 32 & 1)
const MaxInt = 1<<(UintSize-1) - 1

var Infty ProposalNumber = fmt.Sprintf("%d,%d", MaxInt, -1)

func printProposal(n ProposalNumber) string {
	components := strings.Split(n, ",")
	return fmt.Sprintf("(%s, %s)", components[0], components[1])
}

func smallestProposal() ProposalNumber {
	return fmt.Sprintf("%d, %d", firstValidRound-1, 0)
}

func (px *Paxos) nextProposalNumber(index int) ProposalNumber {
	px.instances[index].max_round_seen += 1
	return fmt.Sprintf("%d,%d", px.instances[index].max_round_seen, px.me)
}

func (px *Paxos) setDecided(index int) {
	px.instances[index].acceptedProposal = Infty
}

func (px *Paxos) isDecided(index int) bool {
	return px.instances[index].acceptedProposal == Infty
}

// to order two proposalNumber, hide the comparison details
func le(pn1 ProposalNumber, pn2 ProposalNumber) bool {
	return less(pn1, pn2) || pn1 == pn2
}

func less(pn1 ProposalNumber, pn2 ProposalNumber) bool {
	components := strings.Split(pn1, ",")
	round1, _ := strconv.Atoi(components[0])
	id1, _ := strconv.Atoi(components[1])
	components = strings.Split(pn2, ",")
	round2, _ := strconv.Atoi(components[0])
	id2, _ := strconv.Atoi(components[1])
	
	return ( round1 < round2) || (round1 == round2 && id1 < id2)
}

func (px *Paxos) updateMaxRound(index int, n ProposalNumber) {
	round, _ := strconv.Atoi(strings.Split(n, ",")[0])
	px.instances[index].max_round_seen = Max(px.instances[index].max_round_seen, round)
}

