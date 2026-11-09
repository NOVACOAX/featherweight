import Testing

@testable import FeatherweightCore

@Suite struct HelperInstallPolicyTests {
    private let helper = "/Applications/Featherweight.app/Contents/Library/LoginItems/Featherweight Helper.app/Contents/MacOS/FeatherweightHelper"
    private let moved = "/Users/me/Downloads/Featherweight.app/Contents/Library/LoginItems/Featherweight Helper.app/Contents/MacOS/FeatherweightHelper"
    private let translocated = "/private/var/folders/ab/cd/X/AppTranslocation/6F1E/d/Featherweight.app/Contents/Library/LoginItems/Featherweight Helper.app/Contents/MacOS/FeatherweightHelper"

    @Test func reinstallsWhenTheAgentPointsAtAnotherPath() {
        #expect(HelperInstallPolicy.atLaunch(onboardingComplete: true, installedPath: moved, helperPath: helper) == .install)
    }

    @Test func leavesAnAgentThatAlreadyPointsHere() {
        #expect(HelperInstallPolicy.atLaunch(onboardingComplete: true, installedPath: helper, helperPath: helper) == .skip)
    }

    @Test func leavesAloneWhenNotInstalledOrOnboardingIsNotDone() {
        // Not installed: the user switched it off.
        #expect(HelperInstallPolicy.atLaunch(onboardingComplete: true, installedPath: nil, helperPath: helper) == .skip)
        // First launch has its own install step.
        #expect(HelperInstallPolicy.atLaunch(onboardingComplete: false, installedPath: moved, helperPath: helper) == .skip)
    }

    @Test func neverInstallsFromATranslocatedCopy() {
        #expect(HelperInstallPolicy.isTranslocated(translocated))
        #expect(!HelperInstallPolicy.isTranslocated(helper))
        #expect(HelperInstallPolicy.atLaunch(onboardingComplete: true, installedPath: moved, helperPath: translocated) == .askToMove)
        #expect(HelperInstallPolicy.atFirstInstall(helperPath: translocated) == .askToMove)
        #expect(HelperInstallPolicy.moveNotice == "Move Featherweight to your Applications folder, then open it again.")
    }

    @Test func firstInstallFromAnOrdinaryPlaceInstalls() {
        #expect(HelperInstallPolicy.atFirstInstall(helperPath: helper) == .install)
        #expect(HelperInstallPolicy.atFirstInstall(helperPath: moved) == .install)
    }
}
