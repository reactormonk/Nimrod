#
#
#           The Nimrod Compiler
#        (c) Copyright 2009 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module implements the parser of the Pascal variant Nimrod is written in.
# It transfers a Pascal module into a Nimrod AST. Then the renderer can be
# used to generate the Nimrod version of the compiler.

import 
  os, llstream, scanner, paslex, idents, wordrecg, strutils, ast, astalgo, msgs, 
  options

type 
  TPasSection* = enum 
    seImplementation, seInterface
  TPasContext* = enum 
    conExpr, conStmt, conTypeDesc
  TPasParser*{.final.} = object 
    section*: TPasSection
    inParamList*: bool
    context*: TPasContext     # needed for the @emit command
    lastVarSection*: PNode
    lex*: TPasLex
    tok*: TPasTok
    repl*: TIdTable           # replacements
  
  TReplaceTuple* = array[0..1, string]

const 
  ImportBlackList*: array[1..3, string] = ["nsystem", "sysutils", "charsets"]
  stdReplacements*: array[1..19, TReplaceTuple] = [["include", "incl"], 
    ["exclude", "excl"], ["pchar", "cstring"], ["assignfile", "open"], 
    ["integer", "int"], ["longword", "int32"], ["cardinal", "int"], 
    ["boolean", "bool"], ["shortint", "int8"], ["smallint", "int16"], 
    ["longint", "int32"], ["byte", "int8"], ["word", "int16"], 
    ["single", "float32"], ["double", "float64"], ["real", "float"], 
    ["length", "len"], ["len", "length"], ["setlength", "setlen"]]
  nimReplacements*: array[1..35, TReplaceTuple] = [["nimread", "read"], 
    ["nimwrite", "write"], ["nimclosefile", "close"], ["closefile", "close"], 
    ["openfile", "open"], ["nsystem", "system"], ["ntime", "times"], 
    ["nos", "os"], ["nmath", "math"], ["ncopy", "copy"], ["addChar", "add"], 
    ["halt", "quit"], ["nobject", "TObject"], ["eof", "EndOfFile"], 
    ["input", "stdin"], ["output", "stdout"], ["addu", "`+%`"], 
    ["subu", "`-%`"], ["mulu", "`*%`"], ["divu", "`/%`"], ["modu", "`%%`"], 
    ["ltu", "`<%`"], ["leu", "`<=%`"], ["shlu", "`shl`"], ["shru", "`shr`"], 
    ["assigned", "not isNil"], ["eintoverflow", "EOverflow"], ["format", "`%`"], 
    ["snil", "nil"], ["tostringf", "$"], ["ttextfile", "tfile"], 
    ["tbinaryfile", "tfile"], ["strstart", "0"], ["nl", "\"\\n\""], ["tostring", 
      "$"]]                   #,
                              #    ('NL', '"\n"'),
                              #    ('tabulator', '''\t'''),
                              #    ('esc', '''\e'''),
                              #    ('cr', '''\r'''),
                              #    ('lf', '''\l'''),
                              #    ('ff', '''\f'''),
                              #    ('bel', '''\a'''),
                              #    ('backspace', '''\b'''),
                              #    ('vt', '''\v''') 

proc ParseUnit*(p: var TPasParser): PNode
proc openPasParser*(p: var TPasParser, filename: string, inputStream: PLLStream)
proc closePasParser*(p: var TPasParser)
proc exSymbol*(n: var PNode)
proc fixRecordDef*(n: var PNode)
  # XXX: move these two to an auxiliary module

# implementation

proc OpenPasParser(p: var TPasParser, filename: string, 
                   inputStream: PLLStream) = 
  OpenLexer(p.lex, filename, inputStream)
  initIdTable(p.repl)
  for i in countup(low(stdReplacements), high(stdReplacements)): 
    IdTablePut(p.repl, getIdent(stdReplacements[i][0]), 
               getIdent(stdReplacements[i][1]))
  if gCmd == cmdBoot: 
    for i in countup(low(nimReplacements), high(nimReplacements)): 
      IdTablePut(p.repl, getIdent(nimReplacements[i][0]), 
                 getIdent(nimReplacements[i][1]))
  
proc ClosePasParser(p: var TPasParser) = CloseLexer(p.lex)
proc getTok(p: var TPasParser) = getPasTok(p.lex, p.tok)

proc parMessage(p: TPasParser, msg: TMsgKind, arg = "") = 
  lexMessage(p.lex, msg, arg)

proc parLineInfo(p: TPasParser): TLineInfo = 
  result = getLineInfo(p.lex)

proc skipCom(p: var TPasParser, n: PNode) = 
  while p.tok.xkind == pxComment: 
    if (n != nil): 
      if n.comment == nil: n.comment = p.tok.literal
      else: n.comment = n.comment & "\n" & p.tok.literal
    else: 
      parMessage(p, warnCommentXIgnored, p.tok.literal)
    getTok(p)

proc ExpectIdent(p: TPasParser) = 
  if p.tok.xkind != pxSymbol: 
    lexMessage(p.lex, errIdentifierExpected, pasTokToStr(p.tok))
  
proc Eat(p: var TPasParser, xkind: TPasTokKind) = 
  if p.tok.xkind == xkind: getTok(p)
  else: lexMessage(p.lex, errTokenExpected, PasTokKindToStr[xkind])
  
proc Opt(p: var TPasParser, xkind: TPasTokKind) = 
  if p.tok.xkind == xkind: getTok(p)
  
proc newNodeP(kind: TNodeKind, p: TPasParser): PNode = 
  result = newNodeI(kind, getLineInfo(p.lex))

proc newIntNodeP(kind: TNodeKind, intVal: BiggestInt, p: TPasParser): PNode = 
  result = newNodeP(kind, p)
  result.intVal = intVal

proc newFloatNodeP(kind: TNodeKind, floatVal: BiggestFloat, p: TPasParser): PNode = 
  result = newNodeP(kind, p)
  result.floatVal = floatVal

proc newStrNodeP(kind: TNodeKind, strVal: string, p: TPasParser): PNode = 
  result = newNodeP(kind, p)
  result.strVal = strVal

proc newIdentNodeP(ident: PIdent, p: TPasParser): PNode = 
  result = newNodeP(nkIdent, p)
  result.ident = ident

proc createIdentNodeP(ident: PIdent, p: TPasParser): PNode = 
  var x: PIdent
  result = newNodeP(nkIdent, p)
  x = PIdent(IdTableGet(p.repl, ident))
  if x != nil: result.ident = x
  else: result.ident = ident
  
proc parseExpr(p: var TPasParser): PNode
proc parseStmt(p: var TPasParser): PNode
proc parseTypeDesc(p: var TPasParser, definition: PNode = nil): PNode
proc parseEmit(p: var TPasParser, definition: PNode): PNode = 
  var a: PNode
  getTok(p)                   # skip 'emit'
  result = nil
  if p.tok.xkind != pxCurlyDirRi: 
    case p.context
    of conExpr: 
      result = parseExpr(p)
    of conStmt: 
      result = parseStmt(p)
      if p.tok.xkind != pxCurlyDirRi: 
        a = result
        result = newNodeP(nkStmtList, p)
        addSon(result, a)
        while p.tok.xkind != pxCurlyDirRi: 
          addSon(result, parseStmt(p))
    of conTypeDesc: 
      result = parseTypeDesc(p, definition)
  eat(p, pxCurlyDirRi)

proc parseCommand(p: var TPasParser, definition: PNode = nil): PNode = 
  var a: PNode
  result = nil
  getTok(p)
  if p.tok.ident.id == getIdent("discard").id: 
    result = newNodeP(nkDiscardStmt, p)
    getTok(p)
    eat(p, pxCurlyDirRi)
    addSon(result, parseExpr(p))
  elif p.tok.ident.id == getIdent("set").id: 
    getTok(p)
    eat(p, pxCurlyDirRi)
    result = parseExpr(p)
    result.kind = nkCurly
    assert(sonsNotNil(result))
  elif p.tok.ident.id == getIdent("cast").id: 
    getTok(p)
    eat(p, pxCurlyDirRi)
    a = parseExpr(p)
    if (a.kind == nkCall) and (sonsLen(a) == 2): 
      result = newNodeP(nkCast, p)
      addSon(result, a.sons[0])
      addSon(result, a.sons[1])
    else: 
      parMessage(p, errInvalidDirectiveX, pasTokToStr(p.tok))
      result = a
  elif p.tok.ident.id == getIdent("emit").id: 
    result = parseEmit(p, definition)
  elif p.tok.ident.id == getIdent("ignore").id: 
    getTok(p)
    eat(p, pxCurlyDirRi)
    while true: 
      case p.tok.xkind
      of pxEof: 
        parMessage(p, errTokenExpected, "{@emit}")
      of pxCommand: 
        getTok(p)
        if p.tok.ident.id == getIdent("emit").id: 
          result = parseEmit(p, definition)
          break 
        else: 
          while (p.tok.xkind != pxCurlyDirRi) and (p.tok.xkind != pxEof): 
            getTok(p)
          eat(p, pxCurlyDirRi)
      else: 
        getTok(p)             # skip token
  elif p.tok.ident.id == getIdent("ptr").id: 
    result = newNodeP(nkPtrTy, p)
    getTok(p)
    eat(p, pxCurlyDirRi)
  elif p.tok.ident.id == getIdent("tuple").id: 
    result = newNodeP(nkTupleTy, p)
    getTok(p)
    eat(p, pxCurlyDirRi)
  elif p.tok.ident.id == getIdent("acyclic").id: 
    result = newIdentNodeP(p.tok.ident, p)
    getTok(p)
    eat(p, pxCurlyDirRi)
  else: 
    parMessage(p, errInvalidDirectiveX, pasTokToStr(p.tok))
    while true: 
      getTok(p)
      if (p.tok.xkind == pxCurlyDirRi) or (p.tok.xkind == pxEof): break 
    eat(p, pxCurlyDirRi)
    result = nil

proc getPrecedence(kind: TPasTokKind): int = 
  case kind
  of pxDiv, pxMod, pxStar, pxSlash, pxShl, pxShr, pxAnd: 
    result = 5                # highest
  of pxPlus, pxMinus, pxOr, pxXor: 
    result = 4
  of pxIn, pxEquals, pxLe, pxLt, pxGe, pxGt, pxNeq, pxIs: 
    result = 3
  else: result = - 1
  
proc rangeExpr(p: var TPasParser): PNode = 
  var a: PNode
  a = parseExpr(p)
  if p.tok.xkind == pxDotDot: 
    result = newNodeP(nkRange, p)
    addSon(result, a)
    getTok(p)
    skipCom(p, result)
    addSon(result, parseExpr(p))
  else: 
    result = a
  
proc bracketExprList(p: var TPasParser, first: PNode): PNode = 
  var a: PNode
  result = newNodeP(nkBracketExpr, p)
  addSon(result, first)
  getTok(p)
  skipCom(p, result)
  while true: 
    if p.tok.xkind == pxBracketRi: 
      getTok(p)
      break 
    if p.tok.xkind == pxEof: 
      parMessage(p, errTokenExpected, PasTokKindToStr[pxBracketRi])
      break 
    a = rangeExpr(p)
    skipCom(p, a)
    if p.tok.xkind == pxComma: 
      getTok(p)
      skipCom(p, a)
    addSon(result, a)

proc exprColonEqExpr(p: var TPasParser, kind: TNodeKind, tok: TPasTokKind): PNode = 
  var a: PNode
  a = parseExpr(p)
  if p.tok.xkind == tok: 
    result = newNodeP(kind, p)
    getTok(p)
    skipCom(p, result)
    addSon(result, a)
    addSon(result, parseExpr(p))
  else: 
    result = a
  
proc exprListAux(p: var TPasParser, elemKind: TNodeKind, 
                 endTok, sepTok: TPasTokKind, result: PNode) = 
  var a: PNode
  getTok(p)
  skipCom(p, result)
  while true: 
    if p.tok.xkind == endTok: 
      getTok(p)
      break 
    if p.tok.xkind == pxEof: 
      parMessage(p, errTokenExpected, PasTokKindToStr[endtok])
      break 
    a = exprColonEqExpr(p, elemKind, sepTok)
    skipCom(p, a)
    if (p.tok.xkind == pxComma) or (p.tok.xkind == pxSemicolon): 
      getTok(p)
      skipCom(p, a)
    addSon(result, a)

proc qualifiedIdent(p: var TPasParser): PNode = 
  var a: PNode
  if p.tok.xkind == pxSymbol: 
    result = createIdentNodeP(p.tok.ident, p)
  else: 
    parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
    return nil
  getTok(p)
  skipCom(p, result)
  if p.tok.xkind == pxDot: 
    getTok(p)
    skipCom(p, result)
    if p.tok.xkind == pxSymbol: 
      a = result
      result = newNodeI(nkDotExpr, a.info)
      addSon(result, a)
      addSon(result, createIdentNodeP(p.tok.ident, p))
      getTok(p)
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
  
proc qualifiedIdentListAux(p: var TPasParser, endTok: TPasTokKind, result: PNode) = 
  var a: PNode
  getTok(p)
  skipCom(p, result)
  while true: 
    if p.tok.xkind == endTok: 
      getTok(p)
      break 
    if p.tok.xkind == pxEof: 
      parMessage(p, errTokenExpected, PasTokKindToStr[endtok])
      break 
    a = qualifiedIdent(p)
    skipCom(p, a)
    if p.tok.xkind == pxComma: 
      getTok(p)
      skipCom(p, a)
    addSon(result, a)

proc exprColonEqExprList(p: var TPasParser, kind, elemKind: TNodeKind, 
                         endTok, sepTok: TPasTokKind): PNode = 
  result = newNodeP(kind, p)
  exprListAux(p, elemKind, endTok, sepTok, result)

proc setBaseFlags(n: PNode, base: TNumericalBase) = 
  case base
  of base10: 
    nil
  of base2: 
    incl(n.flags, nfBase2)
  of base8: 
    incl(n.flags, nfBase8)
  of base16: 
    incl(n.flags, nfBase16)
  
proc identOrLiteral(p: var TPasParser): PNode = 
  var a: PNode
  case p.tok.xkind
  of pxSymbol: 
    result = createIdentNodeP(p.tok.ident, p)
    getTok(p)
  of pxIntLit: 
    result = newIntNodeP(nkIntLit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of pxInt64Lit: 
    result = newIntNodeP(nkInt64Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of pxFloatLit: 
    result = newFloatNodeP(nkFloatLit, p.tok.fNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of pxStrLit: 
    if len(p.tok.literal) != 1: result = newStrNodeP(nkStrLit, p.tok.literal, p)
    else: result = newIntNodeP(nkCharLit, ord(p.tok.literal[0]), p)
    getTok(p)
  of pxNil: 
    result = newNodeP(nkNilLit, p)
    getTok(p)
  of pxParLe: 
    # () constructor
    result = exprColonEqExprList(p, nkPar, nkExprColonExpr, pxParRi, pxColon) #if hasSonWith(result, nkExprColonExpr) then
                                                                              #  replaceSons(result, nkExprColonExpr, nkExprEqExpr)
    if (sonsLen(result) > 1) and not hasSonWith(result, nkExprColonExpr): 
      result.kind = nkBracket # is an array constructor
  of pxBracketLe: 
    # [] constructor
    result = newNodeP(nkBracket, p)
    getTok(p)
    skipCom(p, result)
    while (p.tok.xkind != pxBracketRi) and (p.tok.xkind != pxEof): 
      a = rangeExpr(p)
      if a.kind == nkRange: 
        result.kind = nkCurly # it is definitely a set literal
      opt(p, pxComma)
      skipCom(p, a)
      assert(a != nil)
      addSon(result, a)
    eat(p, pxBracketRi)
  of pxCommand: 
    result = parseCommand(p)
  else: 
    parMessage(p, errExprExpected, pasTokToStr(p.tok))
    getTok(p)                 # we must consume a token here to prevend endless loops!
    result = nil
  if result != nil: skipCom(p, result)
  
proc primary(p: var TPasParser): PNode = 
  var a: PNode
  # prefix operator?
  if (p.tok.xkind == pxNot) or (p.tok.xkind == pxMinus) or
      (p.tok.xkind == pxPlus): 
    result = newNodeP(nkPrefix, p)
    a = newIdentNodeP(getIdent(pasTokToStr(p.tok)), p)
    addSon(result, a)
    getTok(p)
    skipCom(p, a)
    addSon(result, primary(p))
    return 
  elif p.tok.xkind == pxAt: 
    result = newNodeP(nkAddr, p)
    a = newIdentNodeP(getIdent(pasTokToStr(p.tok)), p)
    getTok(p)
    if p.tok.xkind == pxBracketLe: 
      result = newNodeP(nkPrefix, p)
      addSon(result, a)
      addSon(result, identOrLiteral(p))
    else: 
      addSon(result, primary(p))
    return 
  result = identOrLiteral(p)
  while true: 
    case p.tok.xkind
    of pxParLe: 
      a = result
      result = newNodeP(nkCall, p)
      addSon(result, a)
      exprListAux(p, nkExprEqExpr, pxParRi, pxEquals, result)
    of pxDot: 
      a = result
      result = newNodeP(nkDotExpr, p)
      addSon(result, a)
      getTok(p)               # skip '.'
      skipCom(p, result)
      if p.tok.xkind == pxSymbol: 
        addSon(result, createIdentNodeP(p.tok.ident, p))
        getTok(p)
      else: 
        parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
    of pxHat: 
      a = result
      result = newNodeP(nkDerefExpr, p)
      addSon(result, a)
      getTok(p)
    of pxBracketLe: 
      result = bracketExprList(p, result)
    else: break 
  
proc lowestExprAux(p: var TPasParser, v: var PNode, limit: int): TPasTokKind = 
  var 
    op, nextop: TPasTokKind
    opPred: int
    v2, node, opNode: PNode
  v = primary(p)              # expand while operators have priorities higher than 'limit'
  op = p.tok.xkind
  opPred = getPrecedence(op)
  while (opPred > limit): 
    node = newNodeP(nkInfix, p)
    opNode = newIdentNodeP(getIdent(pasTokToStr(p.tok)), p) # skip operator:
    getTok(p)
    case op
    of pxPlus: 
      case p.tok.xkind
      of pxPer: 
        getTok(p)
        eat(p, pxCurlyDirRi)
        opNode.ident = getIdent("+%")
      of pxAmp: 
        getTok(p)
        eat(p, pxCurlyDirRi)
        opNode.ident = getIdent("&")
      else: 
        nil
    of pxMinus: 
      if p.tok.xkind == pxPer: 
        getTok(p)
        eat(p, pxCurlyDirRi)
        opNode.ident = getIdent("-%")
    of pxEquals: 
      opNode.ident = getIdent("==")
    of pxNeq: 
      opNode.ident = getIdent("!=")
    else: 
      nil
    skipCom(p, opNode)        # read sub-expression with higher priority
    nextop = lowestExprAux(p, v2, opPred)
    addSon(node, opNode)
    addSon(node, v)
    addSon(node, v2)
    v = node
    op = nextop
    opPred = getPrecedence(nextop)
  result = op                 # return first untreated operator
  
proc fixExpr(n: PNode): PNode = 
  result = n
  if n == nil: return 
  case n.kind
  of nkInfix: 
    if n.sons[1].kind == nkBracket: 
      n.sons[1].kind = nkCurly
    if n.sons[2].kind == nkBracket: 
      n.sons[2].kind = nkCurly
    if (n.sons[0].kind == nkIdent): 
      if (n.sons[0].ident.id == getIdent("+").id): 
        if (n.sons[1].kind == nkCharLit) and (n.sons[2].kind == nkStrLit) and
            (n.sons[2].strVal == ""): 
          result = newStrNode(nkStrLit, chr(int(n.sons[1].intVal)) & "")
          result.info = n.info
          return              # do not process sons as they don't exist anymore
        elif (n.sons[1].kind in {nkCharLit, nkStrLit}) or
            (n.sons[2].kind in {nkCharLit, nkStrLit}): 
          n.sons[0].ident = getIdent("&") # fix operator
  else: 
    nil
  if not (n.kind in {nkEmpty..nkNilLit}): 
    for i in countup(0, sonsLen(n) - 1): result.sons[i] = fixExpr(n.sons[i])
  
proc parseExpr(p: var TPasParser): PNode = 
  var oldcontext: TPasContext
  oldcontext = p.context
  p.context = conExpr
  if p.tok.xkind == pxCommand: 
    result = parseCommand(p)
  else: 
    discard lowestExprAux(p, result, - 1)
    result = fixExpr(result)
  p.context = oldcontext

proc parseExprStmt(p: var TPasParser): PNode = 
  var 
    a, b: PNode
    info: TLineInfo
  info = parLineInfo(p)
  a = parseExpr(p)
  if p.tok.xkind == pxAsgn: 
    getTok(p)
    skipCom(p, a)
    b = parseExpr(p)
    result = newNodeI(nkAsgn, info)
    addSon(result, a)
    addSon(result, b)
  else: 
    result = a
  
proc inImportBlackList(ident: PIdent): bool = 
  for i in countup(low(ImportBlackList), high(ImportBlackList)): 
    if ident.id == getIdent(ImportBlackList[i]).id: 
      return true
  result = false

proc parseUsesStmt(p: var TPasParser): PNode = 
  var a: PNode
  result = newNodeP(nkImportStmt, p)
  getTok(p)                   # skip `import`
  skipCom(p, result)
  while true: 
    case p.tok.xkind
    of pxEof: break 
    of pxSymbol: a = newIdentNodeP(p.tok.ident, p)
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
      break 
    getTok(p)                 # skip identifier, string
    skipCom(p, a)
    if (gCmd != cmdBoot) or not inImportBlackList(a.ident): 
      addSon(result, createIdentNodeP(a.ident, p))
    if p.tok.xkind == pxComma: 
      getTok(p)
      skipCom(p, a)
    else: 
      break 
  if sonsLen(result) == 0: result = nil
  
proc parseIncludeDir(p: var TPasParser): PNode = 
  var filename: string
  result = newNodeP(nkIncludeStmt, p)
  getTok(p)                   # skip `include`
  filename = ""
  while true: 
    case p.tok.xkind
    of pxSymbol, pxDot, pxDotDot, pxSlash: 
      filename = filename & pasTokToStr(p.tok)
      getTok(p)
    of pxStrLit: 
      filename = p.tok.literal
      getTok(p)
      break 
    of pxCurlyDirRi: 
      break 
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
      break 
  addSon(result, newStrNodeP(nkStrLit, changeFileExt(filename, "nim"), p))
  if filename == "config.inc": result = nil
  
proc definedExprAux(p: var TPasParser): PNode = 
  result = newNodeP(nkCall, p)
  addSon(result, newIdentNodeP(getIdent("defined"), p))
  ExpectIdent(p)
  addSon(result, createIdentNodeP(p.tok.ident, p))
  getTok(p)

proc isHandledDirective(p: TPasParser): bool = 
  result = false
  if p.tok.xkind in {pxCurlyDirLe, pxStarDirLe}: 
    case whichKeyword(p.tok.ident)
    of wElse, wEndif: result = false
    else: result = true
  
proc parseStmtList(p: var TPasParser): PNode = 
  result = newNodeP(nkStmtList, p)
  while true: 
    case p.tok.xkind
    of pxEof: 
      break 
    of pxCurlyDirLe, pxStarDirLe: 
      if not isHandledDirective(p): break 
    else: 
      nil
    addSon(result, parseStmt(p))
  if sonsLen(result) == 1: result = result.sons[0]
  
proc parseIfDirAux(p: var TPasParser, result: PNode) = 
  var 
    s: PNode
    endMarker: TPasTokKind
  addSon(result.sons[0], parseStmtList(p))
  if p.tok.xkind in {pxCurlyDirLe, pxStarDirLe}: 
    endMarker = succ(p.tok.xkind)
    if whichKeyword(p.tok.ident) == wElse: 
      s = newNodeP(nkElse, p)
      while (p.tok.xkind != pxEof) and (p.tok.xkind != endMarker): getTok(p)
      eat(p, endMarker)
      addSon(s, parseStmtList(p))
      addSon(result, s)
    if p.tok.xkind in {pxCurlyDirLe, pxStarDirLe}: 
      endMarker = succ(p.tok.xkind)
      if whichKeyword(p.tok.ident) == wEndif: 
        while (p.tok.xkind != pxEof) and (p.tok.xkind != endMarker): getTok(p)
        eat(p, endMarker)
      else: 
        parMessage(p, errXExpected, "{$endif}")
  else: 
    parMessage(p, errXExpected, "{$endif}")
  
proc parseIfdefDir(p: var TPasParser, endMarker: TPasTokKind): PNode = 
  result = newNodeP(nkWhenStmt, p)
  addSon(result, newNodeP(nkElifBranch, p))
  getTok(p)
  addSon(result.sons[0], definedExprAux(p))
  eat(p, endMarker)
  parseIfDirAux(p, result)

proc parseIfndefDir(p: var TPasParser, endMarker: TPasTokKind): PNode = 
  var e: PNode
  result = newNodeP(nkWhenStmt, p)
  addSon(result, newNodeP(nkElifBranch, p))
  getTok(p)
  e = newNodeP(nkCall, p)
  addSon(e, newIdentNodeP(getIdent("not"), p))
  addSon(e, definedExprAux(p))
  eat(p, endMarker)
  addSon(result.sons[0], e)
  parseIfDirAux(p, result)

proc parseIfDir(p: var TPasParser, endMarker: TPasTokKind): PNode = 
  result = newNodeP(nkWhenStmt, p)
  addSon(result, newNodeP(nkElifBranch, p))
  getTok(p)
  addSon(result.sons[0], parseExpr(p))
  eat(p, endMarker)
  parseIfDirAux(p, result)

proc parseDirective(p: var TPasParser): PNode = 
  var endMarker: TPasTokKind
  result = nil
  if not (p.tok.xkind in {pxCurlyDirLe, pxStarDirLe}): return 
  endMarker = succ(p.tok.xkind)
  if p.tok.ident != nil: 
    case whichKeyword(p.tok.ident)
    of wInclude: 
      result = parseIncludeDir(p)
      eat(p, endMarker)
    of wIf: 
      result = parseIfDir(p, endMarker)
    of wIfdef: 
      result = parseIfdefDir(p, endMarker)
    of wIfndef: 
      result = parseIfndefDir(p, endMarker)
    else: 
      # skip unknown compiler directive
      while (p.tok.xkind != pxEof) and (p.tok.xkind != endMarker): getTok(p)
      eat(p, endMarker)
  else: 
    eat(p, endMarker)
  
proc parseRaise(p: var TPasParser): PNode = 
  result = newNodeP(nkRaiseStmt, p)
  getTok(p)
  skipCom(p, result)
  if p.tok.xkind != pxSemicolon: addSon(result, parseExpr(p))
  else: addSon(result, nil)
  
proc parseIf(p: var TPasParser): PNode = 
  var branch: PNode
  result = newNodeP(nkIfStmt, p)
  while true: 
    getTok(p)                 # skip ``if``
    branch = newNodeP(nkElifBranch, p)
    skipCom(p, branch)
    addSon(branch, parseExpr(p))
    eat(p, pxThen)
    skipCom(p, branch)
    addSon(branch, parseStmt(p))
    skipCom(p, branch)
    addSon(result, branch)
    if p.tok.xkind == pxElse: 
      getTok(p)
      if p.tok.xkind != pxIf: 
        # ordinary else part:
        branch = newNodeP(nkElse, p)
        skipCom(p, result)    # BUGFIX
        addSon(branch, parseStmt(p))
        addSon(result, branch)
        break 
    else: 
      break 
  
proc parseWhile(p: var TPasParser): PNode = 
  result = newNodeP(nkWhileStmt, p)
  getTok(p)
  skipCom(p, result)
  addSon(result, parseExpr(p))
  eat(p, pxDo)
  skipCom(p, result)
  addSon(result, parseStmt(p))

proc parseRepeat(p: var TPasParser): PNode = 
  var a, b, c, s: PNode
  result = newNodeP(nkWhileStmt, p)
  getTok(p)
  skipCom(p, result)
  addSon(result, newIdentNodeP(getIdent("true"), p))
  s = newNodeP(nkStmtList, p)
  while (p.tok.xkind != pxEof) and (p.tok.xkind != pxUntil): 
    addSon(s, parseStmt(p))
  eat(p, pxUntil)
  a = newNodeP(nkIfStmt, p)
  skipCom(p, a)
  b = newNodeP(nkElifBranch, p)
  c = newNodeP(nkBreakStmt, p)
  addSon(c, nil)
  addSon(b, parseExpr(p))
  skipCom(p, a)
  addSon(b, c)
  addSon(a, b)
  if (b.sons[0].kind == nkIdent) and
      (b.sons[0].ident.id == getIdent("false").id): 
    nil
  else: 
    addSon(s, a)
  addSon(result, s)

proc parseCase(p: var TPasParser): PNode = 
  var b: PNode
  result = newNodeP(nkCaseStmt, p)
  getTok(p)
  addSon(result, parseExpr(p))
  eat(p, pxOf)
  skipCom(p, result)
  while (p.tok.xkind != pxEnd) and (p.tok.xkind != pxEof): 
    if p.tok.xkind == pxElse: 
      b = newNodeP(nkElse, p)
      getTok(p)
    else: 
      b = newNodeP(nkOfBranch, p)
      while (p.tok.xkind != pxEof) and (p.tok.xkind != pxColon): 
        addSon(b, rangeExpr(p))
        opt(p, pxComma)
        skipcom(p, b)
      eat(p, pxColon)
    skipCom(p, b)
    addSon(b, parseStmt(p))
    addSon(result, b)
    if b.kind == nkElse: break 
  eat(p, pxEnd)

proc parseTry(p: var TPasParser): PNode = 
  var b, e: PNode
  result = newNodeP(nkTryStmt, p)
  getTok(p)
  skipCom(p, result)
  b = newNodeP(nkStmtList, p)
  while not (p.tok.xkind in {pxFinally, pxExcept, pxEof, pxEnd}): 
    addSon(b, parseStmt(p))
  addSon(result, b)
  if p.tok.xkind == pxExcept: 
    getTok(p)
    while p.tok.ident.id == getIdent("on").id: 
      b = newNodeP(nkExceptBranch, p)
      getTok(p)
      e = qualifiedIdent(p)
      if p.tok.xkind == pxColon: 
        getTok(p)
        e = qualifiedIdent(p)
      addSon(b, e)
      eat(p, pxDo)
      addSon(b, parseStmt(p))
      addSon(result, b)
      if p.tok.xkind == pxCommand: discard parseCommand(p)
    if p.tok.xkind == pxElse: 
      b = newNodeP(nkExceptBranch, p)
      getTok(p)
      addSon(b, parseStmt(p))
      addSon(result, b)
  if p.tok.xkind == pxFinally: 
    b = newNodeP(nkFinally, p)
    getTok(p)
    e = newNodeP(nkStmtList, p)
    while (p.tok.xkind != pxEof) and (p.tok.xkind != pxEnd): 
      addSon(e, parseStmt(p))
    if sonsLen(e) == 0: addSon(e, newNodeP(nkNilLit, p))
    addSon(result, e)
  eat(p, pxEnd)

proc parseFor(p: var TPasParser): PNode = 
  var a, b, c: PNode
  result = newNodeP(nkForStmt, p)
  getTok(p)
  skipCom(p, result)
  expectIdent(p)
  addSon(result, createIdentNodeP(p.tok.ident, p))
  getTok(p)
  eat(p, pxAsgn)
  a = parseExpr(p)
  b = nil
  c = newNodeP(nkCall, p)
  if p.tok.xkind == pxTo: 
    addSon(c, newIdentNodeP(getIdent("countup"), p))
    getTok(p)
    b = parseExpr(p)
  elif p.tok.xkind == pxDownto: 
    addSon(c, newIdentNodeP(getIdent("countdown"), p))
    getTok(p)
    b = parseExpr(p)
  else: 
    parMessage(p, errTokenExpected, PasTokKindToStr[pxTo])
  addSon(c, a)
  addSon(c, b)
  eat(p, pxDo)
  skipCom(p, result)
  addSon(result, c)
  addSon(result, parseStmt(p))

proc parseParam(p: var TPasParser): PNode = 
  var a, v: PNode
  result = newNodeP(nkIdentDefs, p)
  v = nil
  case p.tok.xkind
  of pxConst: 
    getTok(p)
  of pxVar: 
    getTok(p)
    v = newNodeP(nkVarTy, p)
  of pxOut: 
    getTok(p)
    v = newNodeP(nkVarTy, p)
  else: 
    nil
  while true: 
    case p.tok.xkind
    of pxSymbol: a = createIdentNodeP(p.tok.ident, p)
    of pxColon, pxEof, pxParRi, pxEquals: break 
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
      return 
    getTok(p)                 # skip identifier
    skipCom(p, a)
    if p.tok.xkind == pxComma: 
      getTok(p)
      skipCom(p, a)
    addSon(result, a)
  if p.tok.xkind == pxColon: 
    getTok(p)
    skipCom(p, result)
    if v != nil: addSon(v, parseTypeDesc(p))
    else: v = parseTypeDesc(p)
    addSon(result, v)
  else: 
    addSon(result, nil)
    if p.tok.xkind != pxEquals: 
      parMessage(p, errColonOrEqualsExpected, pasTokToStr(p.tok))
  if p.tok.xkind == pxEquals: 
    getTok(p)
    skipCom(p, result)
    addSon(result, parseExpr(p))
  else: 
    addSon(result, nil)
  
proc parseParamList(p: var TPasParser): PNode = 
  var a: PNode
  result = newNodeP(nkFormalParams, p)
  addSon(result, nil)         # return type
  if p.tok.xkind == pxParLe: 
    p.inParamList = true
    getTok(p)
    skipCom(p, result)
    while true: 
      case p.tok.xkind
      of pxSymbol, pxConst, pxVar, pxOut: 
        a = parseParam(p)
      of pxParRi: 
        getTok(p)
        break 
      else: 
        parMessage(p, errTokenExpected, ")")
        break 
      skipCom(p, a)
      if p.tok.xkind == pxSemicolon: 
        getTok(p)
        skipCom(p, a)
      addSon(result, a)
    p.inParamList = false
  if p.tok.xkind == pxColon: 
    getTok(p)
    skipCom(p, result)
    result.sons[0] = parseTypeDesc(p)

proc parseCallingConvention(p: var TPasParser): PNode = 
  result = nil
  if p.tok.xkind == pxSymbol: 
    case whichKeyword(p.tok.ident)
    of wStdcall, wCDecl, wSafeCall, wSysCall, wInline, wFastCall: 
      result = newNodeP(nkPragma, p)
      addSon(result, newIdentNodeP(p.tok.ident, p))
      getTok(p)
      opt(p, pxSemicolon)
    of wRegister: 
      result = newNodeP(nkPragma, p)
      addSon(result, newIdentNodeP(getIdent("fastcall"), p))
      getTok(p)
      opt(p, pxSemicolon)
    else: 
      nil

proc parseRoutineSpecifiers(p: var TPasParser, noBody: var bool): PNode = 
  var e: PNode
  result = parseCallingConvention(p)
  noBody = false
  while p.tok.xkind == pxSymbol: 
    case whichKeyword(p.tok.ident)
    of wAssembler, wOverload, wFar: 
      getTok(p)
      opt(p, pxSemicolon)
    of wForward: 
      noBody = true
      getTok(p)
      opt(p, pxSemicolon)
    of wImportc: 
      # This is a fake for platform module. There is no ``importc``
      # directive in Pascal.
      if result == nil: result = newNodeP(nkPragma, p)
      addSon(result, newIdentNodeP(getIdent("importc"), p))
      noBody = true
      getTok(p)
      opt(p, pxSemicolon)
    of wNoConv: 
      # This is a fake for platform module. There is no ``noconv``
      # directive in Pascal.
      if result == nil: result = newNodeP(nkPragma, p)
      addSon(result, newIdentNodeP(getIdent("noconv"), p))
      noBody = true
      getTok(p)
      opt(p, pxSemicolon)
    of wProcVar: 
      # This is a fake for the Nimrod compiler. There is no ``procvar``
      # directive in Pascal.
      if result == nil: result = newNodeP(nkPragma, p)
      addSon(result, newIdentNodeP(getIdent("procvar"), p))
      getTok(p)
      opt(p, pxSemicolon)
    of wVarargs: 
      if result == nil: result = newNodeP(nkPragma, p)
      addSon(result, newIdentNodeP(getIdent("varargs"), p))
      getTok(p)
      opt(p, pxSemicolon)
    of wExternal: 
      if result == nil: result = newNodeP(nkPragma, p)
      getTok(p)
      noBody = true
      e = newNodeP(nkExprColonExpr, p)
      addSon(e, newIdentNodeP(getIdent("dynlib"), p))
      addSon(e, parseExpr(p))
      addSon(result, e)
      opt(p, pxSemicolon)
      if (p.tok.xkind == pxSymbol) and
          (p.tok.ident.id == getIdent("name").id): 
        e = newNodeP(nkExprColonExpr, p)
        getTok(p)
        addSon(e, newIdentNodeP(getIdent("importc"), p))
        addSon(e, parseExpr(p))
        addSon(result, e)
      else: 
        addSon(result, newIdentNodeP(getIdent("importc"), p))
      opt(p, pxSemicolon)
    else: 
      e = parseCallingConvention(p)
      if e == nil: break 
      if result == nil: result = newNodeP(nkPragma, p)
      addSon(result, e.sons[0])

proc parseRoutineType(p: var TPasParser): PNode = 
  result = newNodeP(nkProcTy, p)
  getTok(p)
  skipCom(p, result)
  addSon(result, parseParamList(p))
  opt(p, pxSemicolon)
  addSon(result, parseCallingConvention(p))
  skipCom(p, result)

proc parseEnum(p: var TPasParser): PNode = 
  var a, b: PNode
  result = newNodeP(nkEnumTy, p)
  getTok(p)
  skipCom(p, result)
  addSon(result, nil)         # it does not inherit from any enumeration
  while true: 
    case p.tok.xkind
    of pxEof, pxParRi: break 
    of pxSymbol: a = newIdentNodeP(p.tok.ident, p)
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
      break 
    getTok(p)                 # skip identifier
    skipCom(p, a)
    if (p.tok.xkind == pxEquals) or (p.tok.xkind == pxAsgn): 
      getTok(p)
      skipCom(p, a)
      b = a
      a = newNodeP(nkEnumFieldDef, p)
      addSon(a, b)
      addSon(a, parseExpr(p))
    if p.tok.xkind == pxComma: 
      getTok(p)
      skipCom(p, a)
    addSon(result, a)
  eat(p, pxParRi)

proc identVis(p: var TPasParser): PNode = 
  # identifier with visability
  var a: PNode
  a = createIdentNodeP(p.tok.ident, p)
  if p.section == seInterface: 
    result = newNodeP(nkPostfix, p)
    addSon(result, newIdentNodeP(getIdent("*"), p))
    addSon(result, a)
  else: 
    result = a
  getTok(p)

type 
  TSymbolParser = proc (p: var TPasParser): PNode

proc rawIdent(p: var TPasParser): PNode = 
  result = createIdentNodeP(p.tok.ident, p)
  getTok(p)

proc parseIdentColonEquals(p: var TPasParser, identParser: TSymbolParser): PNode = 
  var a: PNode
  result = newNodeP(nkIdentDefs, p)
  while true: 
    case p.tok.xkind
    of pxSymbol: a = identParser(p)
    of pxColon, pxEof, pxParRi, pxEquals: break 
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
      return 
    skipCom(p, a)
    if p.tok.xkind == pxComma: 
      getTok(p)
      skipCom(p, a)
    addSon(result, a)
  if p.tok.xkind == pxColon: 
    getTok(p)
    skipCom(p, result)
    addSon(result, parseTypeDesc(p))
  else: 
    addSon(result, nil)
    if p.tok.xkind != pxEquals: 
      parMessage(p, errColonOrEqualsExpected, pasTokToStr(p.tok))
  if p.tok.xkind == pxEquals: 
    getTok(p)
    skipCom(p, result)
    addSon(result, parseExpr(p))
  else: 
    addSon(result, nil)
  if p.tok.xkind == pxSemicolon: 
    getTok(p)
    skipCom(p, result)

proc parseRecordCase(p: var TPasParser): PNode = 
  var a, b, c: PNode
  result = newNodeP(nkRecCase, p)
  getTok(p)
  a = newNodeP(nkIdentDefs, p)
  addSon(a, rawIdent(p))
  eat(p, pxColon)
  addSon(a, parseTypeDesc(p))
  addSon(a, nil)
  addSon(result, a)
  eat(p, pxOf)
  skipCom(p, result)
  while true: 
    case p.tok.xkind
    of pxEof, pxEnd: 
      break 
    of pxElse: 
      b = newNodeP(nkElse, p)
      getTok(p)
    else: 
      b = newNodeP(nkOfBranch, p)
      while (p.tok.xkind != pxEof) and (p.tok.xkind != pxColon): 
        addSon(b, rangeExpr(p))
        opt(p, pxComma)
        skipcom(p, b)
      eat(p, pxColon)
    skipCom(p, b)
    c = newNodeP(nkRecList, p)
    eat(p, pxParLe)
    while (p.tok.xkind != pxParRi) and (p.tok.xkind != pxEof): 
      addSon(c, parseIdentColonEquals(p, rawIdent))
      opt(p, pxSemicolon)
      skipCom(p, lastSon(c))
    eat(p, pxParRi)
    opt(p, pxSemicolon)
    if sonsLen(c) > 0: skipCom(p, lastSon(c))
    else: addSon(c, newNodeP(nkNilLit, p))
    addSon(b, c)
    addSon(result, b)
    if b.kind == nkElse: break 
  
proc parseRecordPart(p: var TPasParser): PNode = 
  result = nil
  while (p.tok.xkind != pxEof) and (p.tok.xkind != pxEnd): 
    if result == nil: result = newNodeP(nkRecList, p)
    case p.tok.xkind
    of pxSymbol: 
      addSon(result, parseIdentColonEquals(p, rawIdent))
      opt(p, pxSemicolon)
      skipCom(p, lastSon(result))
    of pxCase: 
      addSon(result, parseRecordCase(p))
    of pxComment: 
      skipCom(p, lastSon(result))
    else: 
      parMessage(p, errIdentifierExpected, pasTokToStr(p.tok))
      break 

proc exSymbol(n: var PNode) = 
  var a: PNode
  case n.kind
  of nkPostfix: 
    nil
  of nkPragmaExpr: 
    exSymbol(n.sons[0])
  of nkIdent, nkAccQuoted: 
    a = newNodeI(nkPostFix, n.info)
    addSon(a, newIdentNode(getIdent("*"), n.info))
    addSon(a, n)
    n = a
  else: internalError(n.info, "exSymbol(): " & $n.kind)
  
proc fixRecordDef(n: var PNode) = 
  var length: int
  if n == nil: return 
  case n.kind
  of nkRecCase: 
    fixRecordDef(n.sons[0])
    for i in countup(1, sonsLen(n) - 1): 
      length = sonsLen(n.sons[i])
      fixRecordDef(n.sons[i].sons[length - 1])
  of nkRecList, nkRecWhen, nkElse, nkOfBranch, nkElifBranch, nkObjectTy: 
    for i in countup(0, sonsLen(n) - 1): fixRecordDef(n.sons[i])
  of nkIdentDefs: 
    for i in countup(0, sonsLen(n) - 3): exSymbol(n.sons[i])
  of nkNilLit: 
    nil
  else: internalError(n.info, "fixRecordDef(): " & $n.kind)
  
proc addPragmaToIdent(ident: var PNode, pragma: PNode) = 
  var e, pragmasNode: PNode
  if ident.kind != nkPragmaExpr: 
    pragmasNode = newNodeI(nkPragma, ident.info)
    e = newNodeI(nkPragmaExpr, ident.info)
    addSon(e, ident)
    addSon(e, pragmasNode)
    ident = e
  else: 
    pragmasNode = ident.sons[1]
    if pragmasNode.kind != nkPragma: 
      InternalError(ident.info, "addPragmaToIdent")
  addSon(pragmasNode, pragma)

proc parseRecordBody(p: var TPasParser, result, definition: PNode) = 
  var a: PNode
  skipCom(p, result)
  a = parseRecordPart(p)
  if result.kind != nkTupleTy: fixRecordDef(a)
  addSon(result, a)
  eat(p, pxEnd)
  case p.tok.xkind
  of pxSymbol: 
    if p.tok.ident.id == getIdent("acyclic").id: 
      if definition != nil: 
        addPragmaToIdent(definition.sons[0], newIdentNodeP(p.tok.ident, p))
      else: 
        InternalError(result.info, "anonymous record is not supported")
      getTok(p)
    else: 
      InternalError(result.info, "parseRecordBody")
  of pxCommand: 
    if definition != nil: addPragmaToIdent(definition.sons[0], parseCommand(p))
    else: InternalError(result.info, "anonymous record is not supported")
  else: 
    nil
  opt(p, pxSemicolon)
  skipCom(p, result)

proc parseRecordOrObject(p: var TPasParser, kind: TNodeKind, 
                         definition: PNode): PNode = 
  var a: PNode
  result = newNodeP(kind, p)
  getTok(p)
  addSon(result, nil)
  if p.tok.xkind == pxParLe: 
    a = newNodeP(nkOfInherit, p)
    getTok(p)
    addSon(a, parseTypeDesc(p))
    addSon(result, a)
    eat(p, pxParRi)
  else: 
    addSon(result, nil)
  parseRecordBody(p, result, definition)

proc parseTypeDesc(p: var TPasParser, definition: PNode = nil): PNode = 
  var 
    oldcontext: TPasContext
    a, r: PNode
  oldcontext = p.context
  p.context = conTypeDesc
  if p.tok.xkind == pxPacked: getTok(p)
  case p.tok.xkind
  of pxCommand: 
    result = parseCommand(p, definition)
  of pxProcedure, pxFunction: 
    result = parseRoutineType(p)
  of pxRecord: 
    getTok(p)
    if p.tok.xkind == pxCommand: 
      result = parseCommand(p)
      if result.kind != nkTupleTy: InternalError(result.info, "parseTypeDesc")
      parseRecordBody(p, result, definition)
      a = lastSon(result)     # embed nkRecList directly into nkTupleTy
      for i in countup(0, sonsLen(a) - 1): 
        if i == 0: result.sons[sonsLen(result) - 1] = a.sons[0]
        else: addSon(result, a.sons[i])
    else: 
      result = newNodeP(nkObjectTy, p)
      addSon(result, nil)
      addSon(result, nil)
      parseRecordBody(p, result, definition)
      if definition != nil: 
        addPragmaToIdent(definition.sons[0], newIdentNodeP(getIdent("final"), p))
      else: 
        InternalError(result.info, "anonymous record is not supported")
  of pxObject: 
    result = parseRecordOrObject(p, nkObjectTy, definition)
  of pxParLe: 
    result = parseEnum(p)
  of pxArray: 
    result = newNodeP(nkBracketExpr, p)
    getTok(p)
    if p.tok.xkind == pxBracketLe: 
      addSon(result, newIdentNodeP(getIdent("array"), p))
      getTok(p)
      addSon(result, rangeExpr(p))
      eat(p, pxBracketRi)
    else: 
      if p.inParamList: addSon(result, newIdentNodeP(getIdent("openarray"), p))
      else: addSon(result, newIdentNodeP(getIdent("seq"), p))
    eat(p, pxOf)
    addSon(result, parseTypeDesc(p))
  of pxSet: 
    result = newNodeP(nkBracketExpr, p)
    getTok(p)
    eat(p, pxOf)
    addSon(result, newIdentNodeP(getIdent("set"), p))
    addSon(result, parseTypeDesc(p))
  of pxHat: 
    getTok(p)
    if p.tok.xkind == pxCommand: result = parseCommand(p)
    elif gCmd == cmdBoot: result = newNodeP(nkRefTy, p)
    else: result = newNodeP(nkPtrTy, p)
    addSon(result, parseTypeDesc(p))
  of pxType: 
    getTok(p)
    result = parseTypeDesc(p)
  else: 
    a = primary(p)
    if p.tok.xkind == pxDotDot: 
      result = newNodeP(nkBracketExpr, p)
      r = newNodeP(nkRange, p)
      addSon(result, newIdentNodeP(getIdent("range"), p))
      getTok(p)
      addSon(r, a)
      addSon(r, parseExpr(p))
      addSon(result, r)
    else: 
      result = a
  p.context = oldcontext

proc parseTypeDef(p: var TPasParser): PNode = 
  result = newNodeP(nkTypeDef, p)
  addSon(result, identVis(p))
  addSon(result, nil)         # generic params
  if p.tok.xkind == pxEquals: 
    getTok(p)
    skipCom(p, result)
    addSon(result, parseTypeDesc(p, result))
  else: 
    addSon(result, nil)
  if p.tok.xkind == pxSemicolon: 
    getTok(p)
    skipCom(p, result)

proc parseTypeSection(p: var TPasParser): PNode = 
  result = newNodeP(nkTypeSection, p)
  getTok(p)
  skipCom(p, result)
  while p.tok.xkind == pxSymbol: 
    addSon(result, parseTypeDef(p))

proc parseConstant(p: var TPasParser): PNode = 
  result = newNodeP(nkConstDef, p)
  addSon(result, identVis(p))
  if p.tok.xkind == pxColon: 
    getTok(p)
    skipCom(p, result)
    addSon(result, parseTypeDesc(p))
  else: 
    addSon(result, nil)
    if p.tok.xkind != pxEquals: 
      parMessage(p, errColonOrEqualsExpected, pasTokToStr(p.tok))
  if p.tok.xkind == pxEquals: 
    getTok(p)
    skipCom(p, result)
    addSon(result, parseExpr(p))
  else: 
    addSon(result, nil)
  if p.tok.xkind == pxSemicolon: 
    getTok(p)
    skipCom(p, result)

proc parseConstSection(p: var TPasParser): PNode = 
  result = newNodeP(nkConstSection, p)
  getTok(p)
  skipCom(p, result)
  while p.tok.xkind == pxSymbol: 
    addSon(result, parseConstant(p))

proc parseVar(p: var TPasParser): PNode = 
  result = newNodeP(nkVarSection, p)
  getTok(p)
  skipCom(p, result)
  while p.tok.xkind == pxSymbol: 
    addSon(result, parseIdentColonEquals(p, identVis))
  p.lastVarSection = result

proc parseRoutine(p: var TPasParser): PNode = 
  var 
    a, stmts: PNode
    noBody: bool
  result = newNodeP(nkProcDef, p)
  getTok(p)
  skipCom(p, result)
  expectIdent(p)
  addSon(result, identVis(p))
  addSon(result, nil)         # generic parameters
  addSon(result, parseParamList(p))
  opt(p, pxSemicolon)
  addSon(result, parseRoutineSpecifiers(p, noBody))
  if (p.section == seInterface) or noBody: 
    addSon(result, nil)
  else: 
    stmts = newNodeP(nkStmtList, p)
    while true: 
      case p.tok.xkind
      of pxVar: addSon(stmts, parseVar(p))
      of pxConst: addSon(stmts, parseConstSection(p))
      of pxType: addSon(stmts, parseTypeSection(p))
      of pxComment: skipCom(p, result)
      of pxBegin: break 
      else: 
        parMessage(p, errTokenExpected, "begin")
        break 
    a = parseStmt(p)
    for i in countup(0, sonsLen(a) - 1): addSon(stmts, a.sons[i])
    addSon(result, stmts)

proc fixExit(p: var TPasParser, n: PNode): bool = 
  var 
    length: int
    a: PNode
  result = false
  if (p.tok.ident.id == getIdent("exit").id): 
    length = sonsLen(n)
    if (length <= 0): return 
    a = n.sons[length - 1]
    if (a.kind == nkAsgn) and (a.sons[0].kind == nkIdent) and
        (a.sons[0].ident.id == getIdent("result").id): 
      delSon(a, 0)
      a.kind = nkReturnStmt
      result = true
      getTok(p)
      opt(p, pxSemicolon)
      skipCom(p, a)

proc fixVarSection(p: var TPasParser, counter: PNode) = 
  var v: PNode
  if p.lastVarSection == nil: return 
  assert(counter.kind == nkIdent)
  for i in countup(0, sonsLen(p.lastVarSection) - 1): 
    v = p.lastVarSection.sons[i]
    for j in countup(0, sonsLen(v) - 3): 
      if v.sons[j].ident.id == counter.ident.id: 
        delSon(v, j)
        if sonsLen(v) <= 2: 
          delSon(p.lastVarSection, i)
        return 

proc parseBegin(p: var TPasParser, result: PNode) = 
  getTok(p)
  while true: 
    case p.tok.xkind
    of pxComment: 
      addSon(result, parseStmt(p))
    of pxSymbol: 
      if not fixExit(p, result): addSon(result, parseStmt(p))
    of pxEnd: 
      getTok(p)
      break 
    of pxSemicolon: 
      getTok(p)
    of pxEof: 
      parMessage(p, errExprExpected)
    else: addSonIfNotNil(result, parseStmt(p))
  if sonsLen(result) == 0: addSon(result, newNodeP(nkNilLit, p))
  
proc parseStmt(p: var TPasParser): PNode = 
  var oldcontext: TPasContext
  oldcontext = p.context
  p.context = conStmt
  result = nil
  case p.tok.xkind
  of pxBegin: 
    result = newNodeP(nkStmtList, p)
    parseBegin(p, result)
  of pxCommand: 
    result = parseCommand(p)
  of pxCurlyDirLe, pxStarDirLe: 
    if isHandledDirective(p): result = parseDirective(p)
  of pxIf: 
    result = parseIf(p)
  of pxWhile: 
    result = parseWhile(p)
  of pxRepeat: 
    result = parseRepeat(p)
  of pxCase: 
    result = parseCase(p)
  of pxTry: 
    result = parseTry(p)
  of pxProcedure, pxFunction: 
    result = parseRoutine(p)
  of pxType: 
    result = parseTypeSection(p)
  of pxConst: 
    result = parseConstSection(p)
  of pxVar: 
    result = parseVar(p)
  of pxFor: 
    result = parseFor(p)
    fixVarSection(p, result.sons[0])
  of pxRaise: 
    result = parseRaise(p)
  of pxUses: 
    result = parseUsesStmt(p)
  of pxProgram, pxUnit, pxLibrary: 
    # skip the pointless header
    while not (p.tok.xkind in {pxSemicolon, pxEof}): getTok(p)
    getTok(p)
  of pxInitialization: 
    getTok(p)                 # just skip the token
  of pxImplementation: 
    p.section = seImplementation
    result = newNodeP(nkCommentStmt, p)
    result.comment = "# implementation"
    getTok(p)
  of pxInterface: 
    p.section = seInterface
    getTok(p)
  of pxComment: 
    result = newNodeP(nkCommentStmt, p)
    skipCom(p, result)
  of pxSemicolon: 
    getTok(p)
  of pxSymbol: 
    if p.tok.ident.id == getIdent("break").id: 
      result = newNodeP(nkBreakStmt, p)
      getTok(p)
      skipCom(p, result)
      addSon(result, nil)
    elif p.tok.ident.id == getIdent("continue").id: 
      result = newNodeP(nkContinueStmt, p)
      getTok(p)
      skipCom(p, result)
      addSon(result, nil)
    elif p.tok.ident.id == getIdent("exit").id: 
      result = newNodeP(nkReturnStmt, p)
      getTok(p)
      skipCom(p, result)
      addSon(result, nil)
    else: 
      result = parseExprStmt(p)
  of pxDot: 
    getTok(p)                 # BUGFIX for ``end.`` in main program
  else: result = parseExprStmt(p)
  opt(p, pxSemicolon)
  if result != nil: skipCom(p, result)
  p.context = oldcontext

proc parseUnit(p: var TPasParser): PNode = 
  result = newNodeP(nkStmtList, p)
  getTok(p)                   # read first token
  while true: 
    case p.tok.xkind
    of pxEof, pxEnd: 
      break 
    of pxBegin: 
      parseBegin(p, result)
    of pxCurlyDirLe, pxStarDirLe: 
      if isHandledDirective(p): addSon(result, parseDirective(p))
      else: parMessage(p, errXNotAllowedHere, p.tok.ident.s)
    else: addSon(result, parseStmt(p))
  opt(p, pxEnd)
  opt(p, pxDot)
  if p.tok.xkind != pxEof: 
    addSon(result, parseStmt(p)) # comments after final 'end.'
  
