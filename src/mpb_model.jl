using MathProgBase

using NLPModels, SparseArrays
import NLPModels.increment!
import MathProgBase.SolverInterface

export MathProgNLPModel

mutable struct ModelReader <: MathProgBase.AbstractMathProgSolver
end

mutable struct MathProgModel <: MathProgBase.AbstractMathProgModel
  eval :: Union{MathProgBase.AbstractNLPEvaluator, Nothing}
  numVar :: Int
  numConstr :: Int
  x :: Vector{Float64}
  y :: Vector{Float64}
  lvar :: Vector{Float64}
  uvar :: Vector{Float64}
  lcon :: Vector{Float64}
  ucon :: Vector{Float64}
  sense :: Symbol
  status :: Symbol
end

MathProgBase.NonlinearModel(solver :: ModelReader) = MathProgModel(nothing,
                                                                   0,
                                                                   0,
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   :Min,
                                                                   :Uninitialized)

function MathProgBase.loadproblem!(m :: MathProgModel,
                                   numVar, numConstr,
                                   l, u, lb, ub,
                                   sense,
                                   eval :: MathProgBase.AbstractNLPEvaluator)

  # TODO: :JacVec is not yet available.
  # [:Grad, :Jac, :JacVec, :Hess, :HessVec, :ExprGraph]
  MathProgBase.initialize(eval, [:Grad, :Jac, :Hess, :HessVec, :ExprGraph])
  m.numVar = numVar
  m.numConstr = numConstr
  m.x = zeros(numVar)
  m.y = zeros(numConstr)
  m.eval = eval
  m.lvar = l
  m.uvar = u
  m.lcon = lb
  m.ucon = ub
  m.sense = sense
end

MathProgBase.setwarmstart!(m :: MathProgModel, x) = (m.x = x)
MathProgBase.status(m :: MathProgModel) = m.status
MathProgBase.getsolution(m :: MathProgModel) = m.x
MathProgBase.getobjval(m :: MathProgModel) = MathProgBase.eval_f(m.eval, m.x)

mutable struct MathProgNLPModel <: AbstractNLPModel
  meta :: NLPModelMeta
  mpmodel :: MathProgModel
  counters :: Counters      # Evaluation counters.

  jrows :: Vector{Int}      # Jacobian sparsity pattern.
  jcols :: Vector{Int}
  jvals :: Vector{Float64}  # Room for the constraints Jacobian.

  hrows :: Vector{Int}      # Hessian sparsity pattern.
  hcols :: Vector{Int}
  hvals :: Vector{Float64}  # Room for the Lagrangian Hessian.
end

"""
    MathProgNLPModel(model, name="Generic")

Construct a `MathProgNLPModel` from a `MathProgModel`.
"""
function MathProgNLPModel(mpmodel :: MathProgModel; name :: String="Generic")

  nvar = mpmodel.numVar
  lvar = mpmodel.lvar
  uvar = mpmodel.uvar

  nlin = length(mpmodel.eval.m.linconstr)         # Number of linear constraints.
  nquad = length(mpmodel.eval.m.quadconstr)       # Number of quadratic constraints.
  nnln = length(mpmodel.eval.m.nlpdata.nlconstr)  # Number of nonlinear constraints.
  ncon = mpmodel.numConstr                        # Total number of constraints.
  lcon = mpmodel.lcon
  ucon = mpmodel.ucon

  jrows, jcols = MathProgBase.jac_structure(mpmodel.eval)
  hrows, hcols = MathProgBase.hesslag_structure(mpmodel.eval)
  nnzj = length(jrows)
  nnzh = length(hrows)

  meta = NLPModelMeta(nvar,
                      x0=mpmodel.x,
                      lvar=lvar,
                      uvar=uvar,
                      ncon=ncon,
                      y0=zeros(ncon),
                      lcon=lcon,
                      ucon=ucon,
                      nnzj=nnzj,
                      nnzh=nnzh,
                      lin=collect(1:nlin),  # linear constraints appear first in MPB
                      nln=collect(nlin+1:ncon),
                      minimize=(mpmodel.sense == :Min),
                      islp=MathProgBase.isobjlinear(mpmodel.eval) & (nlin == ncon),
                      name=name,
                      )

  return MathProgNLPModel(meta,
                      mpmodel,
                      Counters(),
                      jrows,
                      jcols,
                      zeros(nnzj),  # jvals
                      hrows,
                      hcols,
                      zeros(nnzh),  # hvals
                      )
end

import Base.show
show(nlp :: MathProgNLPModel) = show(nlp.mpmodel)

function NLPModels.obj(nlp :: MathProgNLPModel, x :: AbstractVector)
  increment!(nlp, :neval_obj)
  return MathProgBase.eval_f(nlp.mpmodel.eval, x)
end

function NLPModels.grad(nlp :: MathProgNLPModel, x :: AbstractVector)
  g = zeros(nlp.meta.nvar)
  return grad!(nlp, x, g)
end

function NLPModels.grad!(nlp :: MathProgNLPModel, x :: AbstractVector, g :: AbstractVector)
  increment!(nlp, :neval_grad)
  MathProgBase.eval_grad_f(nlp.mpmodel.eval, g, x)
  return g
end

function NLPModels.cons(nlp :: MathProgNLPModel, x :: AbstractVector)
  c = zeros(nlp.meta.ncon)
  return cons!(nlp, x, c)
end

function NLPModels.cons!(nlp :: MathProgNLPModel, x :: AbstractVector, c :: AbstractVector)
  increment!(nlp, :neval_cons)
  MathProgBase.eval_g(nlp.mpmodel.eval, c, x)
  return c
end

function NLPModels.jac_structure!(nlp :: MathProgNLPModel, rows :: AbstractVector{<: Integer}, cols :: AbstractVector{<: Integer})
  rows[1:nlp.meta.nnzj] .= nlp.jrows
  cols[1:nlp.meta.nnzj] .= nlp.jcols
  return (nlp.jrows, nlp.jcols)
end

function NLPModels.jac_structure(nlp :: MathProgNLPModel)
  return (nlp.jrows, nlp.jcols)
end

function NLPModels.jac_coord!(nlp :: MathProgNLPModel, x :: AbstractVector, rows :: AbstractVector{Int}, cols :: AbstractVector{Int}, vals :: AbstractVector)
  increment!(nlp, :neval_jac)
  MathProgBase.eval_jac_g(nlp.mpmodel.eval, vals, x)
  return (rows, cols, vals)
end

function NLPModels.jac_coord(nlp :: MathProgNLPModel, x :: AbstractVector)
  increment!(nlp, :neval_jac)
  MathProgBase.eval_jac_g(nlp.mpmodel.eval, nlp.jvals, x)
  return (nlp.jrows, nlp.jcols, nlp.jvals)
end

function NLPModels.jac(nlp :: MathProgNLPModel, x :: AbstractVector)
  return sparse(jac_coord(nlp, x)..., nlp.meta.ncon, nlp.meta.nvar)
end

function NLPModels.jprod(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector)
  Jv = zeros(nlp.meta.ncon)
  return jprod!(nlp, x, v, Jv)
end

function NLPModels.jprod!(nlp :: MathProgNLPModel,
                x :: AbstractVector,
                v :: AbstractVector,
                Jv :: AbstractVector)
  nlp.counters.neval_jac -= 1
  increment!(nlp, :neval_jprod)
  Jv .= jac(nlp, x) * v
  return Jv
end

function NLPModels.jtprod(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector)
  Jtv = zeros(nlp.meta.nvar)
  return jtprod!(nlp, x, v, Jtv)
end

function NLPModels.jtprod!(nlp :: MathProgNLPModel,
                x :: AbstractVector,
                v :: AbstractVector,
                Jtv :: AbstractVector)
  nlp.counters.neval_jac -= 1
  increment!(nlp, :neval_jtprod)
  Jtv[1:nlp.meta.nvar] = jac(nlp, x)' * v
  return Jtv
end

# Uncomment if/when :JacVec becomes available in MPB.
# "Evaluate the Jacobian-vector product at `x`."
# function NLPModels.jprod(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector)
#   jv = zeros(nlp.meta.ncon)
#   return jprod!(nlp, x, v, jv)
# end
#
# "Evaluate the Jacobian-vector product at `x` in place."
# function NLPModels.jprod!(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector, jv
# :: AbstractVector)
#   increment!(nlp, :neval_jprod)
#   MathProgBase.eval_jac_prod(nlp.mpmodel.eval, jv, x, v)
#   return jv
# end
#
# "Evaluate the transposed-Jacobian-vector product at `x`."
# function NLPModels.jtprod(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector)
#   jtv = zeros(nlp.meta.nvar)
#   return jtprod!(nlp, x, v, jtv)
# end
#
# "Evaluate the transposed-Jacobian-vector product at `x` in place."
# function NLPModels.jtprod!(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector,
# jtv :: AbstractVector)
#   increment!(nlp, :neval_jtprod)
#   MathProgBase.eval_jac_prod_t(nlp.mpmodel.eval, jtv, x, v)
#   return jtv
# end

function NLPModels.hess_structure!(nlp :: MathProgNLPModel, rows :: AbstractVector{<: Integer}, cols :: AbstractVector{<: Integer})
  rows[1:nlp.meta.nnzh] .= nlp.hrows
  cols[1:nlp.meta.nnzh] .= nlp.hcols
  return (nlp.hrows, nlp.hcols)
end

function NLPModels.hess_structure(nlp :: MathProgNLPModel)
  return (nlp.hrows, nlp.hcols)
end

function NLPModels.hess_coord!(nlp :: MathProgNLPModel, x :: AbstractVector, rows :: AbstractVector{Int}, cols :: AbstractVector{Int}, vals :: AbstractVector;
    obj_weight :: Float64=1.0, y :: AbstractVector=zeros(nlp.meta.ncon))
  increment!(nlp, :neval_hess)
  MathProgBase.eval_hesslag(nlp.mpmodel.eval, vals, x, obj_weight, y)
  return (rows, cols, vals)
end

function NLPModels.hess_coord(nlp :: MathProgNLPModel, x :: AbstractVector;
    obj_weight :: Float64=1.0, y :: AbstractVector=zeros(nlp.meta.ncon))
  increment!(nlp, :neval_hess)
  MathProgBase.eval_hesslag(nlp.mpmodel.eval, nlp.hvals, x, obj_weight, y)
  return (nlp.hrows, nlp.hcols, nlp.hvals)
end

function NLPModels.hess(nlp :: MathProgNLPModel, x :: AbstractVector;
    obj_weight :: Float64=1.0, y :: AbstractVector=zeros(nlp.meta.ncon))
  return sparse(hess_coord(nlp, x, y=y, obj_weight=obj_weight)..., nlp.meta.nvar, nlp.meta.nvar)
end

function NLPModels.hprod(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector;
    obj_weight :: Float64=1.0, y :: AbstractVector=zeros(nlp.meta.ncon))
  hv = zeros(nlp.meta.nvar)
  return hprod!(nlp, x, v, hv, obj_weight=obj_weight, y=y)
end

function NLPModels.hprod!(nlp :: MathProgNLPModel, x :: AbstractVector, v :: AbstractVector,
    hv :: AbstractVector;
    obj_weight :: Float64=1.0, y :: AbstractVector=zeros(nlp.meta.ncon))
  increment!(nlp, :neval_hprod)
  MathProgBase.eval_hesslag_prod(nlp.mpmodel.eval, hv, x, v, obj_weight, y)
  return hv
end
