#
#
#           The Nimrod Compiler
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# included from cgen.nim

const
  RangeExpandLimit = 256      # do not generate ranges
                              # over 'RangeExpandLimit' elements
  stringCaseThreshold = 8
    # above X strings a hash-switch for strings is generated

proc registerGcRoot(p: BProc, v: PSym) =
  if gSelectedGc in {gcMarkAndSweep, gcGenerational} and
      containsGarbageCollectedRef(v.loc.t):
    # we register a specialized marked proc here; this has the advantage
    # that it works out of the box for thread local storage then :-)
    let prc = genTraverseProcForGlobal(p.module, v)
    linefmt(p.module.initProc, cpsStmts,
      "#nimRegisterGlobalMarker($1);$n", prc)

proc genVarTuple(p: BProc, n: PNode) = 
  var tup, field: TLoc
  if n.kind != nkVarTuple: InternalError(n.info, "genVarTuple")
  var L = sonsLen(n)
  genLineDir(p, n)
  initLocExpr(p, n.sons[L-1], tup)
  var t = tup.t
  for i in countup(0, L-3): 
    var v = n.sons[i].sym
    if sfCompileTime in v.flags: continue
    if sfGlobal in v.flags:
      assignGlobalVar(p, v)
      genObjectInit(p, cpsInit, v.typ, v.loc, true)
      registerGcRoot(p, v)
    else:
      assignLocalVar(p, v)
      initLocalVar(p, v, immediateAsgn=true)
    initLoc(field, locExpr, t.sons[i], tup.s)
    if t.kind == tyTuple: 
      field.r = ropef("$1.Field$2", [rdLoc(tup), toRope(i)])
    else: 
      if t.n.sons[i].kind != nkSym: InternalError(n.info, "genVarTuple")
      field.r = ropef("$1.$2", 
                      [rdLoc(tup), mangleRecFieldName(t.n.sons[i].sym, t)])
    putLocIntoDest(p, v.loc, field)

proc loadInto(p: BProc, le, ri: PNode, a: var TLoc) {.inline.} =
  if ri.kind in nkCallKinds and (ri.sons[0].kind != nkSym or
                                 ri.sons[0].sym.magic == mNone):
    genAsgnCall(p, le, ri, a)
  else:
    expr(p, ri, a)

proc startBlock(p: BProc, start: TFormatStr = "{$n",
                args: varargs[PRope]): int {.discardable.} =
  lineCg(p, cpsStmts, start, args)
  inc(p.labels)
  result = len(p.blocks)
  setlen(p.blocks, result + 1)
  p.blocks[result].id = p.labels
  p.blocks[result].nestedTryStmts = p.nestedTryStmts.len.int16

proc assignLabel(b: var TBlock): PRope {.inline.} =
  b.label = con("LA", b.id.toRope)
  result = b.label

proc blockBody(b: var TBlock): PRope =
  result = b.sections[cpsLocals]
  if b.frameLen > 0:
    result.appf("F.len+=$1;$n", b.frameLen.toRope)
  result.app(b.sections[cpsInit])
  result.app(b.sections[cpsStmts])

proc endBlock(p: BProc, blockEnd: PRope) =
  let topBlock = p.blocks.len-1
  # the block is merged into the parent block
  app(p.blocks[topBlock-1].sections[cpsStmts], p.blocks[topBlock].blockBody)
  setlen(p.blocks, topBlock)
  # this is done after the block is popped so $n is
  # properly indented when pretty printing is enabled
  line(p, cpsStmts, blockEnd)

proc endBlock(p: BProc) =
  let topBlock = p.blocks.len - 1  
  var blockEnd = if p.blocks[topBlock].label != nil:
      rfmt(nil, "} $1: ;$n", p.blocks[topBlock].label)
    else:
      ~"}$n"
  let frameLen = p.blocks[topBlock].frameLen
  if frameLen > 0:
    blockEnd.appf("F.len-=$1;$n", frameLen.toRope)
  endBlock(p, blockEnd)

proc genSimpleBlock(p: BProc, stmts: PNode) {.inline.} =
  startBlock(p)
  genStmts(p, stmts)
  endBlock(p)

proc exprBlock(p: BProc, n: PNode, d: var TLoc) =
  startBlock(p)
  expr(p, n, d)
  endBlock(p)

template preserveBreakIdx(body: stmt): stmt {.immediate.} =
  var oldBreakIdx = p.breakIdx
  body
  p.breakIdx = oldBreakIdx

proc genState(p: BProc, n: PNode) =
  internalAssert n.len == 1 and n.sons[0].kind == nkIntLit
  let idx = n.sons[0].intVal
  linefmt(p, cpsStmts, "STATE$1: ;$n", idx.toRope)

proc genGotoState(p: BProc, n: PNode) =
  # we resist the temptation to translate it into duff's device as it later
  # will be translated into computed gotos anyway for GCC at least:
  # switch (x.state) {
  #   case 0: goto STATE0;
  # ...
  var a: TLoc
  initLocExpr(p, n.sons[0], a)
  lineF(p, cpsStmts, "switch ($1) {$n", [rdLoc(a)])
  p.BeforeRetNeeded = true
  lineF(p, cpsStmts, "case -1: goto BeforeRet;$n", [])
  for i in 0 .. lastOrd(n.sons[0].typ):
    lineF(p, cpsStmts, "case $1: goto STATE$1;$n", [toRope(i)])
  lineF(p, cpsStmts, "}$n", [])

proc genBreakState(p: BProc, n: PNode) =
  var a: TLoc
  if n.sons[0].kind == nkClosure:
    # XXX this produces quite inefficient code!
    initLocExpr(p, n.sons[0].sons[1], a)
    lineF(p, cpsStmts, "if (($1->Field0) < 0) break;$n", [rdLoc(a)])
  else:
    initLocExpr(p, n.sons[0], a)
    # the environment is guaranteed to contain the 'state' field at offset 0:
    lineF(p, cpsStmts, "if ((((NI*) $1.ClEnv)[0]) < 0) break;$n", [rdLoc(a)])
  #  lineF(p, cpsStmts, "if (($1) < 0) break;$n", [rdLoc(a)])

proc genVarPrototypeAux(m: BModule, sym: PSym)
proc genSingleVar(p: BProc, a: PNode) =
  var v = a.sons[0].sym
  if sfCompileTime in v.flags: return
  var targetProc = p
  var immediateAsgn = a.sons[2].kind != nkEmpty
  if sfGlobal in v.flags:
    if v.owner.kind != skModule:
      targetProc = p.module.preInitProc
    assignGlobalVar(targetProc, v)
    # XXX: be careful here.
    # Global variables should not be zeromem-ed within loops 
    # (see bug #20).
    # That's why we are doing the construction inside the preInitProc.
    # genObjectInit relies on the C runtime's guarantees that 
    # global variables will be initialized to zero.
    genObjectInit(p.module.preInitProc, cpsInit, v.typ, v.loc, true)
    # Alternative construction using default constructor (which may zeromem):
    # if sfImportc notin v.flags: constructLoc(p.module.preInitProc, v.loc)
    if sfExportc in v.flags and generatedHeader != nil:
      genVarPrototypeAux(generatedHeader, v)
    registerGcRoot(p, v)
  else:
    assignLocalVar(p, v)
    initLocalVar(p, v, immediateAsgn)

  if immediateAsgn:
    genLineDir(targetProc, a)
    loadInto(targetProc, a.sons[0], a.sons[2], v.loc)

proc genClosureVar(p: BProc, a: PNode) =
  var immediateAsgn = a.sons[2].kind != nkEmpty
  if immediateAsgn:
    var v: TLoc
    initLocExpr(p, a.sons[0], v)
    genLineDir(p, a)
    loadInto(p, a.sons[0], a.sons[2], v)

proc genVarStmt(p: BProc, n: PNode) = 
  for i in countup(0, sonsLen(n) - 1): 
    var a = n.sons[i]
    if a.kind == nkCommentStmt: continue 
    if a.kind == nkIdentDefs:
      # can be a lifted var nowadays ...
      if a.sons[0].kind == nkSym:
        genSingleVar(p, a)
      else:
        genClosureVar(p, a)
    else:
      genVarTuple(p, a)

proc genConstStmt(p: BProc, t: PNode) = 
  for i in countup(0, sonsLen(t) - 1): 
    var it = t.sons[i]
    if it.kind == nkCommentStmt: continue 
    if it.kind != nkConstDef: InternalError(t.info, "genConstStmt")
    var c = it.sons[0].sym 
    if c.typ.containsCompileTimeOnly: continue
    if sfFakeConst in c.flags:
      genSingleVar(p, it)
    elif c.typ.kind in ConstantDataTypes and lfNoDecl notin c.loc.flags and
        c.ast.len != 0:
      if not emitLazily(c): requestConstImpl(p, c)
      when false:
        # generate the data:
        fillLoc(c.loc, locData, c.typ, mangleName(c), OnUnknown)
        if sfImportc in c.flags: 
          appf(p.module.s[cfsData], "extern NIM_CONST $1 $2;$n", 
               [getTypeDesc(p.module, c.typ), c.loc.r])
        else: 
          appf(p.module.s[cfsData], "NIM_CONST $1 $2 = $3;$n", 
               [getTypeDesc(p.module, c.typ), c.loc.r, genConstExpr(p, c.ast)])
    
proc genIf(p: BProc, n: PNode, d: var TLoc) =
  #
  #  { if (!expr1) goto L1;
  #   thenPart }
  #  goto LEnd
  #  L1:
  #  { if (!expr2) goto L2;
  #   thenPart2 }
  #  goto LEnd
  #  L2:
  #  { elsePart }
  #  Lend:
  var
    a: TLoc
    Lelse: TLabel
  if not isEmptyType(n.typ) and d.k == locNone:
    getTemp(p, n.typ, d)
  genLineDir(p, n)
  let Lend = getLabel(p)
  for i in countup(0, sonsLen(n) - 1): 
    let it = n.sons[i]
    if it.len == 2: 
      when newScopeForIf: startBlock(p)
      initLocExpr(p, it.sons[0], a)
      Lelse = getLabel(p)
      inc(p.labels)
      lineFF(p, cpsStmts, "if (!$1) goto $2;$n",
            "br i1 $1, label %LOC$3, label %$2$nLOC$3: $n",
            [rdLoc(a), Lelse, toRope(p.labels)])
      when not newScopeForIf: startBlock(p)
      expr(p, it.sons[1], d)
      endBlock(p)
      if sonsLen(n) > 1:
        lineFF(p, cpsStmts, "goto $1;$n", "br label %$1$n", [Lend])
      fixLabel(p, Lelse)
    elif it.len == 1:
      startBlock(p)
      expr(p, it.sons[0], d)
      endBlock(p)
    else: internalError(n.info, "genIf()")
  if sonsLen(n) > 1: fixLabel(p, Lend)

proc blockLeaveActions(p: BProc, howMany: int) = 
  var L = p.nestedTryStmts.len
  # danger of endless recursion! we workaround this here by a temp stack
  var stack: seq[PNode]
  newSeq(stack, howMany)
  for i in countup(1, howMany): 
    stack[i-1] = p.nestedTryStmts[L-i]
  setLen(p.nestedTryStmts, L-howMany)
  
  var alreadyPoppedCnt = p.inExceptBlock
  for tryStmt in items(stack):
    if gCmd != cmdCompileToCpp:
      if alreadyPoppedCnt > 0:
        dec alreadyPoppedCnt
      else:
        linefmt(p, cpsStmts, "#popSafePoint();$n")
    var finallyStmt = lastSon(tryStmt)
    if finallyStmt.kind == nkFinally: 
      genStmts(p, finallyStmt.sons[0])
  # push old elements again:
  for i in countdown(howMany-1, 0): 
    p.nestedTryStmts.add(stack[i])
  if gCmd != cmdCompileToCpp:
    for i in countdown(p.inExceptBlock-1, 0):
      linefmt(p, cpsStmts, "#popCurrentException();$n")

proc genReturnStmt(p: BProc, t: PNode) =
  p.beforeRetNeeded = true
  genLineDir(p, t)
  if (t.sons[0].kind != nkEmpty): genStmts(p, t.sons[0])
  blockLeaveActions(p, min(1, p.nestedTryStmts.len))
  lineFF(p, cpsStmts, "goto BeforeRet;$n", "br label %BeforeRet$n", [])

proc genWhileStmt(p: BProc, t: PNode) =
  # we don't generate labels here as for example GCC would produce
  # significantly worse code
  var 
    a: TLoc
    Labl: TLabel
  assert(sonsLen(t) == 2)
  inc(p.withinLoop)
  genLineDir(p, t)

  preserveBreakIdx:
    p.breakIdx = startBlock(p, "while (1) {$n")
    p.blocks[p.breakIdx].isLoop = true
    initLocExpr(p, t.sons[0], a)
    if (t.sons[0].kind != nkIntLit) or (t.sons[0].intVal == 0): 
      let label = assignLabel(p.blocks[p.breakIdx])
      lineF(p, cpsStmts, "if (!$1) goto $2;$n", [rdLoc(a), label])
    genStmts(p, t.sons[1])

    if optProfiler in p.options:
      # invoke at loop body exit:
      linefmt(p, cpsStmts, "#nimProfile();$n")
    endBlock(p)

  dec(p.withinLoop)

proc genBlock(p: BProc, t: PNode, d: var TLoc) =
  preserveBreakIdx:
    p.breakIdx = startBlock(p)
    if t.sons[0].kind != nkEmpty:
      # named block?
      assert(t.sons[0].kind == nkSym)
      var sym = t.sons[0].sym
      sym.loc.k = locOther
      sym.loc.a = p.breakIdx
    expr(p, t.sons[1], d)
    endBlock(p)

proc genParForStmt(p: BProc, t: PNode) =
  assert(sonsLen(t) == 3)
  inc(p.withinLoop)
  genLineDir(p, t)

  preserveBreakIdx:
    let forLoopVar = t.sons[0].sym
    var rangeA, rangeB: TLoc
    assignLocalVar(P, forLoopVar)
    #initLoc(forLoopVar.loc, locLocalVar, forLoopVar.typ, onStack)
    #discard mangleName(forLoopVar)
    let call = t.sons[1]
    initLocExpr(p, call.sons[1], rangeA)
    initLocExpr(p, call.sons[2], rangeB)
    
    lineF(p, cpsStmts, "#pragma omp parallel for $4$n" &
                        "for ($1 = $2; $1 <= $3; ++$1)", 
                        forLoopVar.loc.rdLoc,
                        rangeA.rdLoc, rangeB.rdLoc,
                        call.sons[3].getStr.toRope)
    
    p.breakIdx = startBlock(p)
    p.blocks[p.breakIdx].isLoop = true
    genStmts(p, t.sons[2])
    endBlock(p)

  dec(p.withinLoop)
  
proc genBreakStmt(p: BProc, t: PNode) = 
  var idx = p.breakIdx
  if t.sons[0].kind != nkEmpty: 
    # named break?
    assert(t.sons[0].kind == nkSym)
    var sym = t.sons[0].sym
    assert(sym.loc.k == locOther)
    idx = sym.loc.a
  else:
    # an unnamed 'break' can only break a loop after 'transf' pass:
    while idx >= 0 and not p.blocks[idx].isLoop: dec idx
    if idx < 0 or not p.blocks[idx].isLoop:
      InternalError(t.info, "no loop to break")
  let label = assignLabel(p.blocks[idx])
  blockLeaveActions(p, p.nestedTryStmts.len - p.blocks[idx].nestedTryStmts)
  genLineDir(p, t)
  lineF(p, cpsStmts, "goto $1;$n", [label])

proc getRaiseFrmt(p: BProc): string = 
  if gCmd == cmdCompileToCpp: 
    result = "throw NimException($1, $2);$n"
  else:
    result = "#raiseException((#E_Base*)$1, $2);$n"

proc genRaiseStmt(p: BProc, t: PNode) =
  if p.inExceptBlock > 0:
    # if the current try stmt have a finally block,
    # we must execute it before reraising
    var finallyBlock = p.nestedTryStmts[p.nestedTryStmts.len - 1].lastSon
    if finallyBlock.kind == nkFinally:
      genSimpleBlock(p, finallyBlock.sons[0])
  if t.sons[0].kind != nkEmpty: 
    var a: TLoc
    InitLocExpr(p, t.sons[0], a)
    var e = rdLoc(a)
    var typ = skipTypes(t.sons[0].typ, abstractPtrs)
    genLineDir(p, t)
    lineCg(p, cpsStmts, getRaiseFrmt(p), [e, makeCString(typ.sym.name.s)])
  else: 
    genLineDir(p, t)
    # reraise the last exception:
    if gCmd == cmdCompileToCpp:
      line(p, cpsStmts, ~"throw;$n")
    else:
      linefmt(p, cpsStmts, "#reraiseException();$n")

proc genCaseGenericBranch(p: BProc, b: PNode, e: TLoc, 
                          rangeFormat, eqFormat: TFormatStr, labl: TLabel) = 
  var 
    x, y: TLoc
  var length = sonsLen(b)
  for i in countup(0, length - 2): 
    if b.sons[i].kind == nkRange: 
      initLocExpr(p, b.sons[i].sons[0], x)
      initLocExpr(p, b.sons[i].sons[1], y)
      lineCg(p, cpsStmts, rangeFormat, 
           [rdCharLoc(e), rdCharLoc(x), rdCharLoc(y), labl])
    else: 
      initLocExpr(p, b.sons[i], x)
      lineCg(p, cpsStmts, eqFormat, [rdCharLoc(e), rdCharLoc(x), labl])

proc genCaseSecondPass(p: BProc, t: PNode, d: var TLoc, 
                       labId, until: int): TLabel = 
  var Lend = getLabel(p)
  for i in 1..until:
    lineF(p, cpsStmts, "LA$1: ;$n", [toRope(labId + i)])
    if t.sons[i].kind == nkOfBranch:
      var length = sonsLen(t.sons[i])
      exprBlock(p, t.sons[i].sons[length - 1], d)
      lineF(p, cpsStmts, "goto $1;$n", [Lend])
    else:
      exprBlock(p, t.sons[i].sons[0], d)
  result = Lend

proc genIfForCaseUntil(p: BProc, t: PNode, d: var TLoc,
                       rangeFormat, eqFormat: TFormatStr,
                       until: int, a: TLoc): TLabel =
  # generate a C-if statement for a Nimrod case statement
  var labId = p.labels
  for i in 1..until:
    inc(p.labels)
    if t.sons[i].kind == nkOfBranch: # else statement
      genCaseGenericBranch(p, t.sons[i], a, rangeFormat, eqFormat,
                           con("LA", toRope(p.labels)))
    else:
      lineF(p, cpsStmts, "goto LA$1;$n", [toRope(p.labels)])
  if until < t.len-1:
    inc(p.labels)
    var gotoTarget = p.labels
    lineF(p, cpsStmts, "goto LA$1;$n", [toRope(gotoTarget)])
    result = genCaseSecondPass(p, t, d, labId, until)
    lineF(p, cpsStmts, "LA$1: ;$n", [toRope(gotoTarget)])
  else:
    result = genCaseSecondPass(p, t, d, labId, until)

proc genCaseGeneric(p: BProc, t: PNode, d: var TLoc, 
                    rangeFormat, eqFormat: TFormatStr) = 
  var a: TLoc
  initLocExpr(p, t.sons[0], a)
  var Lend = genIfForCaseUntil(p, t, d, rangeFormat, eqFormat, sonsLen(t)-1, a)
  fixLabel(p, Lend)

proc genCaseStringBranch(p: BProc, b: PNode, e: TLoc, labl: TLabel, 
                         branches: var openArray[PRope]) = 
  var x: TLoc
  var length = sonsLen(b)
  for i in countup(0, length - 2): 
    assert(b.sons[i].kind != nkRange)
    initLocExpr(p, b.sons[i], x)
    assert(b.sons[i].kind in {nkStrLit..nkTripleStrLit})
    var j = int(hashString(b.sons[i].strVal) and high(branches))
    appcg(p.module, branches[j], "if (#eqStrings($1, $2)) goto $3;$n", 
         [rdLoc(e), rdLoc(x), labl])

proc genStringCase(p: BProc, t: PNode, d: var TLoc) =
  # count how many constant strings there are in the case:
  var strings = 0
  for i in countup(1, sonsLen(t) - 1):
    if t.sons[i].kind == nkOfBranch: inc(strings, sonsLen(t.sons[i]) - 1)
  if strings > stringCaseThreshold:
    var bitMask = math.nextPowerOfTwo(strings) - 1
    var branches: seq[PRope]
    newSeq(branches, bitMask + 1)
    var a: TLoc
    initLocExpr(p, t.sons[0], a) # fist pass: gnerate ifs+goto:
    var labId = p.labels
    for i in countup(1, sonsLen(t) - 1): 
      inc(p.labels)
      if t.sons[i].kind == nkOfBranch: 
        genCaseStringBranch(p, t.sons[i], a, con("LA", toRope(p.labels)), 
                            branches)
      else: 
        # else statement: nothing to do yet
        # but we reserved a label, which we use later
    linefmt(p, cpsStmts, "switch (#hashString($1) & $2) {$n", 
            rdLoc(a), toRope(bitMask))
    for j in countup(0, high(branches)):
      if branches[j] != nil:
        lineF(p, cpsStmts, "case $1: $n$2break;$n", 
             [intLiteral(j), branches[j]])
    lineF(p, cpsStmts, "}$n") # else statement:
    if t.sons[sonsLen(t)-1].kind != nkOfBranch: 
      lineF(p, cpsStmts, "goto LA$1;$n", [toRope(p.labels)]) 
    # third pass: generate statements
    var Lend = genCaseSecondPass(p, t, d, labId, sonsLen(t)-1)
    fixLabel(p, Lend)
  else:
    genCaseGeneric(p, t, d, "", "if (#eqStrings($1, $2)) goto $3;$n")
  
proc branchHasTooBigRange(b: PNode): bool = 
  for i in countup(0, sonsLen(b)-2): 
    # last son is block
    if (b.sons[i].Kind == nkRange) and
        b.sons[i].sons[1].intVal - b.sons[i].sons[0].intVal > RangeExpandLimit: 
      return true

proc IfSwitchSplitPoint(p: BProc, n: PNode): int =
  for i in 1..n.len-1:
    var branch = n[i]
    var stmtBlock = lastSon(branch)
    if stmtBlock.stmtsContainPragma(wLinearScanEnd):
      result = i
    elif hasSwitchRange notin CC[ccompiler].props: 
      if branch.kind == nkOfBranch and branchHasTooBigRange(branch): 
        result = i

proc genCaseRange(p: BProc, branch: PNode) =
  var length = branch.len
  for j in 0 .. length-2: 
    if branch[j].kind == nkRange: 
      if hasSwitchRange in CC[ccompiler].props: 
        lineF(p, cpsStmts, "case $1 ... $2:$n", [
            genLiteral(p, branch[j][0]), 
            genLiteral(p, branch[j][1])])
      else: 
        var v = copyNode(branch[j][0])
        while v.intVal <= branch[j][1].intVal: 
          lineF(p, cpsStmts, "case $1:$n", [genLiteral(p, v)])
          Inc(v.intVal)
    else:
      lineF(p, cpsStmts, "case $1:$n", [genLiteral(p, branch[j])])

proc genOrdinalCase(p: BProc, n: PNode, d: var TLoc) =
  # analyse 'case' statement:
  var splitPoint = IfSwitchSplitPoint(p, n)
  
  # generate if part (might be empty):
  var a: TLoc
  initLocExpr(p, n.sons[0], a)
  var Lend = if splitPoint > 0: genIfForCaseUntil(p, n, d,
                    rangeFormat = "if ($1 >= $2 && $1 <= $3) goto $4;$n",
                    eqFormat = "if ($1 == $2) goto $3;$n", 
                    splitPoint, a) else: nil
  
  # generate switch part (might be empty):
  if splitPoint+1 < n.len:
    lineF(p, cpsStmts, "switch ($1) {$n", [rdCharLoc(a)])
    var hasDefault = false
    for i in splitPoint+1 .. < n.len: 
      var branch = n[i]
      if branch.kind == nkOfBranch: 
        genCaseRange(p, branch)
      else: 
        # else part of case statement:
        lineF(p, cpsStmts, "default:$n")
        hasDefault = true
      exprBlock(p, branch.lastSon, d)
      lineF(p, cpsStmts, "break;$n")
    if (hasAssume in CC[ccompiler].props) and not hasDefault: 
      lineF(p, cpsStmts, "default: __assume(0);$n")
    lineF(p, cpsStmts, "}$n")
  if Lend != nil: fixLabel(p, Lend)
  
proc genCase(p: BProc, t: PNode, d: var TLoc) = 
  genLineDir(p, t)
  if not isEmptyType(t.typ) and d.k == locNone:
    getTemp(p, t.typ, d)
  case skipTypes(t.sons[0].typ, abstractVarRange).kind
  of tyString:
    genStringCase(p, t, d)
  of tyFloat..tyFloat128: 
    genCaseGeneric(p, t, d, "if ($1 >= $2 && $1 <= $3) goto $4;$n", 
                            "if ($1 == $2) goto $3;$n")
  else:
    genOrdinalCase(p, t, d)
  
proc hasGeneralExceptSection(t: PNode): bool = 
  var length = sonsLen(t)
  var i = 1
  while (i < length) and (t.sons[i].kind == nkExceptBranch): 
    var blen = sonsLen(t.sons[i])
    if blen == 1: 
      return true
    inc(i)
  result = false

proc genTryCpp(p: BProc, t: PNode, d: var TLoc) =
  # code to generate:
  #
  # XXX: There should be a standard dispatch algorithm
  # that's used both here and with multi-methods
  #
  #   try
  #   {
  #      myDiv(4, 9);
  #   } catch (NimException& exp) {
  #      if (isObj(exp, EIO) {
  #        ...
  #      } else if (isObj(exp, ESystem) {
  #        ...
  #        finallyPart()
  #        raise;
  #      } else {
  #        // general handler
  #      }
  #  }
  #  finallyPart();
  if not isEmptyType(t.typ) and d.k == locNone:
    getTemp(p, t.typ, d)
  var
    exc: PRope
    i, length, blen: int
  genLineDir(p, t)
  exc = getTempName()
  discard cgsym(p.module, "E_Base")
  add(p.nestedTryStmts, t)
  startBlock(p, "try {$n")
  expr(p, t.sons[0], d)
  length = sonsLen(t)
  endBlock(p, ropecg(p.module, "} catch (NimException& $1) {$n", [exc]))
  if optStackTrace in p.Options:
    linefmt(p, cpsStmts, "#setFrame((TFrame*)&F);$n")
  inc p.inExceptBlock
  i = 1
  var catchAllPresent = false
  while (i < length) and (t.sons[i].kind == nkExceptBranch):
    blen = sonsLen(t.sons[i])
    if i > 1: appf(p.s(cpsStmts), "else ")
    if blen == 1:
      # general except section:
      catchAllPresent = true
      exprBlock(p, t.sons[i].sons[0], d)
    else:
      var orExpr: PRope = nil
      for j in countup(0, blen - 2):
        assert(t.sons[i].sons[j].kind == nkType)
        if orExpr != nil: app(orExpr, "||")
        appcg(p.module, orExpr,
              "#isObj($1.exp->m_type, $2)",
              [exc, genTypeInfo(p.module, t.sons[i].sons[j].typ)])
      lineF(p, cpsStmts, "if ($1) ", [orExpr])
      exprBlock(p, t.sons[i].sons[blen-1], d)
    inc(i)
  
  # reraise the exception if there was no catch all
  # and none of the handlers matched
  if not catchAllPresent:
    if i > 1: lineF(p, cpsStmts, "else ")
    startBlock(p)
    var finallyBlock = t.lastSon
    if finallyBlock.kind == nkFinally:
      expr(p, finallyBlock.sons[0], d)
    line(p, cpsStmts, ~"throw;$n")
    endBlock(p)
  
  lineF(p, cpsStmts, "}$n") # end of catch block
  dec p.inExceptBlock
  
  discard pop(p.nestedTryStmts)
  if (i < length) and (t.sons[i].kind == nkFinally):
    exprBlock(p, t.sons[i].sons[0], d)
  
proc genTry(p: BProc, t: PNode, d: var TLoc) = 
  # code to generate:
  #
  # XXX: There should be a standard dispatch algorithm
  # that's used both here and with multi-methods
  #
  #  TSafePoint sp;
  #  pushSafePoint(&sp);
  #  sp.status = setjmp(sp.context);
  #  if (sp.status == 0) {
  #    myDiv(4, 9);
  #    popSafePoint();
  #  } else {
  #    popSafePoint();
  #    /* except DivisionByZero: */
  #    if (sp.status == DivisionByZero) {
  #      printf('Division by Zero\n');
  #      clearException();
  #    } else {
  #      clearException();
  #    }
  #  }
  #  { 
  #    /* finally: */
  #    printf('fin!\n');
  #  }
  #  if (exception not cleared)
  #    propagateCurrentException();
  #
  if not isEmptyType(t.typ) and d.k == locNone:
    getTemp(p, t.typ, d)
  genLineDir(p, t)
  var safePoint = getTempName()
  discard cgsym(p.module, "E_Base")
  linefmt(p, cpsLocals, "#TSafePoint $1;$n", safePoint)
  linefmt(p, cpsStmts, "#pushSafePoint(&$1);$n", safePoint)
  linefmt(p, cpsStmts, "$1.status = setjmp($1.context);$n", safePoint)
  startBlock(p, "if ($1.status == 0) {$n", [safePoint])
  var length = sonsLen(t)
  add(p.nestedTryStmts, t)
  expr(p, t.sons[0], d)
  linefmt(p, cpsStmts, "#popSafePoint();$n")
  endBlock(p)
  startBlock(p, "else {$n")
  linefmt(p, cpsStmts, "#popSafePoint();$n")
  if optStackTrace in p.Options:
    linefmt(p, cpsStmts, "#setFrame((TFrame*)&F);$n")
  inc p.inExceptBlock
  var i = 1
  while (i < length) and (t.sons[i].kind == nkExceptBranch):
    var blen = sonsLen(t.sons[i])
    if blen == 1:
      # general except section:
      if i > 1: lineF(p, cpsStmts, "else")
      startBlock(p)
      linefmt(p, cpsStmts, "$1.status = 0;$n", safePoint)
      expr(p, t.sons[i].sons[0], d)
      linefmt(p, cpsStmts, "#popCurrentException();$n")
      endBlock(p)
    else:
      var orExpr: PRope = nil
      for j in countup(0, blen - 2):
        assert(t.sons[i].sons[j].kind == nkType)
        if orExpr != nil: app(orExpr, "||")
        appcg(p.module, orExpr,
              "#isObj(#getCurrentException()->Sup.m_type, $1)",
              [genTypeInfo(p.module, t.sons[i].sons[j].typ)])
      if i > 1: line(p, cpsStmts, "else ")
      startBlock(p, "if ($1) {$n", [orExpr])
      linefmt(p, cpsStmts, "$1.status = 0;$n", safePoint)
      expr(p, t.sons[i].sons[blen-1], d)
      linefmt(p, cpsStmts, "#popCurrentException();$n")
      endBlock(p)
    inc(i)
  dec p.inExceptBlock
  discard pop(p.nestedTryStmts)
  endBlock(p) # end of else block
  if i < length and t.sons[i].kind == nkFinally:
    exprBlock(p, t.sons[i].sons[0], d)
  linefmt(p, cpsStmts, "if ($1.status != 0) #reraiseException();$n", safePoint)

proc genAsmOrEmitStmt(p: BProc, t: PNode): PRope = 
  for i in countup(0, sonsLen(t) - 1): 
    case t.sons[i].Kind
    of nkStrLit..nkTripleStrLit: 
      app(result, t.sons[i].strVal)
    of nkSym: 
      var sym = t.sons[i].sym
      if sym.kind in {skProc, skIterator, skMethod}: 
        var a: TLoc
        initLocExpr(p, t.sons[i], a)
        app(result, rdLoc(a))
      else: 
        var r = sym.loc.r
        if r == nil: 
          # if no name has already been given,
          # it doesn't matter much:
          r = mangleName(sym)
          sym.loc.r = r       # but be consequent!
        app(result, r)
    else: InternalError(t.sons[i].info, "genAsmOrEmitStmt()")

proc genAsmStmt(p: BProc, t: PNode) = 
  assert(t.kind == nkAsmStmt)
  genLineDir(p, t)
  var s = genAsmOrEmitStmt(p, t)
  lineF(p, cpsStmts, CC[ccompiler].asmStmtFrmt, [s])

proc genEmit(p: BProc, t: PNode) = 
  genLineDir(p, t)
  var s = genAsmOrEmitStmt(p, t.sons[1])
  if p.prc == nil: 
    # top level emit pragma?
    app(p.module.s[cfsProcHeaders], s)
  else:
    line(p, cpsStmts, s)

var 
  breakPointId: int = 0
  gBreakpoints: PRope # later the breakpoints are inserted into the main proc

proc genBreakPoint(p: BProc, t: PNode) = 
  var name: string
  if optEndb in p.Options:
    if t.kind == nkExprColonExpr: 
      assert(t.sons[1].kind in {nkStrLit..nkTripleStrLit})
      name = normalize(t.sons[1].strVal)
    else: 
      inc(breakPointId)
      name = "bp" & $breakPointId
    genLineDir(p, t)          # BUGFIX
    appcg(p.module, gBreakpoints, 
         "#dbgRegisterBreakpoint($1, (NCSTRING)$2, (NCSTRING)$3);$n", [
        toRope(toLinenumber(t.info)), makeCString(toFilename(t.info)),
        makeCString(name)])

proc genWatchpoint(p: BProc, n: PNode) =
  if optEndb notin p.Options: return
  var a: TLoc
  initLocExpr(p, n.sons[1], a)
  let typ = skipTypes(n.sons[1].typ, abstractVarRange)
  lineCg(p, cpsStmts, "#dbgRegisterWatchpoint($1, (NCSTRING)$2, $3);$n",
        [a.addrLoc, makeCString(renderTree(n.sons[1])),
        genTypeInfo(p.module, typ)])

proc genPragma(p: BProc, n: PNode) =
  for i in countup(0, sonsLen(n) - 1):
    var it = n.sons[i]
    case whichPragma(it)
    of wEmit: genEmit(p, it)
    of wBreakpoint: genBreakPoint(p, it)
    of wWatchpoint: genWatchpoint(p, it)
    else: nil

proc FieldDiscriminantCheckNeeded(p: BProc, asgn: PNode): bool = 
  if optFieldCheck in p.options:
    var le = asgn.sons[0]
    if le.kind == nkCheckedFieldExpr:
      var field = le.sons[0].sons[1].sym
      result = sfDiscriminant in field.flags
    elif le.kind == nkDotExpr:
      var field = le.sons[1].sym
      result = sfDiscriminant in field.flags      

proc genDiscriminantCheck(p: BProc, a, tmp: TLoc, objtype: PType, 
                          field: PSym) = 
  var t = skipTypes(objtype, abstractVar)
  assert t.kind == tyObject
  discard genTypeInfo(p.module, t)
  var L = lengthOrd(field.typ)
  if not ContainsOrIncl(p.module.declaredThings, field.id):
    appcg(p.module, cfsVars, "extern $1", 
          discriminatorTableDecl(p.module, t, field))
  lineCg(p, cpsStmts,
        "#FieldDiscriminantCheck((NI)(NU)($1), (NI)(NU)($2), $3, $4);$n",
        [rdLoc(a), rdLoc(tmp), discriminatorTableName(p.module, t, field),
         intLiteral(L+1)])

proc asgnFieldDiscriminant(p: BProc, e: PNode) = 
  var a, tmp: TLoc
  var dotExpr = e.sons[0]
  var d: PSym
  if dotExpr.kind == nkCheckedFieldExpr: dotExpr = dotExpr.sons[0]
  InitLocExpr(p, e.sons[0], a)
  getTemp(p, a.t, tmp)
  expr(p, e.sons[1], tmp)
  genDiscriminantCheck(p, a, tmp, dotExpr.sons[0].typ, dotExpr.sons[1].sym)
  genAssignment(p, a, tmp, {})
  
proc genAsgn(p: BProc, e: PNode, fastAsgn: bool) = 
  genLineDir(p, e)
  if not FieldDiscriminantCheckNeeded(p, e):
    var a: TLoc
    InitLocExpr(p, e.sons[0], a)
    if fastAsgn: incl(a.flags, lfNoDeepCopy)
    assert(a.t != nil)
    loadInto(p, e.sons[0], e.sons[1], a)
  else:
    asgnFieldDiscriminant(p, e)

proc genStmts(p: BProc, t: PNode) = 
  var a: TLoc
  expr(p, t, a)
  InternalAssert a.k in {locNone, locTemp}
