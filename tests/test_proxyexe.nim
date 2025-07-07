import std/[os, strutils, unittest]

import choosenimpkg/cliparams
import choosenimpkg/proxyexe


var
  testDir = currentSourcePath.parentDir
  nimbleDir = testDir / "nimbleDir"
  choosenimDir = testDir / "choosenimDir"
  currentFile = choosenimDir / "current"
  selectedVersion = choosenimDir / "toolchains" / "nim-" & $NimVersion


suite "proxyexe":
  setup:
    removeDir(nimbleDir)
    createDir(nimbleDir)
    removeDir(choosenimDir)
    createDir(choosenimDir)

  teardown:
    removeDir(nimbleDir)
    removeDir(choosenimDir)

  test "can create new CliParams with proxyExeMode = true":
    var params = newCliParams(proxyExeMode = true)
    check params.commands.len == 0
    check params.nimbleOptions.startDir == getCurrentDir()

  test "can getSelectedPath and returned path matches":
    var params: CliParams
    writeFile(currentFile, selectedVersion)
    parseCliParams(params, proxyExeMode = true)
    params.choosenimDir = choosenimDir
    check params.getCurrentFile() == currentFile
    let path = getSelectedPath(params)
    check path == readFile(params.getCurrentFile())

  test "can get executable name and bin path":
    var params: CliParams
    writeFile(currentFile, selectedVersion)
    parseCliParams(params, proxyExeMode = true)
    params.choosenimDir = choosenimDir
    let res = getExePath(params)
    check res.name == "test_proxyexe"
    check res.path == getSelectedPath(params) / "bin" / "test_proxyexe".changeFileExt(ExeExt)
