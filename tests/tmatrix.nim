# Test overloading of [] with multiple indices

type
  TMatrix* = object
    data: seq[float]
    fWidth, fHeight: int

template `|`(x, y: int): expr = y * m.fWidth + x

proc createMatrix*(width, height: int): TMatrix = 
  result.fWidth = width
  result.fHeight = height
  newSeq(result.data, width*height)

proc width*(m: TMatrix): int {.inline.} = return m.fWidth
proc height*(m: TMatrix): int {.inline.} = return m.fHeight

proc `[,]`*(m: TMatrix, x, y: int): float {.inline.} =
  result = m.data[x|y]

proc `[,]=`*(m: var TMatrix, x, y: int, val: float) {.inline.} =
  m.data[x|y] = val
  
proc `[$ .. $, $ .. $]`*(m: TMatrix, a, b, c, d: int): TMatrix =
  result = createMatrix(b-a+1, d-c+1)
  for x in a..b:
    for y in c..d:
      result[x-a, y-c] = m[x, y]

proc `[$ .. $, $ .. $]=`*(m: var TMatrix, a, b, c, d: int, val: float) =
  for x in a..b:
    for y in c..d:
      m[x, y] = val

proc `[$ .. $, $ .. $]=`*(m: var TMatrix, a, b, c, d: int, val: TMatrix) =
  assert val.width == b-a+1
  assert val.height == d-c+1
  for x in a..b:
    for y in c..d:
      m[x, y] = val[x-a, y-c]

proc `-|`*(m: TMatrix): TMatrix =
  ## transposes a matrix
  result = createMatrix(m.height, m.width)
  for x in 0..m.width-1:
    for y in 0..m.height-1: result[y,x] = m[x,y]

#m.row(0, 2) # select row
#m.col(0, 89) # select column

const
  w = 3
  h = 20

var m = createMatrix(w, h)
for i in 0..w-1:
  m[i, i] = 1.0

for i in 0..w-1:
  stdout.write(m[i,i]) #OUT 111
