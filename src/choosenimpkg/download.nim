import std/[httpclient, json, os, osproc, strutils, terminal, times, uri]

when defined(curl):
  import math

import nimblepkg/[version, cli]
when defined(curl):
  import libcurl except Version

import cliparams, common, utils
# import telemetry
when defined(macosx):
  from switcher import isAppleSilicon

const
  githubTagReleasesUrl = "https://api.github.com/repos/nim-lang/Nim/tags"
  githubNightliesReleasesUrl = "https://api.github.com/repos/nim-lang/nightlies/releases"
  githubUrl = "https://github.com/nim-lang/Nim"
  websiteUrlXz = "https://nim-lang.org/download/nim-$1.tar.xz"
  websiteUrlGz = "https://nim-lang.org/download/nim-$1.tar.gz"
  csourcesUrl = "https://github.com/nim-lang/csources"
  dlArchive = "archive/$1.tar.gz"
  binaryUrl = "https://nim-lang.org/download/nim-$1$2_x$3" & getBinArchiveFormat()
  userAgent = "choosenim/" & chooseNimVersion

const # Windows-only
  mingwUrl = "https://nim-lang.org/download/mingw$1.zip"
  dllsUrl = "https://nim-lang.org/download/dlls.zip"

const
  progressBarLength = 50


proc getNightliesUrl(parsedContents: JsonNode, arch: int): (string, string) =
  let os =
    when defined(windows): "windows"
    elif defined(linux): "linux"
    elif defined(macosx): "osx"
    elif defined(freebsd): "freebsd"
  for jn in parsedContents.getElems():
    if jn["name"].getStr().contains("devel"):
      let tagName = jn{"tag_name"}.getStr("")
      for asset in jn["assets"].getElems():
        let aname = asset["name"].getStr()
        let url = asset{"browser_download_url"}.getStr("")
        if os in aname:
          when not defined(macosx):
            if "x" & $arch in aname:
              result = (url, tagName)
          else:
            if isAppleSilicon():
              if "arm64" in aname:
                result = (url, tagName)
            else:
              if "x64" in aname:
                result = (url, tagName)
        if result[0].len != 0:
          break
    if result[0].len != 0:
      break

proc showIndeterminateBar(progress, speed: BiggestInt, lastPos: var int) =
  try:
    eraseLine()
  except OSError:
    echo ""
  if lastPos >= progressBarLength:
    lastPos = 0

  var spaces = repeat(' ', progressBarLength)
  spaces[lastPos] = '#'
  lastPos.inc()
  stdout.write("[$1] $2mb $3kb/s" % [
                  spaces, $(progress div (1000*1000)),
                  $(speed div 1000)
                ])
  stdout.flushFile()

proc showBar(fraction: float, speed: BiggestInt) =
  try:
    eraseLine()
  except OSError:
    echo ""
  let hashes = repeat('#', int(fraction * progressBarLength))
  let spaces = repeat(' ', progressBarLength - hashes.len)
  stdout.write("[$1$2] $3% $4kb/s" % [
                  hashes, spaces, formatFloat(fraction * 100, precision=4),
                  $(speed div 1000)
                ])
  stdout.flushFile()

proc addGithubAuthentication(url: string): string =
  let ghtoken = getEnv("GITHUB_TOKEN")
  if ghtoken == "":
    return url
  else:
    display("Info:", "Using the 'GITHUB_TOKEN' environment variable for GitHub API Token.",
            priority=HighPriority)
    return url.replace("https://api.github.com", "https://" & ghtoken & "@api.github.com")

when defined(curl):
  type CurlError* = object of CatchableError

  proc checkCurl(code: Code) =
    if code != E_OK:
      raise newException(CurlError, "CURL failed: " & $easy_strerror(code))

  proc downloadFileCurl(url, outputPath: string) =
    displayDebug("Downloading using Curl")
    # Based on: https://curl.haxx.se/libcurl/c/url2file.html
    let curl = libcurl.easy_init()
    defer:
      curl.easy_cleanup()

    # Enable progress bar.
    #checkCurl curl.easy_setopt(OPT_VERBOSE, 1)
    checkCurl curl.easy_setopt(OPT_NOPROGRESS, 0)

    # Set which URL to download and tell curl to follow redirects.
    checkCurl curl.easy_setopt(OPT_URL, url)
    checkCurl curl.easy_setopt(OPT_FOLLOWLOCATION, 1)

    type
      UserData = ref object
        file: File
        lastProgressPos: int
        bytesWritten: int
        lastSpeedUpdate: float
        speed: BiggestInt
        needsUpdate: bool

    # Set up progress callback.
    proc onProgress(userData: pointer, dltotal, dlnow, ultotal,
                    ulnow: float): cint =
      result = 0 # Ensure download isn't terminated.

      let userData = cast[UserData](userData)

      # Only update once per second.
      if userData.needsUpdate:
        userData.needsUpdate = false
      else:
        return

      let fraction = dlnow.float / dltotal.float
      if fraction.classify == fcNan:
        return

      if fraction == Inf:
        showIndeterminateBar(dlnow.BiggestInt, userData.speed,
                            userData.lastProgressPos)
      else:
        showBar(fraction, userData.speed)

    checkCurl curl.easy_setopt(OPT_PROGRESSFUNCTION, onProgress)

    # Set up write callback.
    proc onWrite(data: ptr char, size: cint, nmemb: cint,
                userData: pointer): cint =
      let userData = cast[UserData](userData)
      let len = size * nmemb
      result = userData.file.writeBuffer(data, len).cint
      doAssert result == len

      # Handle speed measurement.
      const updateInterval = 0.25
      userData.bytesWritten += result
      if epochTime() - userData.lastSpeedUpdate > updateInterval:
        userData.speed = userData.bytesWritten * int(1/updateInterval)
        userData.bytesWritten = 0
        userData.lastSpeedUpdate = epochTime()
        userData.needsUpdate = true

    checkCurl curl.easy_setopt(OPT_WRITEFUNCTION, onWrite)

    # Open file for writing and set up UserData.
    let userData = UserData(
      file: open(outputPath, fmWrite),
      lastProgressPos: 0,
      lastSpeedUpdate: epochTime(),
      speed: 0
    )
    defer:
      userData.file.close()
    checkCurl curl.easy_setopt(OPT_WRITEDATA, userData)
    checkCurl curl.easy_setopt(OPT_PROGRESSDATA, userData)

    # Download the file.
    checkCurl curl.easy_perform()

    # Verify the response code.
    var responseCode: int
    checkCurl curl.easy_getinfo(INFO_RESPONSE_CODE, addr responseCode)

    if responseCode != 200:
      raise newException(HTTPRequestError,
             "Expected HTTP code $1 got $2" % [$200, $responseCode])

proc downloadFileNim(url, outputPath: string) =
  displayDebug("Downloading using HttpClient")
  var client = newHttpClient(proxy = getProxy())

  var lastProgressPos = 0
  proc onProgressChanged(total, progress, speed: BiggestInt) {.closure, gcsafe.} =
    let fraction = progress.float / total.float
    if fraction == Inf:
      showIndeterminateBar(progress, speed, lastProgressPos)
    else:
      showBar(fraction, speed)

  client.onProgressChanged = onProgressChanged

  client.downloadFile(url, outputPath)

when defined(windows):
  import puppy
  proc downloadFilePuppy(url, outputPath: string) =
    displayDebug("Downloading using Puppy")
    let req = fetch(Request(
      url: parseUrl(url),
      verb: "get",
      headers: @[Header(key: "User-Agent", value: userAgent)]
      )
    )
    if req.code == 200:
      writeFile(outputPath, req.body)
    else:
      raise newException(HTTPRequestError,
                   "Expected HTTP code $1 got $2" % [$200, $req.code])

proc downloadFile*(url, outputPath: string, params: CliParams) =
  # For debugging.
  display("GET:", url, priority = DebugPriority)

  # Telemetry
  let startTime = epochTime()

  # Create outputPath's directory if it doesn't exist already.
  createDir(outputPath.splitFile.dir)

  # Download to temporary file to prevent problems when choosenim crashes.
  let tempOutputPath = outputPath & "_temp"
  try:
    when defined(curl):
      downloadFileCurl(url, tempOutputPath)
    elif defined(windows):
      downloadFilePuppy(url, tempOutputPath)
    else:
      downloadFileNim(url, tempOutputPath)
  except HttpRequestError:
    echo("") # Skip line with progress bar.
    let msg = "Couldn't download file from $1.\nResponse was: $2" %
              [url, getCurrentExceptionMsg()]
    display("Info:", msg, Warning, MediumPriority)
    # report(initTiming(DownloadTime, url, startTime, $LabelFailure), params)
    raise

  moveFile(tempOutputPath, outputPath)

  showBar(1, 0)
  echo("")

  # report(initTiming(DownloadTime, url, startTime, $LabelSuccess), params)

proc needsDownload(params: CliParams, downloadUrl: string,
                   outputPath: var string): bool =
  ## Returns whether the download should commence.
  ##
  ## The `outputPath` argument is filled with the valid download path.
  result = true
  outputPath = params.getDownloadPath(downloadUrl)
  if outputPath.fileExists():
    # TODO: Verify sha256.
    display("Info:", "$1 already downloaded" % outputPath,
            priority=HighPriority)
    return false

proc retrieveUrl*(url: string): string
proc downloadImpl(version: Version, params: CliParams): string =
  let arch = getGccArch(params)
  displayDebug("Detected", "arch as " & $arch & "bit")
  if version.isSpecial():
    var reference, url = ""
    if $version in ["#devel", "#head"] and not params.latest:
      # Install nightlies by default for devel channel
      try:
        let rawContents = retrieveUrl(githubNightliesReleasesUrl.addGithubAuthentication())
        let parsedContents = parseJson(rawContents)
        (url, reference) = getNightliesUrl(parsedContents, arch)
        if url.len == 0:
          display(
            "Warning", "Recent nightly release not found, installing latest devel commit.",
            Warning, HighPriority
          )
        reference = if reference.len == 0: "devel" else: reference
      except HTTPRequestError:
        # Unable to get nightlies release json from github API, fallback
        # to `choosenim devel --latest`
        display("Warning", "Nightlies build unavailable, building latest commit",
                Warning, HighPriority)

    if url.len == 0:
      let
        commit = getLatestCommit(githubUrl, "devel")
        archive = if commit.len != 0: commit else: "devel"
      reference =
        case normalize($version)
        of "#head":
          archive
        else:
          ($version)[1 .. ^1]
      url = $(parseUri(githubUrl) / (dlArchive % reference))
    display("Downloading", "Nim $1 from $2" % [reference, "GitHub"],
            priority = HighPriority)
    var outputPath: string
    if not needsDownload(params, url, outputPath): return outputPath

    downloadFile(url, outputPath, params)
    result = outputPath
  else:
    display("Downloading", "Nim $1 from $2" % [$version, "nim-lang.org"],
            priority = HighPriority)

    var outputPath: string

    # Use binary builds for Windows and Linux
    when defined(Windows) or defined(linux):
      let os = when defined(linux): "-linux" else: ""
      let binUrl = binaryUrl % [$version, os, $arch]
      if not needsDownload(params, binUrl, outputPath): return outputPath
      try:
        downloadFile(binUrl, outputPath, params)
        return outputPath
      except HttpRequestError:
        display("Info:", "Binary build unavailable, building from source",
                priority = HighPriority)

    let hasUnxz = findExe("unxz") != ""
    let url = (if hasUnxz: websiteUrlXz else: websiteUrlGz) % $version
    if not needsDownload(params, url, outputPath): return outputPath

    downloadFile(url, outputPath, params)
    result = outputPath

proc download*(version: Version, params: CliParams): string =
  ## Returns the path of the downloaded .tar.(gz|xz) file.
  try:
    return downloadImpl(version, params)
  except HttpRequestError:
    raise newException(ChooseNimError, "Version $1 does not exist." %
                       $version)

proc downloadCSources*(params: CliParams): string =
  let
    commit = getLatestCommit(csourcesUrl, "master")
    archive = if commit.len != 0: commit else: "master"
    csourcesArchiveUrl = $(parseUri(csourcesUrl) / (dlArchive % archive))

  var outputPath: string
  if not needsDownload(params, csourcesArchiveUrl, outputPath):
    return outputPath

  display("Downloading", "Nim C sources from GitHub", priority = HighPriority)
  downloadFile(csourcesArchiveUrl, outputPath, params)
  return outputPath

proc downloadMingw*(params: CliParams): string =
  let
    arch = getCpuArch()
    url = mingwUrl % $arch
  var outputPath: string
  if not needsDownload(params, url, outputPath):
    return outputPath

  display("Downloading", "C compiler (Mingw$1)" % $arch, priority = HighPriority)
  downloadFile(url, outputPath, params)
  return outputPath

proc downloadDLLs*(params: CliParams): string =
  var outputPath: string
  if not needsDownload(params, dllsUrl, outputPath):
    return outputPath

  display("Downloading", "DLLs (openssl, pcre, ...)", priority = HighPriority)
  downloadFile(dllsUrl, outputPath, params)
  return outputPath

proc retrieveUrl*(url: string): string =
  when defined(curl):
    display("Curl", "Requesting " & url, priority = DebugPriority)
    # Based on: https://curl.haxx.se/libcurl/c/simple.html
    let curl = libcurl.easy_init()

    # Set which URL to retrieve and tell curl to follow redirects.
    checkCurl curl.easy_setopt(OPT_URL, url)
    checkCurl curl.easy_setopt(OPT_FOLLOWLOCATION, 1)

    var res = ""
    # Set up write callback.
    proc onWrite(data: ptr char, size: cint, nmemb: cint,
                 userData: pointer): cint =
      var res = cast[ptr string](userData)
      var buffer = newString(size * nmemb)
      copyMem(addr buffer[0], data, buffer.len)
      res[].add(buffer)
      result = buffer.len.cint

    checkCurl curl.easy_setopt(OPT_WRITEFUNCTION, onWrite)
    checkCurl curl.easy_setopt(OPT_WRITEDATA, addr res)

    let usrAgentCopy = userAgent
    checkCurl curl.easy_setopt(OPT_USERAGENT, unsafeAddr usrAgentCopy[0])

    # Download the file.
    checkCurl curl.easy_perform()

    # Verify the response code.
    var responseCode: int
    checkCurl curl.easy_getinfo(INFO_RESPONSE_CODE, addr responseCode)

    display("Curl", res, priority = DebugPriority)

    if responseCode != 200:
      raise newException(HTTPRequestError,
             "Expected HTTP code $1 got $2 for $3" % [$200, $responseCode, url])

    return res
  elif defined(windows):
    return fetch(
      url,
      headers = @[Header(key: "User-Agent", value: userAgent)]
    )
  else:
    display("Http", "Requesting " & url, priority = DebugPriority)
    var client = newHttpClient(proxy = getProxy(), userAgent = userAgent)
    return client.getContent(url)

proc getOfficialReleases*(params: CliParams): seq[Version] =
  let rawContents = retrieveUrl(githubTagReleasesUrl.addGithubAuthentication())
  let parsedContents = parseJson(rawContents)
  let cutOffVersion = newVersion("0.16.0")

  var releases: seq[Version] = @[]
  for release in parsedContents:
    let name = release["name"].getStr().strip(true, false, {'v'})
    let version = name.newVersion
    if cutOffVersion <= version:
      releases.add(version)
  return releases

template isDevel*(version: Version): bool =
  $version in ["#head", "#devel"]

proc gitUpdate*(version: Version, extractDir: string, params: CliParams): bool =
  if version.isDevel() and params.latest:
    let git = findExe("git")
    if git.len != 0 and fileExists(extractDir / ".git" / "config"):
      result = true

      let lastDir = getCurrentDir()
      setCurrentDir(extractDir)
      defer:
        setCurrentDir(lastDir)

      display("Fetching", "latest changes", priority = HighPriority)
      for cmd in [" fetch --all", " reset --hard origin/devel"]:
        var (outp, errC) = execCmdEx(git.quoteShell & cmd)
        if errC != QuitSuccess:
          display("Warning:", "git" & cmd & " failed: " & outp, Warning, priority = HighPriority)
          return false

proc gitInit*(version: Version, extractDir: string, params: CliParams) =
  createDir(extractDir / ".git")
  if version.isDevel():
    let git = findExe("git")
    if git.len != 0:
      let lastDir = getCurrentDir()
      setCurrentDir(extractDir)
      defer:
        setCurrentDir(lastDir)

      var init = true
      display("Setting", "up git repository", priority = HighPriority)
      for cmd in [" init", " remote add origin https://github.com/nim-lang/nim"]:
        var (outp, errC) = execCmdEx(git.quoteShell & cmd)
        if errC != QuitSuccess:
          display("Warning:", "git" & cmd & " failed: " & outp, Warning, priority = HighPriority)
          init = false
          break

      if init:
        discard gitUpdate(version, extractDir, params)

when isMainModule:

  echo retrieveUrl("https://nim-lang.org")
