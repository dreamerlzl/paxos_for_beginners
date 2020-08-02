defmodule ProposalNumber do
  defstruct round: 0, id: 0

  @type t(r, i) :: %ProposalNumber{round: r, id: i}
  @type t :: %ProposalNumber{round: integer | atom, id: integer}

  @spec less?(ProposalNumber.t(), ProposalNumber.t()) :: boolean # true | false
  def less?(pn1, pn2) do
    pn1.round < pn2.round || (pn1.round == pn2.round && pn1.id < pn2.id)
  end

  @spec eq?(ProposalNumber.t(), ProposalNumber.t()) :: boolean
  def eq?(pn1, pn2) do
    pn1.round == pn2.round && pn1.id == pn2.id
  end

  @spec leq?(ProposalNumber.t(), ProposalNumber.t()) :: boolean
  def leq?(pn1, pn2) do
    eq?(pn1, pn2) || less?(pn1, pn2)
  end

  @spec select_larger(ProposalNumber.t(), ProposalNumber.t()) :: ProposalNumber.t()
  def select_larger(pn1, pn2) do
    if leq?(pn1, pn2) do
      pn2
    else
      pn1
    end
  end

  #  utilize the fact that number < atom
  def infty do
    %ProposalNumber{round: :infty, id: 0}
  end

  def smallest do
    %ProposalNumber{round: 0, id: 0}
  end

  # @spec next_proposal(PaxosState, integer) :: ProposalNumber
  def next_proposal(max_round, id) do
    %ProposalNumber{round: max_round + 1, id: id}
  end

end
