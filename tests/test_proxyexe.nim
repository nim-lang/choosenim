import std/[os, strutils, unittest]

import choosenimpkg/cliparams
import choosenimpkg/proxyexe


proc toExe(filename: string): string =
  when defined(windows):
    filename & ".exe"
  else:
    filename


suite "proxyexe":
  test "can create new CliParams with proxyExeMode = true":
    var params = newCliParams(proxyExeMode = true)
    check(params.commands.len == 0)
    check(params.nimbleOptions.startDir == getCurrentDir())

  test "can getSelectedPath and returned path matches Nim version":
    var params: CliParams
    parseCliParams(params, proxyExeMode = true)
    let path = getSelectedPath(params)
    check(path == readFile(params.getCurrentFile()))
    check(path.lastPathPart() == "nim-" & NimVersion)

  test "can get executable name and bin path":
    var params: CliParams
    parseCliParams(params, proxyExeMode = true)
    let res = getExePath(params)
    check(res.name == toExe("test_proxyexe"))
    check(res.path == getSelectedPath(params) / params.getBinDir() / toExe("test_proxyexe"))
