#
#
#           The Nimrod Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import
  intsets, ast, astalgo, msgs, renderer, magicsys, types, idents, trees, 
  wordrecg

# Second semantic checking pass over the AST. Necessary because the old
# way had some inherent problems. Performs:
# 
# * procvar checks
# * effect+exception tracking
# * closure analysis
# * checks for invalid usages of compiletime magics (not implemented)
# * checks for invalid usages of PNimNode (not implemented)
# * later: will do an escape analysis for closures at least

# Predefined effects:
#   io, time (time dependent), gc (performs GC'ed allocation), exceptions,
#   side effect (accesses global), store (stores into *type*),
#   store_unkown (performs some store) --> store(any)|store(x) 
#   load (loads from *type*), recursive (recursive call),
#   endless (has endless loops), --> user effects are defined over *patterns*
#   --> a TR macro can annotate the proc with user defined annotations
#   --> the effect system can access these

# Load&Store analysis is performed on *paths*. A path is an access like
# obj.x.y[i].z; splitting paths up causes some problems:
# 
# var x = obj.x
# var z = x.y[i].z
#
# Alias analysis is affected by this too! A good solution is *type splitting*:
# T becomes T1 and T2 if it's known that T1 and T2 can't alias. 
# 
# An aliasing problem and a race condition are effectively the same problem.
# Type based alias analysis is nice but not sufficient; especially splitting
# an array and filling it in parallel should be supported but is not easily
# done: It essentially requires a built-in 'indexSplit' operation and dependent
# typing.

when false:
  proc sem2call(c: PContext, n: PNode): PNode =
    assert n.kind in nkCallKinds
    
  proc sem2sym(c: PContext, n: PNode): PNode =
    assert n.kind == nkSym
  
  
# ------------------------ exception tracking -------------------------------

discard """
  exception tracking:
  
  a() # raises 'x', 'e'
  try:
    b() # raises 'e'
  except e:
    # must not undo 'e' here; hrm
    c()
 
 --> we need a stack of scopes for this analysis
 
 
  Effect tracking:
  
  We track the effects per proc; forward declarations and indirect calls cause
  problems: Forward declarations are computed lazily (we do this pass after
  a whole module) and indirect calls are assumed the worst, unless they have
  an effect annotation.
"""

type
  TEffects = object
    exc: PNode  # stack of exceptions
    bottom: int
  
  PEffects = var TEffects

proc throws(tracked: PEffects, n: PNode) =
  # since a 'raise' statement occurs rarely and we need distinct reasons;
  # we simply do not merge anything here, this would be problematic for the
  # stack of exceptions anyway:
  tracked.exc.add n
  
proc excType(n: PNode): PType =
  assert n.kind == nkRaiseStmt
  # reraise is like raising E_Base:
  let t = if n.sons[0].kind == nkEmpty: sysTypeFromName"E_Base"
          else: n.sons[0].typ
  result = skipTypes(t, skipPtrs)

proc addEffect(a: PEffects, e: PNode, useLineInfo=true) =
  assert e.kind == nkRaiseStmt
  var aa = a.exc
  for i in a.bottom .. <aa.len:
    if sameType(aa[i].excType, e.excType):
      if not useLineInfo: return
      elif aa[i].info == e.info: return
  throws(a, e)

proc mergeEffects(a: PEffects, b: PNode, useLineInfo) =
  for effect in items(b): addEffect(a, effect, useLineInfo)

proc listEffects(a: PEffects) =
  var aa = a.exc
  for e in items(aa):
    Message(e.info, hintUser, renderTree(e))

proc catches(tracked: PEffects, e: PType) =
  let e = skipTypes(e, skipPtrs)
  var L = tracked.exc.len
  var i = tracked.bottom
  while i < L:
    # r supertype of e?
    if inheritanceDiff(tracked.exc[i].excType, e) <= 0:
      tracked.exc.sons[i] = tracked.exc.sons[L-1]
      dec L
    else:
      inc i
  setLen(tracked.exc.sons, L)
  
proc catchesAll(tracked: PEffects) =
  setLen(tracked.exc.sons, tracked.bottom)

proc track(tracked: PEffects, n: PNode)
proc trackTryStmt(tracked: PEffects, n: PNode) =
  let oldBottom = tracked.bottom
  tracked.bottom = tracked.exc.len
  track(tracked, n.sons[0])
  for i in 1 .. < n.len:
    let b = n.sons[i]
    let blen = sonsLen(b)
    if b.kind == nkExceptBranch:
      if blen == 1:
        catchesAll(tracked)
      else:
        for j in countup(0, blen - 2):
          assert(b.sons[j].kind == nkType)
          catches(tracked, b.sons[j].typ)
    else:
      assert b.kind == nkFinally
    track(tracked, b.sons[blen-1])
  tracked.bottom = oldBottom

proc isIndirectCall(n: PNode): bool =
  result = n.kind != nkSym or n.sym.kind notin routineKinds

proc isForwardedProc(n: PNode): bool =
  result = n.kind == nkSym and sfForward in n.sym.flags

proc trackPragmaStmt(tracked: PEffects, n: PNode) = 
  for i in countup(0, sonsLen(n) - 1): 
    var it = n.sons[i]
    if whichPragma(it) == wEffects:
      # list the computed effects up to here:
      listEffects(tracked)

proc raisesSpec(n: PNode): PNode =
  for i in countup(0, sonsLen(n) - 1):
    var it = n.sons[i]
    if it.kind == nkExprColonExpr and whichPragma(it) == wRaises:
      result = it.sons[1]
      if result.kind notin {nkCurly, nkBracket}:
        result = newNodeI(nkCurly, result.info)
        result.add(it.sons[1])
      return

proc createRaise(n: PNode, t: PType): PNode =
  result = newNodeI(nkRaiseStmt, n.info)
  result.add(newNodeIT(nkType, n.info, t))

proc track(tracked: PEffects, n: PNode) =
  case n.kind
  of nkRaiseStmt: throws(tracked, n)
  of nkCallKinds:
    # p's effects are ours too:
    let op = n.sons[0].typ
    if op != nil and op.kind == tyProc:
      InternalAssert op.n.sons[0].kind == nkEffectList
      var effectList = op.n.sons[0]
      if effectList.len == 0:
        if isForwardedProc(n.sons[0]):
          let spec = raisesSpec(n.sons[0].sym.ast.sons[pragmasPos])
          if not isNil(spec):
            mergeEffects(tracked, spec, useLineInfo=false)
          else:
            addEffect(tracked, createRaise(n, sysTypeFromName"E_Base"))
        elif isIndirectCall(n.sons[0]):
          addEffect(tracked, createRaise(n, sysTypeFromName"E_Base"))
      else:
        effectList = effectList.sons[exceptionEffects]
        mergeEffects(tracked, effectList, useLineInfo=true)
  of nkTryStmt:
    trackTryStmt(tracked, n)
    return
  of nkPragma:
    trackPragmaStmt(tracked, n)
    return
  of nkMacroDef, nkTemplateDef: return
  else: nil
  for i in 0 .. <safeLen(n):
    track(tracked, n.sons[i])

# XXX
# - make use of 'raises' in proc types compatibility
# - check for 'raises' consistency for multi-methods

proc checkRaisesSpec(spec, real: PNode) =
  # check that any real exception is listed in 'spec'; mark those as used;
  # report any unused exception
  var used = initIntSet()
  for r in items(real):
    block search:
      for s in 0 .. <spec.len:
        if inheritanceDiff(r.excType, spec[s].typ) <= 0:
          used.incl(s)
          break search
      # XXX call graph analysis would be nice here!
      localError(r.info, errGenerated, "can raise an unlisted exception: " &
        typeToString(r.sons[0].typ))
  # hint about unnecessarily listed exception types:
  for s in 0 .. <spec.len:
    if not used.contains(s):
      Message(spec[s].info, hintXDeclaredButNotUsed, renderTree(spec[s]))

proc compatibleEffects*(formal, actual: PType): bool =
  # for proc type compatibility checking:
  assert formal.kind == tyProc and actual.kind == tyProc
  InternalAssert formal.n.sons[0].kind == nkEffectList
  InternalAssert actual.n.sons[0].kind == nkEffectList
  
  var effectList = formal.n.sons[0]
  if effectList.len == 0:
    # 'formal' has no restrictions :-)
    result = true

proc trackProc*(s: PSym, body: PNode) =
  var effects = s.typ.n.sons[0]
  InternalAssert effects.kind == nkEffectList
  # effects already computed?
  if sfForward in s.flags: return
  if effects.len == effectListLen: return
  newSeq(effects.sons, effectListLen)
  effects.sons[exceptionEffects] = newNodeI(nkArgList, body.info)
  
  var t: TEffects
  t.exc = effects.sons[exceptionEffects]
  track(t, body)
  
  let spec = raisesSpec(s.ast.sons[pragmasPos])
  if not isNil(spec):
    checkRaisesSpec(spec, t.exc)
