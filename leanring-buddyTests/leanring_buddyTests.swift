//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import CoreGraphics
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

}

@MainActor
struct PointingCoordinateParsingTests {

    @Test func responseWithoutAnyTagYieldsNoPoints() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "no tag at all in this one.")

        #expect(parseResult.points.isEmpty)
        #expect(parseResult.spokenText == "no tag at all in this one.")
    }

    @Test func pointNoneTagYieldsNoPointsAndIsStripped() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "the capital of france is paris. [POINT:none]")

        #expect(parseResult.points.isEmpty)
        #expect(parseResult.spokenText == "the capital of france is paris.")
    }

    @Test func singleTagIsParsedAndStripped() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "click that. [POINT:850,300:save button]")

        #expect(parseResult.points.count == 1)
        #expect(parseResult.points[0].coordinate == CGPoint(x: 850, y: 300))
        #expect(parseResult.points[0].elementLabel == "save button")
        #expect(parseResult.points[0].screenNumber == nil)
        #expect(parseResult.spokenText == "click that.")
    }

    @Test func screenNumberSuffixIsParsed() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "on your other monitor. [POINT:400,300:terminal:screen2]")

        #expect(parseResult.points.count == 1)
        #expect(parseResult.points[0].screenNumber == 2)
        #expect(parseResult.points[0].elementLabel == "terminal")
    }

    @Test func midTextTagWithTrailingPunctuationIsParsed() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "the [POINT:850,300:models] tag is inline, mid-sentence.")

        #expect(parseResult.points.count == 1)
        #expect(parseResult.points[0].coordinate == CGPoint(x: 850, y: 300))
        #expect(parseResult.spokenText == "the  tag is inline, mid-sentence.")
    }

    @Test func multipleTagsAreReturnedInDocumentOrder() {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "file menu, then share, then export. [POINT:60,15:file menu][POINT:140,200:share][POINT:300,260:export file]"
        )

        #expect(parseResult.points.count == 3)
        #expect(parseResult.points[0].elementLabel == "file menu")
        #expect(parseResult.points[1].elementLabel == "share")
        #expect(parseResult.points[2].elementLabel == "export file")
        #expect(parseResult.spokenText == "file menu, then share, then export.")
    }

    @Test func tagsBeyondTheTourMaximumAreDropped() {
        let sixTags = (1...6).map { "[POINT:\($0 * 100),\($0 * 100):stop \($0)]" }.joined()
        let parseResult = CompanionManager.parsePointingCoordinates(from: "lots of stops. " + sixTags)

        #expect(parseResult.points.count == CompanionManager.maximumPointingTourStops)
        #expect(parseResult.points.last?.elementLabel == "stop 4")
    }

    @Test func pointNoneMixedWithCoordinateTagsContributesNothing() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "here. [POINT:none][POINT:500,500:center]")

        #expect(parseResult.points.count == 1)
        #expect(parseResult.points[0].elementLabel == "center")
    }

    @Test func labelLessTagYieldsNilLabel() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "right there. [POINT:250,750]")

        #expect(parseResult.points.count == 1)
        #expect(parseResult.points[0].elementLabel == nil)
        #expect(parseResult.points[0].coordinate == CGPoint(x: 250, y: 750))
    }

}
