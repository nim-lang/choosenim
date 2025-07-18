# Copyright (C) Dominik Picheta. All rights reserved.
# BSD-3-Clause License. Look at license.txt for more info.

import std/[asyncdispatch, options, os, strutils, times]

# import analytics
import nimblepkg/cli

when defined(windows):
  import osinfo/win
else:
  import osinfo/posix

import cliparams, common, utils

type
  EventCategory* = enum
    ActionEvent,
    BuildEvent, BuildSuccessEvent, BuildFailureEvent,
    ErrorEvent,
    OSInfoEvent

  Event* = object
    category*: EventCategory
    action*: string
    label*: string
    value*: Option[int]

  TimingCategory* = enum
    BuildTime,
    DownloadTime

  Timing* = object
    category*: TimingCategory
    name*: string
    time*: int
    label*: string

  LabelCategory* = enum
    LabelSuccess, LabelFailure



proc initEvent*(category: EventCategory, action="", label="",
                value=none(int)): Event =
  let cmd = "choosenim " & commandLineParams().join(" ")
  return Event(category: category,
     action: if action.len == 0: cmd else: action,
     label: label, value: value)

proc initTiming*(category: TimingCategory, name: string, startTime: float,
                 label=""): Timing =
  ## The `startTime` is the Unix epoch timestamp for when the timing started
  ## (from `epochTime`).
  ## This function will automatically calculate the elapsed time based on that.
  let elapsed = int((epochTime() - startTime)*1000)
  return Timing(category: category,
                name: name,
                label: label, time: elapsed)

proc promptCustom(msg: string, params: CliParams): string =
  if params.nimbleOptions.forcePrompts == forcePromptYes:
    display("Prompt:", msg, Warning, HighPriority)
    display("Answer:", "Forced Yes", Warning, HighPriority)
    return "y"
  else:
    return promptCustom(msg, "")

when false: # TODO: Re-enable once analytics is set up again
  proc analyticsPrompt(params: CliParams) =
    let msg = ("Can choosenim record and send anonymised telemetry " &
              "data? [y/n]\n" &
              "Anonymous aggregate user analytics allow us to prioritise\n" &
              "fixes and features based on how, where and when people " &
              "use Nim.\n" &
              "For more details see: https://goo.gl/NzUEPf.")

    let resp = promptCustom(msg, params)
    let analyticsFile = params.getAnalyticsFile()
    case resp.normalize
    of "y", "yes":
      let clientID = analytics.genClientID()
      writeFile(analyticsFile, clientID)
      display("Info:", "Your client ID is " & clientID, priority=LowPriority)
    of "n", "no":
      # Write an empty file to signify that the user answered "No".
      writeFile(analyticsFile, "")
      return
    else:
      # Force the user to answer.
      analyticsPrompt(params)

  proc report*(obj: Event | Timing | ref Exception, params: CliParams)
  proc loadAnalytics*(params: CliParams): bool =
    ## Returns ``true`` if ``analytics`` object has been loaded successfully.
    display("Info:",
            "Not sending analytics because they are currently disabled. If turned back on in a future update your preference is to " &
            (if getEnv("CHOOSENIM_NO_ANALYTICS") == "1" or getEnv("DO_NOT_TRACK") == "1": "not send" else: "send") & " analytics.",
            priority=MediumPriority)

    if getEnv("CHOOSENIM_NO_ANALYTICS") == "1" or getEnv("DO_NOT_TRACK") == "1":
      display("Info:",
              "Not sending analytics because either CHOOSENIM_NO_ANALYTICS or DO_NOT_TRACK is set.",
              priority=MediumPriority)
      return false

    if params.isNil:
      raise newException(ValueError, "Params is nil.")

    if not params.analytics.isNil:
      return true

    let analyticsFile = params.getAnalyticsFile()
    var prompted = false
    if not fileExists(analyticsFile):
      params.analyticsPrompt()
      prompted = true

    let clientID = readFile(analyticsFile)
    if clientID.len == 0:
      display("Info:",
              "No client ID found in '$1', not sending analytics." %
                analyticsFile,
              priority=LowPriority)
      return false

    params.analytics = newPuppyAnalytics("UA-105812497-1", clientID, "choosenim",
                                          chooseNimVersion, proxy = getProxy(),
                                          timeout=5)

    # Report OS info only once.
    if prompted:
      when defined(windows):
        let systemVersion = $getVersionInfo()
      else:
        let systemVersion = getSystemVersion()
      report(initEvent(OSInfoEvent, systemVersion), params)

    return true

proc reportAsyncError(fut: Future[void], params: CliParams) =
  fut.callback =
    proc (fut: Future[void]) {.gcsafe.} =
      {.gcsafe.}:
        if fut.failed:
          display("Warning: ", "Could not report analytics due to error: " &
                  fut.error.msg, Warning, MediumPriority)
        params.pendingReports.dec()

proc hasPendingReports*(params: CliParams): bool = params.pendingReports > 0

when false:
  proc report*(obj: Event | Timing | ref Exception, params: CliParams) =
    try:
      if not loadAnalytics(params):
        return
    except Exception as exc:
      display("Warning:", "Could not load analytics reporter due to error:" &
              exc.msg, Warning, MediumPriority)
      return

    displayDebug("Reporting to analytics...")

    try:
      when obj is Event:
        params.analytics.reportEvent($obj.category, obj.action,
                                              obj.label, obj.value)
      elif obj is Timing:
        params.analytics.reportTiming($obj.category, obj.name,
                                                obj.time, obj.label)
      else:
        params.analytics.reportException(obj.msg)

    except Exception as exc:
      display("Warning:", "Could not report to analytics due to error:" &
              exc.msg, Warning, MediumPriority)

