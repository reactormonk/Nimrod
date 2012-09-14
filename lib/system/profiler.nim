#
#
#            Nimrod's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This file implements the Nimrod profiler. The profiler needs support by the
# code generator. The idea is to inject the instruction stream
# with 'nimProfile()' calls. These calls are injected at every loop end
# (except perhaps loops that have no side-effects). At every Nth call a
# stack trace is taken. A stack tace is a list of cstrings. We have a count
# table of those.
# 
# The nice thing about this profiler is that it's completely time independent!

{.push profiler: off.}

when not defined(getTicks):
  include "system/timers"

const
  MaxTraceLen = 20 # tracking the last 20 calls is enough

type
  TStackTrace* = array [0..MaxTraceLen-1, cstring]
  TProfilerHook* = proc (st: TStackTrace) {.nimcall.}

proc captureStackTrace(f: PFrame, st: var TStackTrace) =
  const
    firstCalls = 5
  var
    it = f
    i = 0
    total = 0
  while it != nil and i <= high(st)-(firstCalls-1):
    # the (-1) is for a nil entry that marks where the '...' should occur
    st[i] = it.procname
    inc(i)
    inc(total)
    it = it.prev
  var b = it
  while it != nil:
    inc(total)
    it = it.prev
  for j in 1..total-i-(firstCalls-1): 
    if b != nil: b = b.prev
  if total != i:
    st[i] = "..."
    inc(i)
  while b != nil and i <= high(st):
    st[i] = b.procname
    inc(i)
    b = b.prev

var
  profilerHook*: TProfilerHook
    ## set this variable to provide a procedure that implements a profiler in
    ## user space. See the `nimprof` module for a reference implementation.
  SamplingInterval = 50_000
    # set this to change the default sampling interval
  gTicker = SamplingInterval
  interval: TNanos = 5_000_000 # 5ms

proc callProfilerHook(hook: TProfilerHook) {.noinline.} =
  # 'noinline' so that 'nimProfile' does not perform the stack allocation
  # in the common case.
  var st: TStackTrace
  captureStackTrace(framePtr, st)
  hook(st)

proc setProfilingInterval*(intervalInUs: int): TNanos =
  ## set this to change the sampling interval. Default value is 5ms.
  interval = intervalInUs * 1000

var t0: TTicks

proc nimProfile() =
  ## This is invoked by the compiler in every loop and on every proc entry!
  dec gTicker
  if gTicker == 0:
    gTicker = -1
    let t1 = getticks()
    if getticks() - t0 > interval:
      if not isNil(profilerHook):
        # disable recursive calls: XXX should use try..finally,
        # but that's too expensive!
        let oldHook = profilerHook
        profilerHook = nil
        callProfilerHook(oldHook)
        profilerHook = oldHook
      t0 = getticks()
    gTicker = SamplingInterval

proc stopProfiling*() =
  ## call this to stop profiling; should be called by the client profiler.
  profilerHook = nil

{.pop.}
