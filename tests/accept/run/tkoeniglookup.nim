discard """
  output: '''x: 0 y: 0'''
"""

proc ToString[T]*(x: T): string = return $x


type
  TMyObj = object
    x, y: int

proc `$`*(a: TMyObj): bool = 
  result = "x: " & a.x & " y: " & a.y

var a: TMyObj
echo toString(a)

