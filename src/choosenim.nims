when defined(macosx):
  switch("define", "curl")
elif not defined(windows):
  switch("define", "curl")

import strutils

proc isRosetta*(): bool =
  let res = gorgeEx("sysctl -in sysctl.proc_translated")
  if res.exitCode == 0:
    return res.output.strip() == "1"
  return false

proc isAppleSilicon(): bool =
  let (output, exitCode) = gorgeEx("uname -m")  # arch -x86_64 uname -m returns x86_64 on M1
  assert exitCode == 0, output
  return output == "arm64" or isRosetta()

when defined(macosx) and isAppleSilicon():
  switch("passC", "-Wno-incompatible-function-pointer-types")

when defined(staticBuild):
  import "choosenimpkg/proxyexe.nims"
