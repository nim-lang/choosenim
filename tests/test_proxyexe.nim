import std/[oids, os, osproc, strutils, unittest]

import choosenimpkg/cliparams
import choosenimpkg/proxyexe


const
  testDir = currentSourcePath.parentDir  / "proxyexe_d"
  nimbleDir = testDir / "nimbleDir"
  choosenimDir = testDir / "choosenimDir"
  currentFile = choosenimDir / "current"
  selectedVersion = choosenimDir / "toolchains" / "nim-" & $NimVersion
  proxyexeBase = currentSourcePath.parentDir.parentDir / "src" / "choosenimpkg" / "proxyexe"
  proxyexeSrc = proxyexeBase.addFileExt("nim")
  proxyexeBin = proxyexeBase.addFileExt(ExeExt)
  echoNim = testDir / "echo.nim"
  echoBin = testDir / "echo".addFileExt(ExeExt)
  proxyNimBin = nimbleDir / "bin" / "nim".addFileExt(ExeExt)
  mockNimBin = selectedVersion / "bin" / "nim".addFileExt(ExeExt)

const echoSrc = """
import std/cmdline
echo "$1"
for i in 0..paramCount():
  echo paramStr(i)
"""


suite "proxyexe":
  setup:
    removeDir(testDir)
    createDir(nimbleDir)
    createDir(choosenimDir)

  teardown:
    removeDir(testDir)

  # Sanity checks for assumptions the proxyexe code makes

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

  # Run proxyexe in mock nimble / choosenim dir

  test "proxyexe calls correct executable with correct arguments":
    # create mock nimble and choosenim dirs
    createDir(nimbleDir / "bin")
    createDir(selectedVersion / "bin")
    writeFile(currentFile, selectedVersion)

    # compile proxyexe with -d:useExec
    discard execShellCmd("nimble compile -d:useExec " & proxyexeSrc)

    # install proxyexe to nimbleDir bin dir as "nim[.exe]"
    copyFileWithPermissions(proxyexeBin, proxyNimBin)

    # create & compile test executable
    # Add OID to output, so we can ensure we call the right executable
    let oid = $genOid()
    writeFile(echoNim, echoSrc % [oid])
    discard execShellCmd("nimble compile " & echoNim)

    # install test executable to selectedVersion bin dir as "nim[.exe]"
    copyFileWithPermissions(echoBin, mockNimBin)

    # call proxyexe nim with execProcess and pass test args
    let args = @[
        "--choosenimdir=" & choosenimDir,
        "--nimbledir=" & nimbleDir,
        "one",
        "two",
        "three"
      ]
    let outp = execProcess(proxyNimBin, args=args, options={poStdErrToStdOut})

    # compare output with given test args and check that received arg[0] is
    # path to proxied executable in toolchain bin dir
    check outp.strip.splitLines == @[oid, mockNimBin] & args
