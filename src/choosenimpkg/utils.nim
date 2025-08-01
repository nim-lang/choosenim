import std/[httpclient, os, osproc, sequtils, strutils, uri]

import nimblepkg/[cli, version]
import zippy/tarballs as zippy_tarballs
import zippy/ziparchives as zippy_zips

import cliparams, common

when defined(windows):
  import switcher

proc parseVersion*(versionStr: string): Version =
  if versionStr[0] notin {'#', '\0'} + Digits:
    let msg = "Invalid version, path or unknown channel.\n" &
              "Try 1.0.6, #head, #commitHash, or stable.\n" &
              "For example: choosenim #head.\n  \n"&
              "See --help for more examples."
    raise newException(ChooseNimError, msg)

  let parts = versionStr.split(".")
  if parts.len >= 3 and parts[2].parseInt() mod 2 != 0:
    let msg = ("Version $# is a development version of Nim. This means " &
              "it hasn't been released so you cannot install it this " &
              "way. All unreleased versions of Nim " &
              "have an odd patch number in their version.") % versionStr
    let exc = newException(ChooseNimError, msg)
    exc.hint = "If you want to install the development version then run " &
               "`choosenim devel`."
    raise exc

  result = newVersion(versionStr)

proc isRosetta*(): bool =
  let res = execCmdEx("sysctl -in sysctl.proc_translated")
  if res.exitCode == 0:
    return res.output.strip() == "1"
  return false

proc doCmdRaw*(cmd: string) =
  var command = cmd
  # To keep output in sequence
  stdout.flushFile()
  stderr.flushFile()

  if defined(macosx) and isRosetta():
    command = "arch -arm64 " & command

  displayDebug("Executing", command)
  displayDebug("Work Dir", getCurrentDir())
  let (output, exitCode) = execCmdEx(command)
  displayDebug("Finished", "with exit code " & $exitCode)
  displayDebug("Output", output)

  if exitCode != QuitSuccess:
    raise newException(ChooseNimError,
        "Execution failed with exit code $1\nCommand: $2\nOutput: $3" %
        [$exitCode, command, output])

proc extract*(path: string, extractDir: string) =
  display("Extracting", path.extractFilename(), priority = HighPriority)

  if path.splitFile().ext == ".xz":
    when defined(windows):
      # We don't ship with `unxz` on Windows, instead assume that we get
      # a .zip on this platform.
      raise newException(
        ChooseNimError, "Unable to extract. Tar.xz files are not supported on Windows."
      )
    else:
      let tarFile = path.changeFileExt("")
      removeFile(tarFile) # just in case it exists, if it does `unxz` fails.
      if findExe("unxz") == "":
        raise newException(
          ChooseNimError, "Unable to extract. Need `unxz` to extract .tar.xz file. See https://github.com/dom96/choosenim/issues/290."
        )
      doCmdRaw("unxz " & quoteShell(path))
      extract(tarFile, extractDir) # We remove the .xz extension
      return

  let tempDir = getTempDir() / "choosenim-extraction"
  removeDir(tempDir)

  try:
    case path.splitFile.ext
    of ".zip":
      zippy_zips.extractAll(path, tempDir)
    of ".tar", ".gz":
      if findExe("tar") != "":
        # TODO: Workaround for high mem usage of zippy (https://github.com/guzba/zippy/issues/31).
        createDir(tempDir)
        doCmdRaw("tar xf " & quoteShell(path) & " -C " & quoteShell(tempDir))
      else:
        zippy_tarballs.extractAll(path, tempDir)
    else:
      raise newException(
        ValueError, "Unsupported format for extraction: " & path
      )
  except Exception as exc:
    raise newException(ChooseNimError, "Unable to extract. Error was '$1'." %
                       exc.msg)

  # Skip outer directory.
  # Same as: https://github.com/dom96/untar/blob/d21f7229b/src/untar.nim
  #
  # Determine which directory to copy.
  var srcDir = tempDir
  let contents = toSeq(walkDir(srcDir))
  if contents.len == 1:
    # Skip the outer directory.
    srcDir = contents[0][1]

  # Finally copy the directory to what the user specified.
  copyDir(srcDir, extractDir)

proc getProxy*(): Proxy =
  ## Returns ``nil`` if no proxy is specified.
  var url = ""
  try:
    if existsEnv("http_proxy"):
      url = getEnv("http_proxy")
    elif existsEnv("https_proxy"):
      url = getEnv("https_proxy")
  except ValueError:
    display("Warning:", "Unable to parse proxy from environment: " &
        getCurrentExceptionMsg(), Warning, HighPriority)

  if url.len > 0:
    var parsed = parseUri(url)
    if parsed.scheme.len == 0 or parsed.hostname.len == 0:
      parsed = parseUri("http://" & url)
    let auth =
      if parsed.username.len > 0: parsed.username & ":" & parsed.password
      else: ""
    return newProxy($parsed, auth)
  else:
    return nil

proc getGccArch*(params: CliParams): int =
  ## Get gcc arch by getting pointer size x 8
  var
    outp = ""
    errC = 0

  when defined(windows):
    # Add MingW bin dir to PATH so getGccArch can find gcc.
    let pathEnv = getEnv("PATH")
    if not isDefaultCCInPath(params) and dirExists(params.getMingwBin()):
      putEnv("PATH", params.getMingwBin() & PathSep & pathEnv)

    (outp, errC) = execCmdEx("cmd /c echo int main^(^) { return sizeof^(void *^); } | gcc -xc - -o archtest && archtest")

    putEnv("PATH", pathEnv)
  else:
    (outp, errC) = execCmdEx("echo \"int main() { return sizeof(void *); }\" | gcc -xc - -o archtest && ./archtest")

  removeFile("archtest".addFileExt(ExeExt))

  if errC in [4, 8]:
    return errC * 8
  else:
    # Fallback when arch detection fails. See https://github.com/dom96/choosenim/issues/284
    return when defined(windows): 32 else: 64

proc getLatestCommit*(repo, branch: string): string =
  ## Get latest commit for remote Git repo with ls-remote
  ##
  ## Returns "" if Git isn't available
  let
    git = findExe("git")
  if git.len != 0:
    var
      cmd = when defined(windows): "cmd /c " else: ""
    cmd &= git.quoteShell & " ls-remote " & repo & " " & branch

    let
      (outp, errC) = execCmdEx(cmd)
    if errC == 0:
      for line in outp.splitLines():
        result = line.split('\t')[0]
        break
    else:
      display("Warning", outp & "\ngit ls-remote failed", Warning, HighPriority)
